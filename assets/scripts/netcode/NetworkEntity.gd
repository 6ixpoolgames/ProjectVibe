# Written by Claude (claude-opus-5-5), 2026-11-04. History: netcode/CHANGELOG.md.
## Makes an entity exist across the network (netcode spec sections 7, 10, 13).
##
## Add it as a child of the entity, after its TickStateComponent. NetworkSession gives it an id (the same on every machine, and what
## anything referring to another entity over the network uses), an owner and a role. Offline it is AUTHORITY and local, nothing is
## sent, and the entity plays as single player. The parent may define optional hooks (see the README, "Hooks on the parent").
## [codeblock]
## # in the entity's scene: TickStateComponent first, then NetworkEntity
## NetworkSession.spawn("pawn", peer_id, Vector3(0, 1, 0))
## [/codeblock]
## Design: netcode spec 7, 10, 13.
extends Node
class_name NetworkEntity

## Sent when its role or owner changes while running (swapping pawns), after its parent hears _on_network_role. A pawn's
## ControllerManager listens, to drop the last owner's input.
signal role_changed(entity: NetworkEntity)
## Despawned while [member linger_until_tick] is still ahead: it stays until then, and its holder switches itself off (a pawn hides,
## stops ticking and stops colliding).
signal lingering_started(entity: NetworkEntity)

## What this machine does with the entity: AUTHORITY (server or offline), LOCAL_PREDICTED (your pawn, simulated ahead), REMOTE_FOLLOWING
## (drawn between snapshots), REMOTE_PREDICTED (simulated ahead on its last input) or LOCAL_UNPREDICTED (your pawn, MOBA-style). See the README.
enum Role { AUTHORITY, LOCAL_PREDICTED, REMOTE_FOLLOWING, REMOTE_PREDICTED, LOCAL_UNPREDICTED }

## Off: stays on this machine only, like particles or debris; not spawned anywhere else (not tested yet).
@export var is_replicated: bool = true
## On: other clients simulate this ahead instead of following the server. NetworkSession.default_predicted turns it on everywhere.
@export var is_predicted: bool = false
## On: offline, keep state and input history every tick, for a single-player rewind. Off: nothing is saved or rounded offline (pawn spec 12.1).
@export var keep_history_offline: bool = false:
	set(value):
		keep_history_offline = value
		refresh_input_saving()

## The node that holds this entity's input, for the server's input hooks (a Pawn's ControllerManager sets itself). Null: the parent.
var input_owner: Node = null
## The same on every machine, given by NetworkSession at spawn. -1 until then.
var entity_id: int = -1
## A despawn before this tick waits until the tick after it: what the entity started is still running (its projectiles in flight, whose
## hits need it). Until then it lingers, switched off ([signal lingering_started]). Server or offline. -1: no wait.
var linger_until_tick := -1
## The name it was registered under with NetworkSession.register_type.
var type_name: String = ""
## The peer that sends its input; 0 is the server itself, such as an AI pawn.
var owner_peer: int = 0
## What this machine does with it.
var role: Role = Role.AUTHORITY
## True if this machine provides its input.
var is_local: bool = true
## The NetworkSession that spawned it, or null for an entity made directly.
var session: Node = null
## Its TickStateComponent, a sibling found at configure or ready.
var state: TickStateComponent = null

# Server: how this entity's input is doing, reported in snapshots to its owner.
var last_input_tick: int = -1
var missed_inputs: int = 0

## Ticks of positions kept for lag compensation (about 1 s).
const HIT_HISTORY_SIZE := 64
# REFACTOR: a fixed 64 ticks, while how far back lag compensation goes is a setting (NetworkSession.rewind_cap_seconds). A cap above
# about 1 s, or a higher tick rate, finds no record and silently rewinds nothing (designer friendly). See CHANGELOG.md.
var _driver: Node = null
var _root: Node = null
var _hit_ticks := PackedInt64Array()
var _hit_positions := PackedVector3Array()
var _live_position := Vector3.ZERO
var _paused := false # see set_paused


## Called by NetworkSession before the entity enters the tree, so everything below it sees its role from the start.
func configure(new_id: int, new_type: String, new_owner: int, new_role: Role, local: bool, new_session: Node) -> void:
	entity_id = new_id
	type_name = new_type
	owner_peer = new_owner
	role = new_role
	is_local = local
	session = new_session
	_root = get_parent()
	state = _find_state()
	if state == null:
		push_warning("[NetworkEntity] %s has no TickStateComponent, so it has nothing to send" % _root.name)
	_apply_role_to_state()
	_root.set_meta(&"network_entity", self)
	if _root.has_method(&"_on_network_role"):
		_root._on_network_role(self)


func _enter_tree() -> void:
	_driver = get_node_or_null("/root/TickDriver")
	if _driver:
		_driver.register(self)


func _exit_tree() -> void:
	if _driver:
		_driver.unregister(self)


func _ready() -> void:
	_root = get_parent()
	if state == null:
		state = _find_state()
	_hit_ticks.resize(HIT_HISTORY_SIZE)
	_hit_ticks.fill(-1)
	_hit_positions.resize(HIT_HISTORY_SIZE)
	_apply_role_to_driver()


## True if this entity is placed from snapshots rather than simulated here.
func follows_snapshots() -> bool:
	return role == Role.REMOTE_FOLLOWING or role == Role.LOCAL_UNPREDICTED


## Changes who owns this entity while running (swapping pawns). Input queued from the old owner is dropped, and the parent hears its role again.
func change_owner(new_owner: int, local: bool, new_role: Role) -> void:
	owner_peer = new_owner
	is_local = local
	last_input_tick = -1
	missed_inputs = 0
	role = new_role
	if state:
		state.forget_queued_input()
	_apply_role_to_state()
	_apply_role_to_driver()
	if _root and _root.has_method(&"_on_network_role"):
		_root._on_network_role(self)
	role_changed.emit(self)


## Changes role while running, when a feature switch changes (NetworkSession.refresh_entities). History starts again from here.
func set_role(new_role: Role) -> void:
	if new_role == role:
		return
	role = new_role
	_apply_role_to_state()
	_apply_role_to_driver()


# Sets the TickStateComponent up for this role: how a rollback treats it, and what it saves.
func _apply_role_to_state() -> void:
	if state == null:
		return
	state.rollback_mode = TickStateComponent.RollbackMode.FOLLOW_SERVER if follows_snapshots() else TickStateComponent.RollbackMode.RESIMULATE
	state.keep_input_history = is_local
	refresh_input_saving()


## Works out which inputs the TickStateComponent saves: a server only those a client predicting it needs; offline none unless
## [member keep_history_offline]; a client every tick, for replays. State is recorded every tick everywhere, in the state store.
## [br]An entity NetworkSession never configured (made directly, as tests do) saves everything.
func refresh_input_saving() -> void:
	if state == null:
		return
	var offline: bool = session != null and not session.is_server() and not session.is_client()
	var on_server: bool = role == Role.AUTHORITY and session != null and session.is_server()
	state.skip_input_capture = (on_server and not (is_predicted or session.default_predicted)) or (offline and not keep_history_offline)


## Stops every tick this entity causes (its parent's, its TickState's, its own), or starts them again; state stays as it is.
## [br]While paused it records nothing, so snapshots leave it out. Only for the machine that decides, such as a far-off server AI pawn.
func set_paused(paused: bool) -> void:
	if paused != _paused:
		_paused = paused
		_apply_role_to_driver()


## True while [method set_paused] has stopped it.
func is_paused() -> bool:
	return _paused


# The one place that decides which parts tick. Registers the parent first, since this entity's _tick_input must run after the parent's.
# Something placed from snapshots must not also simulate itself; your own unpredicted pawn still decides its input in _tick_input.
func _apply_role_to_driver() -> void:
	if _driver == null or _root == null or not is_inside_tree():
		return
	if state:
		state.set_recording(not _paused)
	if _paused:
		_driver.unregister(_root)
		_driver.unregister(self)
		if state:
			_driver.unregister(state)
		return
	if follows_snapshots():
		_driver.unregister(_root)
	else:
		_driver.register(_root)
	if state:
		_driver.register(state)
	_driver.register(self)


# --- Called by the tick driver -----------------------------------------------------------------

## Server: hands the entity the input its owner sent for this tick. Runs after the parent's own _tick_input.
func _tick_input(dt: float, tick: int) -> void:
	if role == Role.LOCAL_UNPREDICTED and _root.has_method(&"_tick_input"):
		_root._tick_input(dt, tick)
		return
	if role != Role.AUTHORITY or is_local or owner_peer == 0 or state == null:
		return
	if state.apply_input(tick):
		last_input_tick = tick
	else:
		# Only once it has started sending. A client takes a moment to sync its clock after its pawn spawns.
		if last_input_tick >= 0:
			missed_inputs += 1
		var owner_node: Node = input_owner if is_instance_valid(input_owner) else _root
		if owner_node.has_method(&"_network_input_missing"):
			owner_node._network_input_missing()


## Server: remembers where this entity was, so lag compensation can look back.
func _tick_record(tick: int) -> void:
	if role != Role.AUTHORITY or not (_root is Node3D):
		return
	var slot := tick % HIT_HISTORY_SIZE
	_hit_ticks[slot] = tick
	_hit_positions[slot] = _root.global_position


# --- Called by NetworkSession ------------------------------------------------------------------

## Client: places a snapshot-driven entity between snapshots for this render tick.
func follow_server(render_tick: float, allow_extrapolation: bool = true) -> void:
	if state == null:
		return
	state.follow_server_at(render_tick, allow_extrapolation)
	if _root.has_method(&"_on_network_interpolated"):
		_root._on_network_interpolated()


## The server's cleaned-up version of a client's input.
func clean_input(values: Dictionary) -> Dictionary:
	var owner_node: Node = input_owner if is_instance_valid(input_owner) else _root
	if owner_node.has_method(&"sanitize_network_input"):
		return owner_node.sanitize_network_input(values)
	return values


## Client: tells the parent a correction moved it by this much, so it can hide the jump on its visible model.
func tell_corrected(jump: Variant) -> void:
	if _root.has_method(&"_on_network_corrected"):
		_root._on_network_corrected(jump)


## The parent's global position, or null if it has none.
func get_position_or_null() -> Variant:
	if _root is Node3D or _root is Node2D:
		return _root.global_position
	return null


# --- Lag compensation --------------------------------------------------------------------------

## Server: moves this entity to where it was on a past tick, in the collision world too. False if it has no record of then.
func rewind_to(view_tick: float) -> bool:
	if not (_root is Node3D):
		return false
	var before := floori(view_tick)
	var found_before: Variant = _hit_position_at(before)
	if found_before == null:
		return false
	var position: Vector3 = found_before
	var found_after: Variant = _hit_position_at(before + 1)
	if found_after != null:
		position = position.lerp(found_after, view_tick - before)
	_live_position = _root.global_position
	_root.global_position = position
	# REFACTOR: calls TickStateComponent's private _sync_collision, here and in restore_after_rewind; make it public. See CHANGELOG.md.
	if state:
		state._sync_collision()
	return true


## Server: back to the present after a rewind.
func restore_after_rewind() -> void:
	_root.global_position = _live_position
	if state:
		state._sync_collision()


func _hit_position_at(tick: int) -> Variant:
	if tick < 0 or _hit_ticks.is_empty():
		return null
	var slot := tick % HIT_HISTORY_SIZE
	if _hit_ticks[slot] == tick:
		return _hit_positions[slot]
	return null


func _find_state() -> TickStateComponent:
	for child in _root.get_children():
		if child is TickStateComponent:
			return child
	return null
