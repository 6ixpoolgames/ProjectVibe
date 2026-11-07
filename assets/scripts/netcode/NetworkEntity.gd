## Written by Claude (claude-opus-5-5), 2026-11-04: makes an entity exist across the network (netcode spec sections 7, 10, 13).
## Add it as a child of the entity, after its TickStateComponent. NetworkSession gives it an id, an owner and a role when it
## spawns, and the same id on every machine. Anything referring to another entity over the network uses that id.
##
## Roles, set per machine:
##   AUTHORITY          the server (or offline). It simulates for real and its results count.
##   LOCAL_PREDICTED    your own pawn on your client. It simulates ahead and gets corrected.
##   LOCAL_UNPREDICTED  your own pawn with prediction off: MOBA-style. It sends inputs and waits, so what you do shows up after
##                      your ping. It's drawn from snapshots like a remote entity.
##   REMOTE_FOLLOWING   anything else on a client, by default. It doesn't simulate: it's drawn in the past between snapshots
##                      (interpolation), and stays where it's drawn during a rollback.
##   REMOTE_PREDICTED   anything else on a client, when predicted. It simulates ahead on its last known input and gets
##                      corrected, like Rocket League cars. Off by default: it costs CPU on every rollback, needs input in
##                      every snapshot, and puts enemies at their present position, which doesn't suit aiming.
##
## Hooks on the parent, all optional:
##   _on_network_role(entity)                     told its role before entering the tree, so it can pick where input comes from
##   sanitize_network_input(values) -> Dictionary the server cleans a client's input. Never trust it
##   _network_input_missing()                     the server has no input for this tick and repeats the last one
##   _on_network_interpolated()                   a remote entity was just moved between snapshots
##   _on_network_corrected(jump)                  a rollback moved it by this much, for hiding the jump on the visible model
##
## Rules, checked in tests/net_selftest.gd:
##   - Offline, it's AUTHORITY and local, and nothing is sent. The entity plays as single player.
##   - An entity with no TickStateComponent has nothing to send, and warns once.
##   - is_replicated off: exists on this machine only, not spawned anywhere else. This one isn't tested yet.
extends Node
class_name NetworkEntity

enum Role { AUTHORITY, LOCAL_PREDICTED, REMOTE_FOLLOWING, REMOTE_PREDICTED, LOCAL_UNPREDICTED }

## Off: stays on this machine only, like particles or debris.
@export var is_replicated: bool = true
## On: other clients simulate this ahead instead of following the server. NetworkSession.default_predicted turns it on everywhere.
@export var is_predicted: bool = false

var entity_id: int = -1
var type_name: String = ""
var owner_peer: int = 0            # the peer that sends its input; 0 is the server itself, such as an AI pawn
var role: Role = Role.AUTHORITY
var is_local: bool = true          # this machine provides its input
var session: Node = null
var state: TickStateComponent = null

# Server: how this entity's input is doing, reported in snapshots to its owner.
var last_input_tick: int = -1
var missed_inputs: int = 0

const HIT_HISTORY_SIZE := 64
var _driver: Node = null
var _root: Node = null
var _hit_ticks := PackedInt64Array()
var _hit_positions := PackedVector3Array()
var _live_position := Vector3.ZERO
var _paused := false # Claude 2026-11-07: see set_paused


## Called by NetworkSession before the entity enters the tree, so everything below it can see its role from the start.
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


## Claude 2026-11-07: changes who owns this entity while running, which is what swapping pawns does. Input queued from the old owner
## is forgotten, and the parent is told its new role again.
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


## Changes role while running, for the test switches. Its history simply starts again from here.
func set_role(new_role: Role) -> void:
	if new_role == role:
		return
	role = new_role
	_apply_role_to_state()
	_apply_role_to_driver()


func _apply_role_to_state() -> void:
	if state == null:
		return
	state.rollback_mode = TickStateComponent.RollbackMode.FOLLOW_SERVER if follows_snapshots() else TickStateComponent.RollbackMode.RESIMULATE
	state.keep_input_history = is_local
	refresh_input_saving()


## Claude 2026-11-05: on a server, only entities that clients predict need their inputs saved, so they can go in snapshots.
## Offline stays as it was, since a single-player game could still choose to roll back.
func refresh_input_saving() -> void:
	if state:
		state.skip_input_capture = role == Role.AUTHORITY and session != null and session.is_server() and not (is_predicted or session.default_predicted)


## Claude 2026-11-07: stops every tick this entity causes, or starts them again: its parent's, its TickState's and its own. All of its
## state stays as it is. While paused it records nothing, so snapshots leave it out, and clients hold it where they last saw it. Only
## for an entity on the machine that decides, such as a server's AI pawn out of reach of every player.
func set_paused(paused: bool) -> void:
	if paused != _paused:
		_paused = paused
		_apply_role_to_driver()


func is_paused() -> bool:
	return _paused


## Claude 2026-11-07: the one place that decides which of this entity's parts tick, so nothing else has to undo it. It registers them
## in the order they'd normally join: the parent first, because _tick_input below runs after the parent's.
## Something placed from snapshots must not also simulate itself. Your own unpredicted pawn still decides its input, in _tick_input below.
func _apply_role_to_driver() -> void:
	if _driver == null or _root == null or not is_inside_tree():
		return
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

## Server: hands the entity the input its owner sent for this tick. This runs after the parent's own _tick_input.
func _tick_input(dt: float, tick: int) -> void:
	if role == Role.LOCAL_UNPREDICTED and _root.has_method(&"_tick_input"):
		_root._tick_input(dt, tick)
		return
	if role != Role.AUTHORITY or is_local or owner_peer == 0 or state == null:
		return
	if state.apply_input(tick):
		last_input_tick = tick
	else:
		# Claude 2026-11-04: only once it has started sending. A client takes a moment to sync its clock after its pawn spawns.
		if last_input_tick >= 0:
			missed_inputs += 1
		if _root.has_method(&"_network_input_missing"):
			_root._network_input_missing()


## Server: remembers where this entity was, so lag compensation can look back.
func _tick_record(tick: int) -> void:
	if role != Role.AUTHORITY or not (_root is Node3D):
		return
	var slot := tick % HIT_HISTORY_SIZE
	_hit_ticks[slot] = tick
	_hit_positions[slot] = _root.global_position


# --- Called by NetworkSession ------------------------------------------------------------------

## Something placed from snapshots: places it for this tick, between them.
func follow_server(render_tick: float, allow_extrapolation: bool = true) -> void:
	if state == null:
		return
	state.follow_server_at(render_tick, allow_extrapolation)
	if _root.has_method(&"_on_network_interpolated"):
		_root._on_network_interpolated()


## The server's cleaned-up version of a client's input.
func clean_input(values: Dictionary) -> Dictionary:
	if _root.has_method(&"sanitize_network_input"):
		return _root.sanitize_network_input(values)
	return values


func tell_corrected(jump: Variant) -> void:
	if _root.has_method(&"_on_network_corrected"):
		_root._on_network_corrected(jump)


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
	return _hit_positions[slot] if _hit_ticks[slot] == tick else null


func _find_state() -> TickStateComponent:
	for child in _root.get_children():
		if child is TickStateComponent:
			return child
	return null
