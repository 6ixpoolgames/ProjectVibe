## Written by Claude (claude-opus-5-5), 2026-11-04: makes an entity rollback-ready without writing code (netcode spec sections 5 and 6).
## Add it as a child of the entity and list property names in the inspector. It rounds them every tick, keeps their
## recent history, and can put the entity back to any recent tick and replay it. The entity itself keeps implementing
## _tick_input and _tick_simulate as normal; those are all it needs.
##
## The lists:
##   input_properties  what the entity WANTS each tick. Saved after the input phase, restored during replay.
##   state_properties  everything that affects the next tick: position, velocity, grounded, cooldowns...
##                     If a value influences the future and isn't listed, replays drift.
##   sync_properties   server-only values (health, team). Not rolled back. Sent in every snapshot; clients show the latest.
##
## How to write an entry (the optional "@encoding" is one of those in StateEncoding.gd; default is by type):
##   "velocity"                 a property on the parent
##   "Walk:phase"               a property on a node below the parent
##   ":rotation:y @angle_u16"   part of a property on the parent (note the leading colon)
##
## Unusual state: if the parent, or a node in custom_state_nodes, has save_state() -> Dictionary and
## load_state(Dictionary), those run alongside the lists. save_state must return a new Dictionary each call.
## Claude 2026-11-05: the Dictionary also goes to clients in every snapshot, and clients correct it like list entries. That makes
## two rules: its values must come out exactly equal on server and client, so use ints, bools or floats you've rounded yourself,
## and keep it small, since there are no encodings to shrink it.
## After every entity has loaded, the parent's _on_state_loaded(tick) runs if it has one (for things only the engine can
## restore). Claude 2026-11-04: it waits for all of them, so a floor check there sees the others where they were.
##
## Rules and corner cases (all checked in tests/tick_state_selftest.gd):
##   - Entries are matched to nodes when ticks run, not at ready, because children become ready before their parent and
##     the nexus may add parts later. An entry whose node or property isn't there warns once and is looked for again
##     every tick, so it starts working as soon as the part exists. An unusable entry never causes an error.
##   - A listed node that gets freed (an ability removed at runtime) just stops being saved. Ticks saved while it was
##     there leave whatever replaced it alone: only properties saved for that tick are restored.
##   - Arrays and Dictionaries are copied in and out of the history, so every tick keeps its own contents.
##     Objects can't be copied: listing one warns, and it won't roll back. Use save_state/load_state, or an id.
##   - No lists at all, or none usable yet: harmless. The entity isn't predicted, because there is nothing to restore.
##   - history_size is in ticks, default 64 (about 1 s at 60/s). Anything older is gone: asking about it returns empty
##     or false, and a rollback carries on without this entity.
##   - correct_state for a tick that's gone can't replay, so it snaps the entity to the given values and warns.
##   - Replay with an input missing for a tick: the last input stays in place.
##   - Only values that changed are written back after rounding, so setters don't run needlessly.
##   - No TickDriver autoload: stays idle.
##
## Following the server (Claude 2026-11-04, netcode spec section 6.5). rollback_mode decides what a rollback does with this entity:
##   RESIMULATE (default)  it's put back and its _tick_simulate runs again. For what this machine predicts: your own pawn.
##   FOLLOW_SERVER       it isn't simulated: it's for what this machine doesn't predict, like other players' pawns. It's
##                       drawn between snapshots with follow_server_at. NetworkEntity stops its parent ticking live. During a
##                       rollback it normally stays where it's drawn. With follows_during_rollback on, it stands where the
##                       server says instead, so that predicted bodies bump into it there.
## The snapshot code passes what the server says to receive_authoritative_state(tick, values). With follows_during_rollback
## on, during a replay, each tick:
##   - The server sent this tick: the entity stands exactly there.
##   - Otherwise: it starts from the newest server state before this tick and moves on that state's velocity, up to
##     extrapolation_cap_seconds, then holds. This is velocity-only prediction: no steering, gravity or collisions.
## Follow-server rules, also checked in the test:
##   - When the replay ends, the entity gets back exactly what it had before. It only stands there during the replay;
##     where it's drawn doesn't change. Its _tick_simulate and _on_state_loaded don't run.
##   - It keeps no history of its own and doesn't round its properties. Its input isn't saved. get_state() returns empty.
##   - No server data yet, or none from before the replay's first tick: it stays where it is until a server tick is reached.
##   - The position is the parent's "position" or "global_position". The velocity is any entry whose property is called
##     "velocity", on the parent or a node below it ("Motor:velocity"), with the parent's preferred. Without both, or if
##     they're different types, it holds still after the newest server state, which suits a door. If that looks like a
##     mistake, because one is listed and the other isn't but the parent has a velocity, it warns once.
##   - Vector3 ignores up and down by default (extrapolate_vertical), because with no gravity a falling pawn would sink into
##     the floor. Vector2 always uses both axes.
##   - FOLLOW_SERVER with nothing listed uses "position", plus "velocity" if the parent has one, so the mode never does nothing.
##     These aren't added to state_properties, so get_schema() stays the same on machines using either mode. List them
##     to have them sent over the network.
##   - save_state/load_state and custom_state_nodes aren't used in this mode: the server only sends listed properties.
##   - A late packet older than what its history slot already holds is ignored. After a teleport or respawn, call
##     clear_authoritative_state() so nothing is estimated from before it.
##   - Tested with CharacterBody3D and plain nodes. Rigid bodies and animated platforms aren't tested yet.
extends Node
class_name TickStateComponent

@export var input_properties: Array[String] = []
@export var state_properties: Array[String] = []
@export var sync_properties: Array[String] = []
## Extra nodes with save_state() / load_state(). The parent is included automatically if it has them.
@export var custom_state_nodes: Array[NodePath] = []
## Round values to their encodings every tick. Turn off only to compare behaviour; online it must stay on.
@export var quantize_each_tick: bool = true
## Ticks of history kept.
@export var history_size: int = 64

## Claude 2026-11-04: what a rollback does with this entity. See "Following the server" at the top of this file.
enum RollbackMode { RESIMULATE, FOLLOW_SERVER }
@export var rollback_mode: RollbackMode = RollbackMode.RESIMULATE
@export_group("Follow server")
## How far past the newest server state a FOLLOW_SERVER entity keeps moving on its velocity, before it holds. 0 = just hold.
## 0.2 measured best of those tried: longer gets worse on long replays, shorter worse on short ones (netcode spec section 6.5).
@export var extrapolation_cap_seconds: float = 0.2
## Also move it up and down on its velocity. Off by default: with no gravity in the estimate, a falling pawn would sink.
@export var extrapolate_vertical: bool = false
## Claude 2026-11-04: during a rollback, stand on server data and extrapolate, instead of staying where it's drawn. Off by
## default, which is the standard behaviour: over real connections it made no clear difference (netcode spec section 6.5).
@export var follows_during_rollback: bool = false
## Claude 2026-11-04: with that on, this entity only joins a rollback if it's this close to something being resimulated. 0 means no limit.
## A guess to tune: it only has to reach anything a replaying pawn could touch during a replay (netcode spec section 6.5).
@export var follow_server_radius: float = 10.0
## Claude 2026-11-04: FOLLOW_SERVER normally saves no input. Your own pawn with prediction off still has inputs to send.
var keep_input_history: bool = false
## Claude 2026-11-05: the server never replays, so it has no use for a record of what each tick's input turned out to be, unless
## clients predicting this entity need it sent to them. Inputs arriving from clients are still stored until their tick comes.
var skip_input_capture: bool = false

## Stored in a history slot for a property that didn't exist that tick.
const MISSING := &"__tick_state_missing__"


## One list entry, and the node it's currently matched to.
class Prop:
	var entry: String            # exactly as declared, for warnings
	var key: String              # the entry without its encoding, used as the name in get_state() and correct_state()
	var node_path: String        # "" means the parent
	var property: NodePath       # the property, as Node.get_indexed() wants it
	var base_name: String        # the first part of property, to check the node has it
	var encoding: StringName
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
var _newest_state_tick := -1
var _live_values: Array = []     # following: what the entity had before the replay began, to give back when it ends
var _authoritative_ticks := PackedInt64Array() # following: ring buffer of what the server said, one slot per tick
var _authoritative_values: Array = []
var _newest_authoritative_tick := -1
var _replay_base_tick := -1      # following: the server tick the replay is currently estimating from; -1 is none
var _position_index := -1        # following: where "position" and "velocity" are in the state list; -1 is not listed
var _velocity_index := -1

# Ring buffers, one slot per tick (tick % history_size). A slot only counts if its stored tick matches.
var _state_ticks := PackedInt64Array()
var _state_values: Array = []
var _state_custom: Array = []
var _input_ticks := PackedInt64Array()
var _input_values: Array = []


func _enter_tree() -> void:
	_driver = get_node_or_null("/root/TickDriver")
	if _driver:
		_driver.register(self)


func _exit_tree() -> void:
	if _driver:
		_driver.unregister(self)


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
	_build_state_list() # Claude 2026-11-07: moved into a function, which add_state_properties() uses too
	_state_ticks.resize(history_size)
	_state_ticks.fill(-1)
	_state_values.resize(history_size)
	_state_custom.resize(history_size)
	_input_ticks.resize(history_size)
	_input_ticks.fill(-1)
	_input_values.resize(history_size)
	_authoritative_ticks.resize(history_size)
	_authoritative_ticks.fill(-1)
	_authoritative_values.resize(history_size)


## Claude 2026-11-07: adds state entries for parts that arrive after the scene was made, such as abilities PawnInitializer adds. Pawn
## spec step 6. Entries are written as in state_properties, with node paths relative to the parent ("AbilityManager/Sprint:time_left").
## Only before the first tick is recorded, because every saved tick has to hold the same list. Every machine must add the same
## entries in the same order, which holds when they come from the same parts. They aren't part of get_schema(), because that reads
## the scene as made, so the handshake doesn't check them. False if refused.
func add_state_properties(entries: Array[String]) -> bool:
	if _newest_state_tick >= 0:
		push_warning("[TickStateComponent] %s: state entries can only be added before the first tick is recorded, so %s won't roll back." % [_root.name if _root else name, str(entries)])
		return false
	var added: Array[String] = state_properties.duplicate() # a new array, so instances of one scene don't share a list
	for entry in entries:
		if not added.has(entry):
			added.append(entry)
	state_properties = added
	if is_node_ready():
		_build_state_list()
	return true


# Builds _states from state_properties, and finds position and velocity among them.
func _build_state_list() -> void:
	# Claude 2026-11-04: FOLLOW_SERVER with nothing listed would silently do nothing, so a door can just set the mode. This is
	# kept out of state_properties, which get_schema() reads, because the handshake compares it across machines and
	# rollback_mode can differ between them.
	var listed: Array[String] = state_properties
	if rollback_mode == RollbackMode.FOLLOW_SERVER and state_properties.is_empty():
		listed = ["position"]
		if "velocity" in _root:
			listed.append("velocity")
	_states = _parse_list(listed)
	_position_index = -1
	_velocity_index = -1
	# Claude 2026-11-04: matched by the property's name, so a velocity kept on a part like the motor still counts.
	for i in _states.size():
		var p := _states[i]
		var property_name := String(p.property)
		if p.node_path == "" and (property_name == "position" or property_name == "global_position"):
			if _position_index < 0:
				_position_index = i
		elif property_name == "velocity" and (_velocity_index < 0 or p.node_path == ""):
			_velocity_index = i


# --- Called by the tick driver -----------------------------------------------------------------

## After every entity's input phase, before anything simulates.
func _tick_capture_input(tick: int) -> void:
	if skip_input_capture or _inputs.is_empty() or (rollback_mode == RollbackMode.FOLLOW_SERVER and not keep_input_history): # Claude 2026-11-04: following replays no inputs
		return
	var slot := tick % history_size
	_input_ticks[slot] = tick
	_input_values[slot] = _capture(_inputs, _input_values[slot])


## After simulating. Stores what state the entity ended this tick in.
func _tick_record(tick: int) -> void:
	if _states.is_empty() and _custom_paths.is_empty():
		return
	# Claude 2026-11-04: following uses the server's data, not its own, so it has nothing to save.
	if rollback_mode == RollbackMode.FOLLOW_SERVER:
		return
	var slot := tick % history_size
	_state_ticks[slot] = tick
	_newest_state_tick = maxi(_newest_state_tick, tick)
	_state_values[slot] = _capture(_states, _state_values[slot])
	if not _custom_paths.is_empty():
		_state_custom[slot] = _save_customs()


## Rollback step 1: put the entity back to how it ended this tick. False if there's nothing to restore for that tick,
## in which case the entity keeps its current state and sits the replay out.
func _rollback_load(tick: int) -> bool:
	if rollback_mode == RollbackMode.FOLLOW_SERVER: # Claude 2026-11-04
		return _begin_following(tick)
	if not has_state(tick):
		if _newest_state_tick >= 0:
			_warn_once("load_expired", "[TickStateComponent] %s: asked to go back to tick %d, which is no longer in the history (%d ticks kept); keeping current state" % [_root.name, tick, history_size])
		return false
	var slot := tick % history_size
	if not _slot_has_anything(slot):
		return false
	_restore_slot(slot)
	return true


## Claude 2026-11-04: rollback step 1b, once everything is loaded and in the collision world.
func _rollback_after_load(tick: int) -> void:
	if rollback_mode == RollbackMode.RESIMULATE:
		_notify_loaded(tick)


## Rollback step 2, per replayed tick: put back what the entity wanted that tick.
func _rollback_input(tick: int) -> void:
	if _inputs.is_empty() or rollback_mode == RollbackMode.FOLLOW_SERVER: # Claude 2026-11-04: following runs no simulation to feed
		return
	var slot := tick % history_size
	if _input_ticks[slot] == tick:
		_apply(_inputs, _input_values[slot])


## Rollback step 3, per replayed tick: run the entity's normal simulation again.
func _rollback_simulate(dt: float, tick: int) -> void:
	# Claude 2026-11-04: following moves to where the server says, in the same phase a simulated entity would move.
	if rollback_mode == RollbackMode.FOLLOW_SERVER:
		_follow_tick(tick)
		return
	if _root.has_method(&"_tick_simulate"):
		_root._tick_simulate(dt, tick)


## Claude 2026-11-04: makes the physics world see where this body is right now. Normally a moved body reaches the
## collision world only at the next physics step, so when several ticks run within one frame, as in a replay or a frame
## with two ticks, bodies would collide with out-of-date positions of each other. Kinematic bodies are deferred by the
## physics engine, but a static body's position applies at once, so it's static for just this call.
func _sync_collision() -> void:
	# Claude 2026-11-04: to do (netcode spec section 17): 2D bodies aren't handled, and rigid bodies get flipped too.
	if not (_root is PhysicsBody3D) or not _root.is_inside_tree():
		return
	var rid: RID = _root.get_rid()
	var mode := PhysicsServer3D.body_get_mode(rid)
	PhysicsServer3D.body_set_mode(rid, PhysicsServer3D.BODY_MODE_STATIC)
	PhysicsServer3D.body_set_state(rid, PhysicsServer3D.BODY_STATE_TRANSFORM, _root.global_transform)
	PhysicsServer3D.body_set_mode(rid, mode)


## Claude 2026-11-04: rollback's last step. A following entity gets back what it had before the replay. Its collision position
## has to follow, because the replay's last sync left it at the last replayed tick.
func _rollback_finished() -> void:
	if rollback_mode != RollbackMode.FOLLOW_SERVER:
		return
	_apply(_states, _live_values)
	_sync_collision()


## Claude 2026-11-04: the driver loads resimulated entities first, then asks these two about each following one, so a
## following entity far from every replaying body doesn't cost anything.
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

## Claude 2026-11-04: what the server says this entity's state was on a tick, as {entry: value}. Called by the snapshot code
## for a FOLLOW_SERVER entity. Entries not given stay as they are during that tick; names not in state_properties are ignored.
func receive_authoritative_state(tick: int, values: Dictionary) -> void:
	if tick < 0 or _authoritative_ticks.is_empty():
		return
	var slot := tick % history_size
	if _authoritative_ticks[slot] > tick:
		return # a late packet; this slot already holds something newer
	var saved: Array = []
	saved.resize(_states.size())
	for i in _states.size():
		var p := _states[i]
		saved[i] = _rounded_copy(p, values[p.key]) if values.has(p.key) else MISSING
	_authoritative_ticks[slot] = tick
	_authoritative_values[slot] = saved
	_newest_authoritative_tick = maxi(_newest_authoritative_tick, tick)


## Claude 2026-11-04: forgets all server data, so nothing is estimated from before a teleport or respawn.
func clear_authoritative_state() -> void:
	_authoritative_ticks.fill(-1)
	_newest_authoritative_tick = -1


## Claude 2026-11-04: places the entity for drawing, part way between the two snapshots around this tick. If nothing newer
## has arrived, it moves on from the newest on its velocity, up to the cap, then holds. With extrapolation off, it just holds
## at the newest. Before any data, it stays put.
func follow_server_at(render_tick: float, allow_extrapolation: bool = true) -> void:
	if _authoritative_ticks.is_empty() or _newest_authoritative_tick < 0:
		return
	var whole := floori(render_tick)
	var before := _find_authoritative(whole, -1)
	var after := _find_authoritative(before + 1 if before >= 0 else whole + 1, 1)
	if before < 0:
		if after >= 0:
			_apply(_states, _authoritative_values[after % history_size]) # all the data is newer: hold at the oldest
		return
	var older: Array = _authoritative_values[before % history_size]
	if after < 0:
		_apply(_states, older)
		if allow_extrapolation:
			_replay_base_tick = before
			_extrapolate(render_tick - before)
		return
	var newer: Array = _authoritative_values[after % history_size]
	var weight := clampf((render_tick - before) / float(after - before), 0.0, 1.0)
	for i in _states.size():
		var p := _states[i]
		if not is_same(older[i], MISSING) and _bind(p):
			p.write(StateEncoding.blend(older[i], newer[i], weight, p.encoding))


## The nearest tick with server data, starting at from_tick and looking one way (step is 1 or -1). -1 if there's none near.
func _find_authoritative(from_tick: int, step: int) -> int:
	var t := from_tick
	for i in history_size / 2:
		if t < 0:
			return -1
		if _authoritative_ticks[t % history_size] == t:
			return t
		t += step
	return -1


# --- Network data --------------------------------------------------------------------------------
# Claude 2026-11-04: what NetworkSession reads and writes. Lists are in declared order, which the handshake's hash guarantees
# is the same on every machine.

## The saved state for a tick as a plain list, or empty if it's gone.
func get_state_values(tick: int) -> Array:
	return _state_values[tick % history_size] if has_state(tick) else []


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


func get_state_encodings() -> Array:
	return _encodings_of(_states)


func get_input_encodings() -> Array:
	return _encodings_of(_inputs)


func get_sync_encodings() -> Array:
	return _encodings_of(_syncs)


func state_values_to_dictionary(values: Array) -> Dictionary:
	return _to_dictionary(_states, values) if values.size() == _states.size() else {}


func input_values_to_dictionary(values: Array) -> Dictionary:
	return _to_dictionary(_inputs, values) if values.size() == _inputs.size() else {}


## Shows what the server says for its server-only values. A list of the wrong size is ignored.
func apply_sync_values(values: Array) -> void:
	if values.size() == _syncs.size():
		_apply(_syncs, values)


## Server: keeps a client's input for the tick it belongs to. Entries not given stay as they are. A wrong type or a
## not-a-number value is dropped too, so an entity with no sanitize_network_input hook is still protected.
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


## Claude 2026-11-07: drops every input waiting here. A new owner's inputs are the only ones that count from now on.
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

func has_state(tick: int) -> bool:
	return tick >= 0 and _state_ticks.size() > 0 and _state_ticks[tick % history_size] == tick


## The state saved for a tick as {entry: value}, or empty if it's gone. Custom state appears under the node's name.
## The values are copies; changing them doesn't change the history.
func get_state(tick: int) -> Dictionary:
	if not has_state(tick):
		return {}
	var slot := tick % history_size
	var out := _to_dictionary(_states, _state_values[slot])
	var saved = _state_custom[slot]
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


## Claude 2026-11-05: what save_state returned on this tick, one entry per custom state node, for sending in snapshots. Empty if
## this entity has none.
func get_custom_values(tick: int) -> Array:
	if _custom_paths.is_empty() or not has_state(tick):
		return []
	var saved: Variant = _state_custom[tick % history_size]
	return saved if saved is Array else []


## True if these values match what's saved for that tick, within tolerance. Only compares list entries that are given
## and were saved. This is the reconciliation question: "was my prediction for this tick right?"
## Claude 2026-11-05: custom is what the authority's save_state returned, from get_custom_values. Those compare exactly.
func matches_state(tick: int, values: Dictionary, custom: Array = []) -> bool:
	if not has_state(tick):
		return false
	var saved: Array = _state_values[tick % history_size]
	for i in _states.size():
		var p := _states[i]
		if values.has(p.key) and not is_same(saved[i], MISSING):
			if not StateEncoding.nearly_equal(saved[i], values[p.key], p.encoding):
				return false
	if custom.size() == _custom_paths.size():
		var saved_custom: Variant = _state_custom[tick % history_size]
		for i in custom.size():
			if saved_custom is Array and saved_custom[i] is Dictionary and custom[i] is Dictionary and saved_custom[i] != custom[i]:
				return false
	return true


## Overwrites saved list entries for a tick with what the authority says was true, then follow with
## TickDriver.rollback(tick) to replay from them. Entries not given stay as predicted. Returns true if the history took it.
## If that tick has already fallen out of the history, a replay is impossible, so this snaps the entity straight to the
## given values and warns, and returns false (netcode spec section 15). A tick that hasn't happened yet changes nothing.
## Claude 2026-11-05: custom corrects what save_state saved. The replay's first step then hands it to load_state.
func correct_state(tick: int, values: Dictionary, custom: Array = []) -> bool:
	var custom_usable := custom.size() == _custom_paths.size() and not custom.is_empty()
	if has_state(tick):
		var saved: Array = _state_values[tick % history_size]
		for i in _states.size():
			var p := _states[i]
			if values.has(p.key):
				saved[i] = _rounded_copy(p, values[p.key])
		if custom_usable:
			_state_custom[tick % history_size] = custom
		return true
	if tick < 0 or tick > _newest_state_tick:
		return false
	_warn_once("correct_expired", "[TickStateComponent] %s: correction for tick %d is older than the history (%d ticks kept); snapping without a replay" % [_root.name, tick, history_size])
	for p in _states:
		if values.has(p.key) and _bind(p):
			p.write(_rounded_copy(p, values[p.key]))
	if custom_usable:
		_load_customs(custom)
	_notify_loaded(tick)
	return false


## Every declared entry with its kind and encoding, in order. Same code on two machines gives the same list;
## the handshake will compare a hash of these (netcode spec section 5.4).
func get_schema() -> PackedStringArray:
	var out := PackedStringArray()
	for pair in [["input", input_properties], ["state", state_properties], ["sync", sync_properties]]:
		for entry in pair[1]:
			out.append("%s %s" % [pair[0], entry])
	# Claude 2026-11-05: custom state goes in snapshots now too, so both sides need to have the same.
	var parent := get_parent()
	if parent and parent.has_method(&"save_state"):
		out.append("custom parent")
	for path in custom_state_nodes:
		out.append("custom %s" % path)
	return out


# --- Internals -----------------------------------------------------------------------------------

## Reads each property, rounds it, writes it back if rounding changed it. Reuses the slot's array, so a tick
## doesn't allocate once the ring is full (Arrays and Dictionaries in the list are the exception: they're copied).
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
	if value is Object:
		_warn_once(p.entry, "[TickStateComponent] %s: '%s' holds an Object, which can't be copied into the history, so it won't roll back. Use save_state/load_state, or list an id." % [_root.name, p.entry])


## True if this tick saved at least one property or custom state.
func _slot_has_anything(slot: int) -> bool:
	for v in _state_values[slot]:
		if not is_same(v, MISSING):
			return true
	var saved = _state_custom[slot]
	if saved is Array:
		for s in saved:
			if s is Dictionary:
				return true
	return false


## Claude 2026-11-04: replay step 1 when following the server. Remembers what the entity has now and finds the server state to start
## from. False, so it sits the replay out, if the server hasn't sent anything.
func _begin_following(tick: int) -> bool:
	if _newest_authoritative_tick < 0 or _states.is_empty():
		return false
	# Claude 2026-11-04: without both, it only holds still, which is much less accurate. A door has neither, so stays quiet.
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


## Claude 2026-11-04: stands the entity where the server says for this tick, or estimates from the last state it sent.
func _follow_tick(tick: int) -> void:
	if _authoritative_ticks[tick % history_size] == tick:
		_replay_base_tick = tick
	if _replay_base_tick < 0:
		return
	_apply(_states, _authoritative_values[_replay_base_tick % history_size])
	if tick > _replay_base_tick:
		_extrapolate(float(tick - _replay_base_tick))


## Claude 2026-11-04: velocity-only prediction: moves on from the server's position, up to the cap. No steering, gravity
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


func _restore_slot(slot: int) -> void:
	_apply(_states, _state_values[slot])
	_load_customs(_state_custom[slot])


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
	var parts := entry.split("@", false, 1)
	var key := parts[0].strip_edges() if parts.size() > 0 else ""
	if key == "":
		_warn_once(entry, "[TickStateComponent] %s: empty entry '%s' skipped" % [_root.name, entry])
		return null
	var p := Prop.new()
	p.entry = entry
	p.key = key
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
