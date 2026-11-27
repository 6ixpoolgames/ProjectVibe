## Written by Claude (claude-opus-5-5), 2026-11-23: what the mass battle would cost to send, three ways (netcode spec 19.10, the owner's
## request: profile before choosing). Not pass/fail: it prints tables. Offline and headless, so it measures the data, not a network: run
## mass_battle_net_measure for real bandwidth and the server's sending time.
##
## Each counted tick, from the real game state:
##   - Snapshots (today): every pawn's entry as the server would encode it (NetworkSession.delta_state_lists, NetPackets.write_world),
##     against the previous snapshot, as a client that acknowledges quickly would have it; how many entities had no change and what they
##     still cost; which state entries cost the most; and how well a whole snapshot compresses (zstd).
##   - Commands: each AI pawn's applied input, sent when it changes (its changed values, plus 3 bytes to say which pawn). The data a
##     command stream or an input-based replay holds.
##   - Orders, at two levels: decisions (a behaviour switch, a target change), which clients would turn into movement by running the
##     behaviours; and steering (a new path goal, a button pressed), which clients would turn into movement with nav and abilities.
##     Sized at 3 bytes for the pawn, 1 for the kind, then a goal as three 24-bit centimetre values (9), a target as a 24-bit id (3), a
##     behaviour or button as 1. Estimates of a format that doesn't exist yet.
## Snapshot framing (packet headers, parts) and acknowledgements aren't counted; the order and command sizes are what a design could
## reach, not measured packets.
##
## Run from the project folder, headless, with a fixed frame time so game time doesn't depend on speed:
##   godot --headless --fixed-fps 60 --path . "res://assets/scripts/samples/tests/net_cost_measure.tscn" -- --size=100
## Settings, after "--": --size=N (each faction's soldiers, 100), --seconds=N (40), --from=N (seconds before counting, 10),
## --spawn-distance=N (40: the factions meet within seconds, so it's the fight that's measured; 300 is the march), --snapshot-rate=N (30).
## The load ladder is pinned (every AI pawn every tick), so the numbers don't depend on this machine's speed.
## Test code: it reaches into TickStateComponent and the AI's PathFollower the way tests do (docs/TEST_AND_DEBUG_CODE.md).
extends Node

const PAWN_BYTES := 3
const KIND_BYTES := 1
const GOAL_BYTES := 9
const TARGET_BYTES := 3
const SMALL_BYTES := 1

var _size := 100
var _seconds := 40
var _from := 10
var _spawn_distance := 40.0
var _snapshot_rate := 30
var _interval := 2

var _snapshots := 0
var _pawn_snapshots := 0
var _snapshot_bytes := 0
var _compressed_bytes := 0
var _full_entities := 0
var _full_bytes := 0
var _unchanged_entities := 0
var _unchanged_bytes := 0
var _entry_bytes := {} # state entry -> value bytes sent for it
var _entry_names := {} # TickStateComponent -> its state entries, without the pawn-specific part

var _ticks := 0
var _ai_pawn_ticks := 0
var _command_bytes := 0
var _commands := 0
var _decisions := {"behaviour": 0, "target": 0}
var _steering := {"goal": 0, "press": 0}
var _last := {} # pawn instance id -> [behaviour, target id, goal, held_actions]


func _ready() -> void:
	for arg in OS.get_cmdline_user_args():
		var parts := arg.trim_prefix("--").split("=", true, 1)
		var value: String = parts[1] if parts.size() > 1 else ""
		match parts[0]:
			"size":
				_size = int(value)
			"seconds":
				_seconds = int(value)
			"from":
				_from = int(value)
			"spawn-distance":
				_spawn_distance = float(value)
			"snapshot-rate":
				_snapshot_rate = maxi(int(value), 1)
	# Every entity keeps its history offline, so a snapshot can be priced against the previous one.
	get_tree().node_added.connect(func(node: Node) -> void:
		if node is NetworkEntity:
			(node as NetworkEntity).keep_history_offline = true)
	if GameMode.replay_recorder:
		GameMode.replay_recorder.enabled = false
	TickDriver.load_step_override = 1
	_run.call_deferred()


func _run() -> void:
	var arena: Node = load("res://assets/scenes/samples/mass_battle_sample.tscn").instantiate()
	arena.team_size = _size
	add_child(arena)
	arena.spawn_distance = _spawn_distance
	await get_tree().physics_frame
	arena._start_offline()
	var rate := TickDriver.get_tick_rate()
	_interval = maxi(1, roundi(float(rate) / _snapshot_rate))
	print("[cost] %d a faction, spawns %d m out, %d s counted from %d s, %d ticks a second, a snapshot every %d ticks" % [_size,
		roundi(_spawn_distance), _seconds - _from, _from, rate, _interval])
	TickDriver.after_tick.connect(_on_after_tick)
	for i in _seconds * rate:
		await get_tree().physics_frame
	TickDriver.after_tick.disconnect(_on_after_tick)
	_print_results(rate)
	get_tree().quit(0)


func _on_after_tick(_dt: float, tick: int) -> void:
	var counting := tick >= _from * TickDriver.get_tick_rate()
	if counting:
		_ticks += 1
	var snapshot := PackedByteArray()
	var is_snapshot_tick := counting and tick % _interval == 0
	for node in get_tree().get_nodes_in_group(Pawn.GROUP):
		var pawn := node as Pawn
		var entity := pawn.get_network_entity() if pawn else null
		if entity == null or entity.state == null:
			continue
		if is_snapshot_tick:
			snapshot.append_array(_price_snapshot_entry(entity, tick))
		_note_ai(pawn, entity.state, tick, counting)
	if is_snapshot_tick:
		_snapshots += 1
		_snapshot_bytes += snapshot.size()
		_compressed_bytes += snapshot.compress(FileAccess.COMPRESSION_ZSTD).size()


# One pawn's entry, encoded as the server would send it this snapshot: in full if it has nothing saved from the previous one, else as
# its changes. Returns the bytes, and counts them.
func _price_snapshot_entry(entity: NetworkEntity, tick: int) -> PackedByteArray:
	var state := entity.state
	var now := state.get_state_values(tick)
	var encodings := state.get_state_encodings()
	var sync := [state.get_sync_values(), state.get_sync_encodings(), [], [], state.get_custom_values(tick)]
	var then := state.get_state_values(tick - _interval) if state.has_state(tick - _interval) else []
	var entry: Array
	var full := then.size() != now.size()
	if full:
		entry = [entity.entity_id, now, encodings]
	else:
		var lists: Array = NetworkSession.delta_state_lists(now, then, encodings, _interval)
		entry = [entity.entity_id | NetworkSession.DELTA_ID_BIT, lists[0], lists[1]]
	entry.append_array(sync)
	var bytes := NetPackets.write_world(entry) # one entity's items, laid out flat as the server's snapshot lists them
	_pawn_snapshots += 1
	if full:
		_full_entities += 1
		_full_bytes += bytes.size()
		return bytes
	if now == then:
		_unchanged_entities += 1
		_unchanged_bytes += bytes.size()
		return bytes
	var names := _entry_names_of(state)
	for i in now.size():
		if typeof(now[i]) == typeof(then[i]) and now[i] == then[i]:
			continue
		var buffer := NetPackets.new_buffer()
		NetPackets.write_value(buffer, now[i], encodings[i] if i < encodings.size() else StateEncoding.RAW)
		var name: String = names[i] if i < names.size() else "?"
		_entry_bytes[name] = int(_entry_bytes.get(name, 0)) + buffer.data_array.size()
	return bytes


func _entry_names_of(state: TickStateComponent) -> Array:
	if not _entry_names.has(state):
		var names: Array = []
		for p in state._states:
			names.append(String(p.entry).replace("AbilityManager/", ""))
		_entry_names[state] = names
	return _entry_names[state]


# An AI pawn's command (its applied input, when it changes) and its orders (decisions and steering) this tick.
func _note_ai(pawn: Pawn, state: TickStateComponent, tick: int, counting: bool) -> void:
	if pawn.controller_manager == null or pawn.controller_manager.has_player() or pawn.ai == null or pawn.is_dead():
		return
	var id := pawn.get_instance_id()
	var behaviours := pawn.ai.behaviour_manager
	var running: Variant = behaviours.get_running_behaviour() if behaviours else null
	var target := pawn.ai.current_target
	var navigation: PathFollower = pawn.controller_manager.get_path_follower() if pawn.controller_manager else null # Claude 2026-11-27: the running move step's (pawn spec 16.10 step 7)
	var goal: Variant = navigation._goal if navigation and navigation._state != PathFollower.PathState.NONE else null
	var held := pawn.controller_manager.held_actions
	var now := [running, target.get_instance_id() if is_instance_valid(target) else 0, goal, held]
	var last: Array = _last.get(id, [])
	_last[id] = now
	if not counting:
		return
	_ai_pawn_ticks += 1
	# The command: the input list, as changes since last tick.
	var inputs := state.get_input_values(tick)
	var before := state.get_input_values(tick - 1)
	if not inputs.is_empty() and inputs.size() == before.size() and inputs != before:
		var lists: Array = NetworkSession.delta_state_lists(inputs, before, state.get_input_encodings(), 1)
		var buffer := NetPackets.new_buffer()
		NetPackets.write_list(buffer, lists[0], lists[1])
		_commands += 1
		_command_bytes += PAWN_BYTES + buffer.data_array.size()
	if last.is_empty():
		return
	if now[0] != last[0]:
		_decisions["behaviour"] += 1
	if now[1] != last[1]:
		_decisions["target"] += 1
	if now[2] != null and now[2] != last[2]:
		_steering["goal"] += 1
	var pressed: int = now[3] & ~int(last[3]) # buttons down now that weren't
	while pressed != 0:
		_steering["press"] += pressed & 1
		pressed >>= 1


func _print_results(rate: int) -> void:
	var seconds := float(_ticks) / rate
	if seconds <= 0.0 or _snapshots == 0:
		print("[cost] nothing counted")
		return
	var pawns := float(_pawn_snapshots) / _snapshots
	var ai_pawns := float(_ai_pawn_ticks) / maxi(_ticks, 1)
	print("[cost] pawns on average: %.0f, of which AI: %.0f" % [pawns, ai_pawns])
	var per_snapshot := float(_snapshot_bytes) / _snapshots
	print("[cost] snapshots: %.0f bytes each, %.1f KB/s a client at %d a second; %.1f bytes a pawn" % [per_snapshot,
		per_snapshot * _snapshot_rate / 1024.0, _snapshot_rate, per_snapshot / pawns])
	print("[cost]   compressed (zstd, a whole snapshot): %.0f bytes, %.0f%% of it" % [float(_compressed_bytes) / _snapshots,
		100.0 * _compressed_bytes / _snapshot_bytes])
	print("[cost]   unchanged since the last snapshot: %.0f%% of pawn entries, still %.1f bytes each (%.0f%% of all bytes)" % [
		100.0 * _unchanged_entities / _pawn_snapshots, float(_unchanged_bytes) / maxi(_unchanged_entities, 1), 100.0 * _unchanged_bytes / _snapshot_bytes])
	print("[cost]   sent in full (new to the snapshot): %d entries, %.0f bytes each" % [_full_entities, float(_full_bytes) / maxi(_full_entities, 1)])
	var entries: Array = _entry_bytes.keys()
	entries.sort_custom(func(a, b): return _entry_bytes[a] > _entry_bytes[b])
	var changed_values := 0
	for entry in entries:
		changed_values += int(_entry_bytes[entry])
	print("[cost]   changed values, by entry (bytes a second a client, share of the values):")
	for i in mini(entries.size(), 10):
		var entry: String = entries[i]
		print("[cost]     %-50s %8.1f KB/s  %4.0f%%" % [entry, _entry_bytes[entry] / seconds / 1024.0,
			100.0 * _entry_bytes[entry] / maxi(changed_values, 1)])
	print("[cost] commands (AI pawns' applied input, when it changes): %.0f a second, %.1f KB/s; %.2f a pawn a second" % [_commands / seconds,
		_command_bytes / seconds / 1024.0, _commands / seconds / maxf(ai_pawns, 1.0)])
	var decision_bytes: float = _decisions["behaviour"] * (PAWN_BYTES + KIND_BYTES + SMALL_BYTES) + _decisions["target"] * (PAWN_BYTES + KIND_BYTES + TARGET_BYTES)
	var steering_bytes: float = _steering["goal"] * (PAWN_BYTES + KIND_BYTES + GOAL_BYTES) + _steering["press"] * (PAWN_BYTES + KIND_BYTES + SMALL_BYTES)
	print("[cost] orders, decisions (behaviour switches %.0f/s, target changes %.0f/s): %.2f KB/s" % [_decisions["behaviour"] / seconds,
		_decisions["target"] / seconds, decision_bytes / seconds / 1024.0])
	print("[cost] orders, steering (new path goals %.0f/s, buttons pressed %.0f/s): %.2f KB/s" % [_steering["goal"] / seconds,
		_steering["press"] / seconds, steering_bytes / seconds / 1024.0])
