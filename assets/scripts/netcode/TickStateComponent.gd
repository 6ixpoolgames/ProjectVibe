# Written by Claude (claude-opus-5-5), 2026-11-04. History: netcode/CHANGELOG.md.
## Makes an entity rollback-ready without writing code (netcode spec sections 5 and 6).
##
## Add it as a child of the entity and list property names in the inspector: [member input_properties] (what the entity wants each
## tick), [member state_properties] (everything that affects the next tick) and [member sync_properties] (server-only values). Its
## state is recorded in the tick driver's state store at the end of every tick (rounded, and written back where rounding changed it),
## and it can put the entity back to any recent tick and replay it. This part is the entity's holder for the store: it matches entries
## to nodes and settles their encodings, and gathers the row itself until every entry has a live node.
## [codeblock]
## "velocity"                 # a property on the parent
## "Walk:phase"               # a property on a node below the parent
## ":rotation:y @angle_u16"   # part of a property on the parent, with an encoding from StateEncoding
## "team pushed"              # read once, then recorded from push_value() when it changes (its setter calls it)
## [/codeblock]
## Design: state store spec 6, netcode spec 5, 6.
extends Node
class_name TickStateComponent
# REFACTOR: two jobs in one class: recording and replaying this machine's own state, and placing an entity it follows from server
# data (follow_server_at, the follow cache, extrapolation, about 300 lines). A separate follower part would make each easier to read
# and extend (reusable, extensible). See CHANGELOG.md.

## What the entity wants each tick: saved after the input phase, put back during a replay, and sent by a client to the server.
@export var input_properties: Array[String] = []
## Everything that affects the next tick: position, velocity, grounded, cooldowns. Rounded, saved and rolled back.
@export var state_properties: Array[String] = []
## Server-only values (health, team). Not rolled back; sent in every snapshot, and clients show the latest.
@export var sync_properties: Array[String] = []
## Extra nodes with save_state() / load_state(). The parent is included automatically if it has them.
@export var custom_state_nodes: Array[NodePath] = []
## Round values to their encodings every tick. Turn off only to compare behaviour; online it must stay on.
@export var quantize_each_tick: bool = true
## Ticks of history kept, at most the tick driver's [member TickDriverSingleton.history_depth].
@export var history_size: int = 64

## What a rollback does with this entity: RESIMULATE puts it back and runs its [code]_tick_simulate[/code] again (what this machine predicts);
## FOLLOW_SERVER draws it from server data (what it doesn't; netcode spec 6.5).
enum RollbackMode { RESIMULATE, FOLLOW_SERVER }
## RESIMULATE for what this machine predicts, FOLLOW_SERVER for what it draws from snapshots (not recorded: the server's data is its
## record). NetworkEntity sets it from its role.
@export var rollback_mode: RollbackMode = RollbackMode.RESIMULATE:
	set(value):
		rollback_mode = value
		_refresh_store_active()
@export_group("Follow server")
## How far past the newest server state a FOLLOW_SERVER entity keeps moving on its velocity, before it holds. 0 = just hold.
## 0.2 measured best of those tried: longer gets worse on long replays, shorter worse on short ones (netcode spec section 6.5).
@export var extrapolation_cap_seconds: float = 0.2
## Also move it up and down on its velocity. Off by default: with no gravity in the estimate, a falling pawn would sink.
@export var extrapolate_vertical: bool = false
## How often a FOLLOW_SERVER entity rewrites every value, not only the changed ones; 0 never. It bounds how long something else writing a property (a script, an animation) can leave it wrong.
@export var follow_refresh_seconds: float = 0.5
## During a rollback, stand on server data and extrapolate, instead of staying where it's drawn. Off by default: no clear difference over real connections (spec 6.5).
@export var follows_during_rollback: bool = false
## With [member follows_during_rollback] on, it only joins a rollback within this distance of something being resimulated; 0 is no limit. A guess to tune.
@export var follow_server_radius: float = 10.0
## Keep input history in FOLLOW_SERVER mode too, for your own pawn with prediction off. NetworkEntity sets it for entities this machine controls.
var keep_input_history: bool = false
## Server: don't record each tick's input (it never replays), unless clients predicting this entity need it. Client inputs still queue. NetworkEntity sets it.
var skip_input_capture: bool = false
## On: the store copies this entity's last row forward on ticks nothing marked it changed ([method mark_changed]), reading none of its
## nodes. For an entity that only changes when it runs: a pawn marks itself on its runs and is marked by what reaches it between them.
var record_only_when_changed := false:
	set(value):
		record_only_when_changed = value
		if _handle >= 0:
			_store.set_carry_forward(_handle, value)

## Stored for a property that didn't exist that tick (the store's [constant StateStoreGD.MISSING]).
const MISSING := &"__tick_state_missing__"
## In the follow cache, a value this component hasn't written, or can't be sure of any more.
const UNWRITTEN := &"__tick_state_unwritten__"


## One list entry, and the node it's currently matched to.
class Prop:
	var entry: String            # exactly as declared, for warnings
	var key: String              # the entry without its encoding, used as the name in get_state() and correct_state()
	var node_path: String        # "" means the parent
	var property: NodePath       # the property, as Node.get_indexed() wants it
	var base_name: String        # the first part of property, to check the node has it
	var encoding: StringName
	var declared: StringName     # the encoding as written ("auto" until a value settles encoding)
	var pushed := false          # recorded from push_value(), not read every tick
	var node = null              # untyped, because it can be freed while we hold it

	func read() -> Variant:
		return node.get_indexed(property)

	func write(value: Variant) -> void:
		node.set_indexed(property, value)


var _driver: Node = null
var _root: Node = null
var _inputs: Array[Prop] = []
var _states: Array[Prop] = []
var _syncs: Array[Prop] = []
var _custom_paths: Array[NodePath] = []
var _custom_nodes: Array = []    # matches _custom_paths; entries may be null or freed
var _warned: Dictionary = {}
var _live_values: Array = []     # following: what the entity had before the replay began, to give back when it ends
var _authoritative_ticks := PackedInt64Array() # following: ring buffer of what the server said, one slot per tick
var _authoritative_values: Array = []
var _newest_authoritative_tick := -1
# What follow_server_at last did, so a remote entity only writes what changes. When it moves on to a new pair of snapshots, it writes
# the values that differ from what it last wrote, and notes which ones move between the two (position, velocity, facing); on the
# ticks in between, only those are blended and written. _follow_before and _follow_after are the pair, _follow_moving the indices
# that blend, _follow_written what was last written at each index. Anything else that writes the properties (a rollback, a
# correction, extrapolating) clears it with _forget_follow(), so the next placement writes everything.
var _follow_before := -1
var _follow_after := -1
var _follow_moving := PackedInt32Array()
var _follow_written: Array = []
var _follow_refreshed := -1 # the tick of the last write of everything (follow_refresh_seconds); -1 before the first
var _auto_encodings_settled := false # whether every "auto" encoding has been worked out
# Each list's encodings, made once and kept until a list is rebuilt or an encoding is settled. Snapshots ask for them for every
# entity every time.
var _encodings_cache := {}
var _replay_base_tick := -1      # following: the server tick the replay is currently estimating from; -1 is none
var _position_index := -1        # following: where "position" and "velocity" are in the state list; -1 is not listed
var _velocity_index := -1

# The state store this entity is recorded in, and its handle there (-1: not in it). The store reads the nodes itself once every entry
# is bound (_bind_in_store); until then, and whenever a node goes away, _store_gather writes the row from GDScript.
var _store: Object = null
var _handle := -1
var _recording := true # false while paused (set_recording)
var _state_index := {}  # an entry's key -> its index in the state list, for push_value
# Ring buffers, one slot per tick (tick % history_size). A slot only counts if its stored tick matches. Custom state stays here, beside
# the store (state store spec 6.4); inputs fold into the store with the netcode.
var _custom_ticks := PackedInt64Array()
var _state_custom: Array = []
var _input_ticks := PackedInt64Array()
var _input_values: Array = []


func _enter_tree() -> void:
	_driver = get_node_or_null("/root/TickDriver")
	if _driver:
		_driver.register(self)
	_refresh_store_active()


func _exit_tree() -> void:
	if _driver:
		_driver.unregister(self)
	_refresh_store_active()


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		_leave_store()


func _ready() -> void:
	_root = get_parent()
	history_size = maxi(1, history_size)
	_custom_paths.clear()
	if _root.has_method(&"save_state") and _root.has_method(&"load_state"):
		_custom_paths.append(get_path_to(_root))
	for path in custom_state_nodes:
		_custom_paths.append(path)
	_custom_nodes.resize(_custom_paths.size())
	_inputs = _parse_list(input_properties)
	_syncs = _parse_list(sync_properties)
	_encodings_cache.clear()
	_build_state_list() # add_state_properties() uses it too
	_custom_ticks.resize(history_size)
	_custom_ticks.fill(-1)
	_state_custom.resize(history_size)
	_input_ticks.resize(history_size)
	_input_ticks.fill(-1)
	_input_values.resize(history_size)
	_authoritative_ticks.resize(history_size)
	_authoritative_ticks.fill(-1)
	_authoritative_values.resize(history_size)
	_join_store()


## Adds state entries for parts that arrive after the scene was made (abilities from PawnInitializer), written as in [member state_properties]. False if refused.
## [br]Only before the first tick is recorded. Every machine must add the same entries in the same order; they aren't in [method get_schema], so the handshake doesn't check them.
func add_state_properties(entries: Array[String]) -> bool:
	if _newest_tick() >= 0:
		push_warning("[TickStateComponent] %s: state entries can only be added before the first tick is recorded, so %s won't roll back." % [_root.name if _root else name, str(entries)])
		return false
	var added: Array[String] = state_properties.duplicate() # a new array, so instances of one scene don't share a list
	for entry in entries:
		if not added.has(entry):
			added.append(entry)
	state_properties = added
	if is_node_ready():
		_build_state_list()
		_join_store() # a new list is a new layout
	return true


# Builds _states from state_properties, and finds position and velocity among them.
func _build_state_list() -> void:
	# FOLLOW_SERVER with nothing listed would silently do nothing, so a door can just set the mode. This is
	# kept out of state_properties, which get_schema() reads, because the handshake compares it across machines and
	# rollback_mode can differ between them.
	var listed: Array[String] = state_properties
	if rollback_mode == RollbackMode.FOLLOW_SERVER and state_properties.is_empty():
		listed = ["position"]
		if "velocity" in _root:
			listed.append("velocity")
	_states = _parse_list(listed)
	_encodings_cache.clear()
	_position_index = -1
	_velocity_index = -1
	_state_index.clear()
	for i in _states.size():
		_state_index[_states[i].key] = i
	# Matched by the property's name, so a velocity kept on a part like the motor still counts.
	for i in _states.size():
		var p := _states[i]
		var property_name := String(p.property)
		if p.node_path == "" and (property_name == "position" or property_name == "global_position"):
			if _position_index < 0:
				_position_index = i
		elif property_name == "velocity" and (_velocity_index < 0 or p.node_path == ""):
			_velocity_index = i


## A position rounded the way the recording rounds the "position" entry, for code that sets position itself (CrowdMover, pawn spec 8.22) so a still pawn stays still.
## [br]Returned as is with no position entry, an unsettled encoding, or rounding off.
func round_position(value: Vector3) -> Vector3:
	if not quantize_each_tick or _position_index < 0:
		return value
	var encoding := _states[_position_index].encoding
	if encoding == StateEncoding.AUTO:
		return value
	return StateEncoding.quantize(value, encoding)


# --- Called by the tick driver -----------------------------------------------------------------

## After every entity's input phase, before anything simulates.
func _tick_capture_input(tick: int) -> void:
	if skip_input_capture or _inputs.is_empty() or (rollback_mode == RollbackMode.FOLLOW_SERVER and not keep_input_history): # following replays no inputs
		return
	var slot := tick % history_size
	_input_ticks[slot] = tick
	_input_values[slot] = _capture(_inputs, _input_values[slot])


## After simulating: saves custom state (save_state). Everything else is recorded by the store's commit, which runs next.
func _tick_record(tick: int) -> void:
	if _custom_paths.is_empty() or rollback_mode == RollbackMode.FOLLOW_SERVER or not _recording:
		return
	var slot := tick % history_size
	_custom_ticks[slot] = tick
	_state_custom[slot] = _save_customs()


## Called by the tick driver for a tick the store couldn't read by itself (an entry not matched yet, or a node gone): gathers the row in
## GDScript, with MISSING for what isn't there, then tries to hand the reading back to the store.
func _store_gather(handle: int, tick: int) -> void:
	if handle != _handle:
		return
	_store.write_row(_handle, tick, _capture(_states, null))
	_bind_in_store()


## This entity's handle in the state store, or -1. The tick driver uses it to commit a rollback's re-run.
func get_store_handle() -> int:
	return _handle


## A pushed entry's new value (see the class description), recorded from this tick's commit on. The owner's setter calls it. Rounded
## to the entry's encoding, and written back to the property if rounding changed it, as a commit would. Unknown keys are ignored.
func push_value(key: String, value: Variant) -> void:
	var i: int = _state_index.get(key, -1)
	if i < 0 or _handle < 0:
		return
	var p := _states[i]
	var rounded: Variant = _rounded_copy(p, value) if quantize_each_tick else StateEncoding.copy_value(value)
	if quantize_each_tick and rounded != value and _bind(p):
		p.write(rounded)
	_store.push(_handle, i, rounded)


## Something changed this entity since the last commit (see [member record_only_when_changed]), so the next commit reads its nodes.
func mark_changed() -> void:
	if _handle >= 0:
		_store.mark_changed(_handle)


## Off stops recording (a paused entity: NetworkEntity.set_paused); rows already recorded stay. On by default.
func set_recording(on: bool) -> void:
	_recording = on
	_refresh_store_active()


## Rollback step 1: put the entity back to how it ended this tick. False if nothing is saved for it; it then sits the replay out.
func _rollback_load(tick: int) -> bool:
	if rollback_mode == RollbackMode.FOLLOW_SERVER:
		return _begin_following(tick)
	if not has_state(tick):
		if _newest_tick() >= 0:
			_warn_once("load_expired", "[TickStateComponent] %s: asked to go back to tick %d, which is no longer in the history (%d ticks kept); keeping current state" % [_root.name, tick, history_size])
		return false
	if not _tick_has_anything(tick):
		return false
	_restore_tick(tick)
	return true


## Rollback step 1b, once everything is loaded and in the collision world.
func _rollback_after_load(tick: int) -> void:
	if rollback_mode == RollbackMode.RESIMULATE:
		_notify_loaded(tick)


## Rollback step 2, per replayed tick: put back what the entity wanted that tick.
func _rollback_input(tick: int) -> void:
	if _inputs.is_empty() or rollback_mode == RollbackMode.FOLLOW_SERVER: # following runs no simulation to feed
		return
	var slot := tick % history_size
	if _input_ticks[slot] == tick:
		_apply(_inputs, _input_values[slot])


## Rollback step 3, per replayed tick: run the entity's normal simulation again.
func _rollback_simulate(dt: float, tick: int) -> void:
	# Following moves to where the server says, in the same phase a simulated entity would move.
	if rollback_mode == RollbackMode.FOLLOW_SERVER:
		_follow_tick(tick)
		return
	if _root.has_method(&"_tick_simulate"):
		_root._tick_simulate(dt, tick)


## Makes the physics world see where this body is right now, so several ticks in one frame (a replay) don't collide with stale positions.
## [br]A moved body reaches the collision world only at the next physics step; a static body's position applies at once, so it's static for this call.
func _sync_collision() -> void:
	# Not yet (netcode spec section 17): rigid bodies get flipped too.
	if not (_root is PhysicsBody3D) or not _root.is_inside_tree():
		return
	var rid: RID = _root.get_rid()
	var mode := PhysicsServer3D.body_get_mode(rid)
	PhysicsServer3D.body_set_mode(rid, PhysicsServer3D.BODY_MODE_STATIC)
	PhysicsServer3D.body_set_state(rid, PhysicsServer3D.BODY_STATE_TRANSFORM, _root.global_transform)
	PhysicsServer3D.body_set_mode(rid, mode)


## Rollback's last step: a following entity gets back what it had before the replay, and its collision position follows.
func _rollback_finished() -> void:
	if rollback_mode != RollbackMode.FOLLOW_SERVER:
		return
	_apply(_states, _live_values)
	_forget_follow() # written here, not by following, so the follow cache can't be trusted
	_sync_collision()


## True in FOLLOW_SERVER mode. The driver asks this and [method wants_to_join_rollback] of each following entity, so far-off ones cost nothing.
func is_following_server() -> bool:
	return rollback_mode == RollbackMode.FOLLOW_SERVER


## Where this entity is, for the distance check, or null if it has no position.
func get_rollback_centre() -> Variant:
	if _root is Node3D or _root is Node2D:
		return _root.global_position
	return null


## True if this following entity should take part in a rollback around these positions.
func wants_to_join_rollback(centres: Array) -> bool:
	return follows_during_rollback and (centres.is_empty() or is_near_any(centres))


## True if this entity is within follow_server_radius of any of the given positions. No position or no limit: always true.
func is_near_any(centres: Array) -> bool:
	var own: Variant = get_rollback_centre()
	if own == null or follow_server_radius <= 0.0:
		return true
	for centre: Variant in centres:
		if typeof(centre) == typeof(own) and own.distance_squared_to(centre) <= follow_server_radius * follow_server_radius:
			return true
	return false


# --- Server data for following -------------------------------------------------------------------

## What the server says this entity's state was on a tick, as {entry: value}: the dictionary form of [method receive_authoritative_values].
## [br]Entries not given stay as they are; names not in state_properties are ignored.
func receive_authoritative_state(tick: int, values: Dictionary) -> void:
	# REFACTOR: only tests call this; snapshots use receive_authoritative_values. A test-only door in production code (production
	# kept apart from test code): the tests could build the list themselves. See CHANGELOG.md.
	# It makes the list and hands it to receive_authoritative_values, which holds the rules (a late packet, the newest tick).
	if tick < 0 or _authoritative_ticks.is_empty():
		return
	var saved: Array = []
	saved.resize(_states.size())
	for i in _states.size():
		var p := _states[i]
		saved[i] = _rounded_copy(p, values[p.key]) if values.has(p.key) else MISSING
	receive_authoritative_values(tick, saved)


## What the server says this entity's state was on a tick, as a whole list in declared order, as a snapshot carries it.
## [br]Kept without copying (the caller hands over its own, already rounded list); a list of the wrong size is ignored.
func receive_authoritative_values(tick: int, values: Array) -> void:
	# An empty list means the server had nothing for it that tick: every entry MISSING, as the dictionary version does with an empty
	# dictionary.
	if values.is_empty() and not _states.is_empty():
		values = []
		values.resize(_states.size())
		values.fill(MISSING)
	if tick < 0 or _authoritative_ticks.is_empty() or values.size() != _states.size():
		return
	var slot := tick % history_size
	if _authoritative_ticks[slot] > tick:
		return # a late packet; this slot already holds something newer
	if not _auto_encodings_settled:
		# An "auto" encoding is settled from its first real value, as _rounded_copy does on the dictionary path.
		_auto_encodings_settled = true
		for i in _states.size():
			if _states[i].encoding == StateEncoding.AUTO:
				if is_same(values[i], MISSING) or values[i] == null:
					_auto_encodings_settled = false
				else:
					_settle_encoding(_states[i], values[i])
	_authoritative_ticks[slot] = tick
	_authoritative_values[slot] = values
	_newest_authoritative_tick = maxi(_newest_authoritative_tick, tick)


## Forgets all server data, so nothing is estimated from before a teleport or respawn.
func clear_authoritative_state() -> void:
	_authoritative_ticks.fill(-1)
	_newest_authoritative_tick = -1
	_forget_follow() # a teleport or respawn: the next placement writes everything again


## Places the entity for drawing, part way between the two snapshots around this tick.
## [br]With nothing newer it moves on its velocity up to [member extrapolation_cap_seconds], then holds; with no data it stays put.
func follow_server_at(render_tick: float, allow_extrapolation: bool = true) -> void:
	if _authoritative_ticks.is_empty() or _newest_authoritative_tick < 0:
		return
	var whole := floori(render_tick)
	# Two short cuts with the same result as the searches below. An entity the server stopped sending (frozen) has nothing near this
	# tick, so it isn't searched for every tick. And when the newest data is the tick before, there's nothing after it to look for.
	@warning_ignore("integer_division") # whole numbers on purpose
	if whole - _newest_authoritative_tick > history_size / 2:
		return
	var before := _find_authoritative(whole, -1)
	var after := -1
	if before != _newest_authoritative_tick:
		after = _find_authoritative(before + 1 if before >= 0 else whole + 1, 1)
	# Each case goes through _place_between, which only writes what changed (see _follow_before).
	if before < 0:
		if after >= 0:
			var oldest: Array = _authoritative_values[after % history_size] # all the data is newer: hold at the oldest
			_place_between(after, after, oldest, oldest, 0.0)
		return
	var older: Array = _authoritative_values[before % history_size]
	if after < 0:
		_place_between(before, before, older, older, 0.0)
		if allow_extrapolation:
			_replay_base_tick = before
			_extrapolate(render_tick - before)
		return
	var newer: Array = _authoritative_values[after % history_size]
	var weight := clampf((render_tick - before) / float(after - before), 0.0, 1.0)
	_place_between(before, after, older, newer, weight)


## Places a following entity weight of the way from older to newer, writing as little as it can; same result as writing [method StateEncoding.blend] of every value.
func _place_between(before: int, after: int, older: Array, newer: Array, weight: float) -> void:
	if _follow_written.size() != _states.size():
		_follow_written.resize(_states.size())
		_follow_written.fill(UNWRITTEN)
		_follow_before = -1
	if before != _follow_before or after != _follow_after:
		_refresh_follow_if_due(before)
		# A new pair: write what differs from what was last written, and note what moves.
		_follow_before = before
		_follow_after = after
		_follow_moving.clear()
		for i in _states.size():
			var value: Variant = older[i]
			if is_same(value, MISSING):
				continue
			if _blends(value, newer[i]):
				_follow_moving.append(i)
				_follow_written[i] = UNWRITTEN # written every tick below; a later pair compares with the real value again
				continue
			var written: Variant = _follow_written[i]
			if typeof(written) == typeof(value) and written == value:
				continue
			var p := _states[i]
			if _bind(p):
				# Gotcha: arrays are shared when assigned, so the node gets its own copy.
				p.write(StateEncoding.copy_value(value))
				_follow_written[i] = value
	for i in _follow_moving:
		var p := _states[i]
		if _bind(p):
			p.write(StateEncoding.blend(older[i], newer[i], weight, p.encoding))


## On a new pair of snapshots, forgets what was last written once [member follow_refresh_seconds] has passed. Entity numbers spread entities' turns, so they don't all refresh on one tick.
func _refresh_follow_if_due(tick: int) -> void:
	if follow_refresh_seconds <= 0.0 or _driver == null:
		return
	var interval: int = _driver.seconds_to_ticks(follow_refresh_seconds)
	if _follow_refreshed < 0:
		_follow_refreshed = tick - posmod(EntityNumber.of(get_parent()), interval)
	# absi, so a clock that jumped back (a resync) still counts as time passed.
	elif absi(tick - _follow_refreshed) >= interval:
		_follow_refreshed = tick
		_follow_written.fill(UNWRITTEN)


## True if a value differs between the two snapshots in a way blend() moves smoothly (same-type vectors and floats).
static func _blends(a: Variant, b: Variant) -> bool:
	var type := typeof(a)
	if type != typeof(b) or not (type == TYPE_VECTOR3 or type == TYPE_VECTOR2 or type == TYPE_FLOAT):
		return false
	return a != b


## Something else wrote the properties, so the next placement writes everything.
func _forget_follow() -> void:
	_follow_before = -1
	_follow_after = -1
	_follow_written.fill(UNWRITTEN)


## The nearest tick with server data, starting at from_tick and looking one way (step is 1 or -1). -1 if there's none near.
func _find_authoritative(from_tick: int, step: int) -> int:
	var t := from_tick
	@warning_ignore("integer_division") # whole numbers on purpose
	for i in history_size / 2:
		if t < 0:
			return -1
		if _authoritative_ticks[t % history_size] == t:
			return t
		t += step
	return -1


# --- Network data --------------------------------------------------------------------------------
# What NetworkSession reads and writes. Lists are in declared order, which the handshake's hash guarantees
# is the same on every machine.

## The saved state for a tick as a plain list (a copy), or empty if it's gone.
func get_state_values(tick: int) -> Array:
	return _store.get_row(_handle, tick) if has_state(tick) else []


## The saved input for a tick as a plain list, or empty if it's gone.
func get_input_values(tick: int) -> Array:
	var slot := tick % history_size
	if tick < 0 or _input_ticks.is_empty() or _input_ticks[slot] != tick:
		return []
	return _input_values[slot]


## The current server-only values, as a plain list.
func get_sync_values() -> Array:
	var values: Array = []
	values.resize(_syncs.size())
	for i in _syncs.size():
		values[i] = _syncs[i].read() if _bind(_syncs[i]) else MISSING
	return values


## The state list's encodings, in declared order. The same list each time until it changes, so don't change what you're given.
func get_state_encodings() -> Array:
	return _cached_encodings(&"state", _states)


## The input list's encodings, kept like the state list's.
func get_input_encodings() -> Array:
	return _cached_encodings(&"input", _inputs)


## The sync list's encodings, kept like the state list's.
func get_sync_encodings() -> Array:
	return _cached_encodings(&"sync", _syncs)


## How many entries each list has: [state, sync, input, custom]. NetworkSession checks a snapshot's lists against these and refuses a mismatch.
func get_list_sizes() -> PackedInt32Array:
	return PackedInt32Array([_states.size(), _syncs.size(), _inputs.size(), _custom_paths.size()])


## A state list as {entry: value}, leaving out MISSING values. Empty if the list is the wrong size.
func state_values_to_dictionary(values: Array) -> Dictionary:
	return _to_dictionary(_states, values) if values.size() == _states.size() else {}


## An input list as {entry: value}, leaving out MISSING values. Empty if the list is the wrong size.
func input_values_to_dictionary(values: Array) -> Dictionary:
	return _to_dictionary(_inputs, values) if values.size() == _inputs.size() else {}


## Shows what the server says for its server-only values. A list of the wrong size is ignored.
func apply_sync_values(values: Array) -> void:
	if values.size() == _syncs.size():
		_apply(_syncs, values)


## Server: keeps a client's input for its tick; entries not given stay as they are. Wrong types and NaN values are dropped, so even an entity with no sanitize hook is protected.
func receive_input(tick: int, values: Dictionary) -> void:
	if tick < 0 or _input_ticks.is_empty():
		return
	var slot := tick % history_size
	if _input_ticks[slot] > tick:
		return
	var saved: Array = []
	saved.resize(_inputs.size())
	for i in _inputs.size():
		var p := _inputs[i]
		saved[i] = _rounded_copy(p, values[p.key]) if values.has(p.key) and _is_usable_input(p, values[p.key]) else MISSING
	_input_ticks[slot] = tick
	_input_values[slot] = saved


## Drops every input waiting here. A new owner's inputs are the only ones that count from now on.
func forget_queued_input() -> void:
	if not _input_ticks.is_empty():
		_input_ticks.fill(-1)


## Server: puts this tick's input on the entity. False if none has arrived for this tick.
func apply_input(tick: int) -> bool:
	var slot := tick % history_size
	if _input_ticks.is_empty() or _input_ticks[slot] != tick:
		return false
	_apply(_inputs, _input_values[slot])
	return true


## Client, for a remote entity it predicts: from this tick on, assume it kept doing what the server last said.
func hold_input_from(tick: int, values: Dictionary) -> void:
	if values.is_empty() or _driver == null:
		return
	for t in range(tick, _driver.tick + 1):
		receive_input(t, values)
	apply_input(tick)


# --- Asking about and correcting the history -----------------------------------------------------

## True if the history holds this tick's state.
func has_state(tick: int) -> bool:
	return _handle >= 0 and _store.has_row(_handle, tick)


## The state saved for a tick as {entry: value}, or empty if it's gone. Custom state appears under the node's name.
## The values are copies; changing them doesn't change the history.
func get_state(tick: int) -> Dictionary:
	if not has_state(tick):
		return {}
	var out := _to_dictionary(_states, _store.get_row(_handle, tick))
	var saved: Variant = _customs_at(tick)
	if saved is Array:
		for i in _custom_paths.size():
			if saved[i] is Dictionary and is_instance_valid(_custom_nodes[i]):
				out[String(_custom_nodes[i].name)] = saved[i].duplicate(true)
	return out


## The input saved for a tick as {entry: value}, or empty if it's gone.
func get_input(tick: int) -> Dictionary:
	var slot := tick % history_size
	if tick < 0 or _input_ticks.size() == 0 or _input_ticks[slot] != tick:
		return {}
	return _to_dictionary(_inputs, _input_values[slot])


## What save_state returned on this tick, one entry per custom state node, for sending in snapshots. Empty if
## this entity has none.
func get_custom_values(tick: int) -> Array:
	if _custom_paths.is_empty() or not has_state(tick):
		return []
	var saved: Variant = _customs_at(tick)
	return saved if saved is Array else []


## True if these values match what's saved for that tick, within tolerance: "was my prediction right?" Compares only entries given and saved.
## [br]custom is the authority's save_state result ([method get_custom_values]); it compares exactly.
func matches_state(tick: int, values: Dictionary, custom: Array = []) -> bool:
	if not has_state(tick):
		return false
	var saved: Array = _store.get_row(_handle, tick)
	for i in _states.size():
		var p := _states[i]
		if values.has(p.key) and not is_same(saved[i], MISSING):
			if not StateEncoding.nearly_equal(saved[i], values[p.key], p.encoding):
				return false
	if custom.size() == _custom_paths.size():
		var saved_custom: Variant = _customs_at(tick)
		for i in custom.size():
			if saved_custom is Array and saved_custom[i] is Dictionary and custom[i] is Dictionary and saved_custom[i] != custom[i]:
				return false
	return true


## Overwrites saved entries for a tick with what the authority says was true; follow with [code]TickDriver.rollback(tick)[/code]. True if the history took it.
## [br]A tick already out of the history can't replay: the entity snaps to the values, with a warning, and it returns false (spec 15).
func correct_state(tick: int, values: Dictionary, custom: Array = []) -> bool:
	var custom_usable := custom.size() == _custom_paths.size() and not custom.is_empty()
	if has_state(tick):
		for i in _states.size():
			var p := _states[i]
			if values.has(p.key):
				_store.set_value(_handle, i, tick, _rounded_copy(p, values[p.key]))
		if custom_usable:
			_custom_ticks[tick % history_size] = tick
			_state_custom[tick % history_size] = custom
		return true
	if tick < 0 or tick > _newest_tick():
		return false
	_warn_once("correct_expired", "[TickStateComponent] %s: correction for tick %d is older than the history (%d ticks kept); snapping without a replay" % [_root.name, tick, history_size])
	_forget_follow()
	for p in _states:
		if values.has(p.key) and _bind(p):
			p.write(_rounded_copy(p, values[p.key]))
	if custom_usable:
		_load_customs(custom)
	_notify_loaded(tick)
	return false


## Every declared entry with its kind and encoding, in order. Same code on two machines gives the same list; the handshake's content
## hash includes it (NetworkSession.content_hash, netcode spec section 5.4).
func get_schema() -> PackedStringArray:
	var out := PackedStringArray()
	for pair in [["input", input_properties], ["state", state_properties], ["sync", sync_properties]]:
		for entry in pair[1]:
			out.append("%s %s" % [pair[0], entry])
	# Custom state goes in snapshots too, so both sides need to have the same.
	var parent := get_parent()
	if parent and parent.has_method(&"save_state"):
		out.append("custom parent")
	for path in custom_state_nodes:
		out.append("custom %s" % path)
	return out


# --- Internals -----------------------------------------------------------------------------------

## Reads each property, rounds it, writes it back if rounding changed it. Reuses the given array if there is one (the input ring's
## slot), so a tick doesn't allocate once the ring is full (Arrays and Dictionaries in the list are the exception: they're copied).
func _capture(props: Array[Prop], reuse: Variant) -> Array:
	var values: Array = reuse if reuse is Array else []
	values.resize(props.size())
	for i in props.size():
		var p := props[i]
		if not _bind(p):
			values[i] = MISSING
			continue
		var v: Variant = p.read()
		_settle_encoding(p, v)
		if quantize_each_tick:
			var q: Variant = StateEncoding.quantize(v, p.encoding)
			if q != v:
				p.write(q)
				v = q
		values[i] = StateEncoding.copy_value(v)
	return values


func _apply(props: Array[Prop], values: Array) -> void:
	for i in props.size():
		if not is_same(values[i], MISSING) and _bind(props[i]):
			props[i].write(StateEncoding.copy_value(values[i]))


func _to_dictionary(props: Array[Prop], values: Array) -> Dictionary:
	var out := {}
	for i in props.size():
		if not is_same(values[i], MISSING):
			out[props[i].key] = StateEncoding.copy_value(values[i])
	return out


func _rounded_copy(p: Prop, value: Variant) -> Variant:
	_settle_encoding(p, value)
	return StateEncoding.copy_value(StateEncoding.quantize(value, p.encoding))


## Auto encodings are picked from the first real value, since a property may still be null before its owner's _ready.
func _settle_encoding(p: Prop, value: Variant) -> void:
	if p.encoding != StateEncoding.AUTO or value == null:
		return
	p.encoding = StateEncoding.resolve(StateEncoding.AUTO, value)
	_encodings_cache.clear() # an encoding changed
	if value is Object:
		_warn_once(p.entry, "[TickStateComponent] %s: '%s' holds an Object, which can't be copied into the history, so it won't roll back. Use save_state/load_state, or list an id." % [_root.name, p.entry])


## True if this tick saved at least one property or custom state.
func _tick_has_anything(tick: int) -> bool:
	for v in _store.get_row(_handle, tick):
		if not is_same(v, MISSING):
			return true
	var saved: Variant = _customs_at(tick)
	if saved is Array:
		for s in saved:
			if s is Dictionary:
				return true
	return false


## Replay step 1 when following the server. Remembers what the entity has now and finds the server state to start from. False, so it
## sits the replay out, if the server hasn't sent anything.
func _begin_following(tick: int) -> bool:
	if _newest_authoritative_tick < 0 or _states.is_empty():
		return false
	# Without both, it only holds still, which is much less accurate. A door has neither, so stays quiet.
	if (_position_index >= 0 and _velocity_index < 0 and "velocity" in _root) or (_velocity_index >= 0 and _position_index < 0):
		_warn_once("no_estimate", "[TickStateComponent] %s: FOLLOW_SERVER needs the parent's position and a velocity listed to estimate movement; holding still instead" % _root.name)
	_live_values.resize(_states.size())
	for i in _states.size():
		var p := _states[i]
		_live_values[i] = StateEncoding.copy_value(p.read()) if _bind(p) else MISSING
	_replay_base_tick = -1
	for back in history_size:
		var t := tick - back
		if t >= 0 and _authoritative_ticks[t % history_size] == t:
			_replay_base_tick = t
			break
	_follow_tick(tick)
	return true


## Stands the entity where the server says for this tick, or estimates from the last state it sent.
func _follow_tick(tick: int) -> void:
	if _authoritative_ticks[tick % history_size] == tick:
		_replay_base_tick = tick
	if _replay_base_tick < 0:
		return
	_apply(_states, _authoritative_values[_replay_base_tick % history_size])
	_forget_follow() # see _rollback_finished
	if tick > _replay_base_tick:
		_extrapolate(float(tick - _replay_base_tick))


## Velocity-only prediction: moves on from the server's position, up to the cap. No steering, gravity
## or collisions, so it costs almost nothing.
func _extrapolate(ticks: float) -> void:
	if _position_index < 0 or _velocity_index < 0:
		return
	var saved: Array = _authoritative_values[_replay_base_tick % history_size]
	var from_position: Variant = saved[_position_index]
	var velocity: Variant = saved[_velocity_index]
	if typeof(from_position) != typeof(velocity) or not (from_position is Vector3 or from_position is Vector2):
		return
	if velocity is Vector3 and not extrapolate_vertical:
		velocity.y = 0.0
	var capped: float = minf(ticks, float(_driver.seconds_to_ticks(extrapolation_cap_seconds)))
	var seconds: float = capped * _driver.get_tick_dt()
	if _bind(_states[_position_index]):
		_states[_position_index].write(from_position + velocity * seconds)
		# The next placement writes the position again, even between the same pair, so it doesn't hold the extrapolated position.
		# Only the position differs from what was written, so that placement writes just it.
		if _position_index < _follow_written.size():
			_follow_written[_position_index] = UNWRITTEN
		_follow_before = -1


## True if a value from the network fits the property it's meant for, and has no not-a-number or infinity in it.
func _is_usable_input(p: Prop, value: Variant) -> bool:
	if not _bind(p) or typeof(value) != typeof(p.read()):
		return false
	match typeof(value):
		TYPE_FLOAT:
			return is_finite(value)
		TYPE_VECTOR2, TYPE_VECTOR3:
			return value.is_finite()
	return true


func _encodings_of(props: Array[Prop]) -> Array:
	var out: Array = []
	for p in props:
		out.append(p.encoding)
	return out


# A list's encodings, made once under its name and kept (see _encodings_cache).
func _cached_encodings(list_name: StringName, props: Array[Prop]) -> Array:
	if not _encodings_cache.has(list_name):
		_encodings_cache[list_name] = _encodings_of(props)
	return _encodings_cache[list_name]


## Puts the entity back to how it ended this tick: the store writes the nodes when it reads them itself, else GDScript does.
func _restore_tick(tick: int) -> void:
	if not _store.load_row(_handle, tick):
		_apply(_states, _store.get_row(_handle, tick))
	_forget_follow() # see _rollback_finished
	_load_customs(_customs_at(tick))


# --- The state store -------------------------------------------------------------------------------

## Joins the tick driver's store (again, if the list changed): one layout per state list, so entities with the same list share a
## table. An entity with nothing to record stays out. Entries keep their declared encodings in the layout ("auto" included); each
## entity's binding gives the settled ones.
func _join_store() -> void:
	_leave_store()
	if _driver == null or (_states.is_empty() and _custom_paths.is_empty() and _syncs.is_empty()):
		return
	_store = _driver.store
	var names := PackedStringArray()
	var encodings: Array = []
	var pushed := PackedByteArray()
	for p in _states:
		names.append(p.key)
		encodings.append(p.declared)
		pushed.append(1 if p.pushed else 0)
	var layout: int = _store.define_layout(names, encodings, pushed)
	_handle = _store.add_entity(layout, self) if layout >= 0 else -1
	if _handle < 0:
		return
	_store.set_entity_depth(_handle, history_size)
	_store.set_carry_forward(_handle, record_only_when_changed)
	_refresh_store_active()
	_bind_in_store()


func _leave_store() -> void:
	if _handle >= 0 and _store:
		_store.remove_entity(_handle)
	_handle = -1


## Hands the reading to the store once every entry has a live node and a settled encoding. Quietly does nothing until then.
func _bind_in_store() -> void:
	if _handle < 0:
		return
	var nodes: Array = []
	var paths: Array = []
	var encodings: Array = []
	for p in _states:
		if not is_instance_valid(p.node) or p.encoding == StateEncoding.AUTO:
			return
		nodes.append(p.node)
		paths.append(p.property)
		encodings.append(p.encoding)
	_store.bind(_handle, nodes, paths, encodings, quantize_each_tick)


## Recorded only in the tree, while recording, and when this machine simulates the entity (not FOLLOW_SERVER).
func _refresh_store_active() -> void:
	if _handle >= 0 and _store:
		_store.set_active(_handle, is_inside_tree() and _recording and rollback_mode == RollbackMode.RESIMULATE)


func _newest_tick() -> int:
	return _store.newest_tick(_handle) if _handle >= 0 else -1


func _customs_at(tick: int) -> Variant:
	var slot := tick % history_size
	return _state_custom[slot] if tick >= 0 and _custom_ticks.size() > 0 and _custom_ticks[slot] == tick else null


func _notify_loaded(tick: int) -> void:
	if _root.has_method(&"_on_state_loaded"):
		_root._on_state_loaded(tick)


func _save_customs() -> Array:
	var saved: Array = []
	for i in _custom_paths.size():
		var n = _bind_custom(i)
		saved.append(n.save_state() if n else MISSING)
	return saved


func _load_customs(saved: Variant) -> void:
	if not (saved is Array):
		return
	for i in _custom_paths.size():
		var n = _bind_custom(i)
		if n and saved[i] is Dictionary:
			n.load_state(saved[i].duplicate(true)) # a copy, so load_state can keep it without touching the history


## The custom state node at this index, or null. Looked for again each time, like list entries.
func _bind_custom(i: int) -> Variant:
	if is_instance_valid(_custom_nodes[i]):
		return _custom_nodes[i]
	var n := get_node_or_null(_custom_paths[i])
	if n and n.has_method(&"save_state") and n.has_method(&"load_state"):
		_custom_nodes[i] = n
		return n
	_custom_nodes[i] = null
	_warn_once(str(_custom_paths[i]), "[TickStateComponent] %s: custom state node '%s' is missing or lacks save_state/load_state; still looking" % [_root.name, _custom_paths[i]])
	return null


func _parse_list(entries: Array[String]) -> Array[Prop]:
	var out: Array[Prop] = []
	for entry in entries:
		var p := _parse_entry(entry)
		if p:
			out.append(p)
	return out


## Reads one entry's text. Doesn't look at nodes yet; _bind does that once ticks are running.
func _parse_entry(entry: String) -> Prop:
	var text := entry.strip_edges()
	var pushed := text.ends_with(" pushed")
	if pushed:
		text = text.trim_suffix(" pushed")
	var parts := text.split("@", false, 1)
	var key := parts[0].strip_edges() if parts.size() > 0 else ""
	if key == "":
		_warn_once(entry, "[TickStateComponent] %s: empty entry '%s' skipped" % [_root.name, entry])
		return null
	var p := Prop.new()
	p.entry = entry
	p.key = key
	p.pushed = pushed
	p.encoding = StateEncoding.AUTO
	if parts.size() > 1:
		var named := StringName(parts[1].strip_edges())
		if StateEncoding.is_known(named):
			p.encoding = named
		else:
			_warn_once(entry, "[TickStateComponent] %s: unknown encoding in '%s'; using auto" % [_root.name, entry])
	var property := key
	var colon := key.find(":")
	if colon >= 0:
		p.node_path = key.substr(0, colon)
		property = key.substr(colon + 1)
	p.property = NodePath(property)
	p.base_name = property.split(":")[0]
	p.declared = p.encoding
	return p


## Makes sure the entry points at a live node with that property. False if it can't right now.
func _bind(p: Prop) -> bool:
	if is_instance_valid(p.node):
		return true
	p.node = null
	var node: Node = _root
	if p.node_path != "":
		node = _root.get_node_or_null(NodePath(p.node_path))
	if node == null:
		_warn_once(p.entry, "[TickStateComponent] %s: no node '%s' for entry '%s', still looking (for part of a property on the parent, start with a colon: ':%s')" % [_root.name, p.node_path, p.entry, p.key])
		return false
	if not (p.base_name in node):
		_warn_once(p.entry, "[TickStateComponent] %s: '%s' has no property '%s', still looking" % [_root.name, node.name, p.base_name])
		return false
	p.node = node
	return true


func _warn_once(key: String, message: String) -> void:
	if _warned.has(key):
		return
	_warned[key] = true
	push_warning(message)
