## Written by Claude (claude-opus-5-5), 2026-11-19: two measurements for the state store refactor (state store spec section 13): the
## state inventory and re-simulation drift. Not pass/fail: it prints tables.
##
## Run from the project folder, headless, with a fixed frame time so game time doesn't depend on speed:
##   godot --headless --fixed-fps 60 --path . "res://assets/scripts/samples/tests/state_inventory_measure.tscn" -- --size=50 --seconds=40 --spawn-distance=40
## For drift from physics alone: --spawn-distance=300 (marching, no fighting, so no hits) and --no-crowd (every pawn moves by physics).
##
## 1. Inventory: every tick from --from= seconds (10) on, it reads each pawn's rolled-back state entries (its TickStateComponent's state
##    list) and input entries, and counts how often each entry changes from one tick to the next. Per entry: its type, encoding, how many
##    pawns have it, and the share of pawn-ticks it changed on. Also the C++ recorder's cost per pawn to read and round its state list.
## 2. Drift: at the end it saves every pawn's state, rolls the whole game back --rewind= ticks (30) with TickDriver.rollback, which loads
##    the saved state and re-runs the ticks from the recorded inputs, then compares. Today's rollback doesn't deliver hits while
##    re-running (after_simulate isn't sent) and doesn't run the crowd mover's batch, so differences there are expected; the table shows
##    which entries differ and by how much.
## Test code: it reaches into TickStateComponent's entry list (_states, _bind) the way tests do (docs/TEST_AND_DEBUG_CODE.md).
extends Node

var _size := 50
var _seconds := 40
var _from := 10
var _rewind := 30
var _no_crowd := false
var _changes := {} # entry -> times it changed
var _seen := {} # entry -> pawn-ticks it was read
var _types := {} # entry -> "type encoding"
var _last := {} # "pawn id|index" -> value last tick
var _input_changes := {}
var _input_seen := {}
var _last_input := {}
var _record_usec := 0
var _record_pawns := 0


func _ready() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--size="):
			_size = int(arg.trim_prefix("--size="))
		elif arg.begins_with("--seconds="):
			_seconds = int(arg.trim_prefix("--seconds="))
		elif arg.begins_with("--from="):
			_from = int(arg.trim_prefix("--from="))
		elif arg.begins_with("--rewind="):
			_rewind = int(arg.trim_prefix("--rewind="))
		elif arg == "--no-crowd":
			_no_crowd = true
	# Every entity keeps history offline, so rollback has saved state and inputs to go back to.
	get_tree().node_added.connect(func(node: Node) -> void:
		if node is NetworkEntity:
			(node as NetworkEntity).keep_history_offline = true)
	if GameMode.replay_recorder:
		GameMode.replay_recorder.enabled = false
	_run.call_deferred()


func _run() -> void:
	var arena: Node = load("res://assets/scenes/samples/mass_battle_sample.tscn").instantiate()
	arena.team_size = _size
	add_child(arena)
	await get_tree().physics_frame
	arena._start_offline()
	# --no-crowd: every pawn moves by physics, so re-running doesn't miss the crowd mover's batch (which a rollback doesn't run).
	if _no_crowd and CrowdMover.current:
		CrowdMover.current.enabled = false
	var rate := TickDriver.get_tick_rate()
	print("[inventory] %d a faction, %d s, counting from %d s, %d ticks a second, debug build %s" % [_size, _seconds, _from, rate, OS.is_debug_build()])
	TickDriver.after_tick.connect(_on_after_tick)
	for i in _seconds * rate:
		await get_tree().physics_frame
	TickDriver.after_tick.disconnect(_on_after_tick)
	_print_inventory()
	await _measure_drift()
	get_tree().quit(0)


func _states_of_pawns() -> Array:
	var out: Array = []
	for node in get_tree().get_nodes_in_group(Pawn.GROUP):
		var pawn := node as Pawn
		if pawn == null or not pawn.is_inside_tree():
			continue
		for child in pawn.get_children():
			if child is TickStateComponent:
				out.append([pawn, child])
				break
	return out


func _on_after_tick(_dt: float, tick: int) -> void:
	if tick < _from * TickDriver.get_tick_rate():
		return
	for pair: Array in _states_of_pawns():
		var pawn: Pawn = pair[0]
		var state: TickStateComponent = pair[1]
		var id := pawn.get_instance_id()
		_count(state._states, id, _changes, _seen, _last, true)
		_count(state._inputs, id, _input_changes, _input_seen, _last_input, false)
	# The store's commit, which read and rounded every bound entity's whole state list this tick (Claude 2026-11-19: was a timed call
	# of the old C++ recorder per pawn).
	var stats: Dictionary = TickDriver.store.get_stats()
	_record_usec += int(stats["commit_usec"])
	_record_pawns += int(stats["bound"])


func _count(props: Array, id: int, changes: Dictionary, seen: Dictionary, last: Dictionary, note_types: bool) -> void:
	for i in props.size():
		var p = props[i]
		if not is_instance_valid(p.node):
			continue
		var value: Variant = p.read()
		var key := Vector2i(id, i)
		var entry: String = _generic(p.entry)
		seen[entry] = int(seen.get(entry, 0)) + 1
		if note_types and not _types.has(entry):
			_types[entry] = "%s %s" % [type_string(typeof(value)), p.encoding]
		if last.has(key) and last[key] != value:
			changes[entry] = int(changes.get(entry, 0)) + 1
		last[key] = value


# An entry without the pawn-specific part of its node path, so the same entry on every pawn counts together.
func _generic(entry: String) -> String:
	return entry.replace("AbilityManager/", "")


func _print_inventory() -> void:
	var entries: Array = _seen.keys()
	entries.sort_custom(func(a, b): return float(_changes.get(a, 0)) / _seen[a] > float(_changes.get(b, 0)) / _seen[b])
	print("[inventory] state entries: %d kinds" % entries.size())
	print("[inventory] %-52s %-22s %10s %9s" % ["entry", "type encoding", "pawn-ticks", "changed"])
	for entry in entries:
		print("[inventory] %-52s %-22s %10d %8.1f%%" % [entry, _types.get(entry, "?"), _seen[entry], 100.0 * _changes.get(entry, 0) / _seen[entry]])
	var input_entries: Array = _input_seen.keys()
	for entry in input_entries:
		print("[inventory] input %-46s %33d %8.1f%%" % [entry, _input_seen[entry], 100.0 * _input_changes.get(entry, 0) / _input_seen[entry]])
	print("[inventory] the store's commit, reading and rounding one entity's state list: %.2f us (over %d entity-ticks)" % [float(_record_usec) / maxi(_record_pawns, 1), _record_pawns])


func _measure_drift() -> void:
	# Between ticks, so rollback is allowed: save every pawn's state now, roll back, re-run, compare.
	await get_tree().physics_frame
	var before := {}
	var pairs := _states_of_pawns()
	for pair: Array in pairs:
		var state: TickStateComponent = pair[1]
		var values: Array = []
		for p in state._states:
			values.append(p.read() if is_instance_valid(p.node) else null)
		before[(pair[0] as Pawn).get_instance_id()] = values
	var now := TickDriver.tick
	var started := Time.get_ticks_usec()
	var rolled := TickDriver.rollback(now - _rewind)
	var usec := Time.get_ticks_usec() - started
	print("[drift] rolled back %d ticks from %d: %s, %.1f ms for %d pawns" % [_rewind, now, "ok" if rolled else "REFUSED", usec / 1000.0, pairs.size()])
	var differ := {}
	var worst := {}
	var pawns_differing := 0
	for pair: Array in pairs:
		var pawn: Pawn = pair[0]
		var state: TickStateComponent = pair[1]
		var old: Array = before.get(pawn.get_instance_id(), [])
		var any := false
		for i in mini(old.size(), state._states.size()):
			var p = state._states[i]
			if not is_instance_valid(p.node):
				continue
			var value: Variant = p.read()
			if old[i] == null or StateEncoding.nearly_equal(old[i], value, p.encoding):
				continue
			any = true
			var entry := _generic(p.entry)
			differ[entry] = int(differ.get(entry, 0)) + 1
			if (value is Vector3 or value is float) and typeof(old[i]) == typeof(value):
				var size: float = (value - old[i]).length() if value is Vector3 else absf(value - old[i])
				worst[entry] = maxf(float(worst.get(entry, 0.0)), size)
		if any:
			pawns_differing += 1
	print("[drift] pawns whose state differs after re-running: %d of %d" % [pawns_differing, pairs.size()])
	var entries: Array = differ.keys()
	entries.sort_custom(func(a, b): return differ[a] > differ[b])
	for entry in entries:
		print("[drift] %-52s %5d pawns   largest %s" % [entry, differ[entry], ("%.4f" % worst[entry]) if worst.has(entry) else "-"])
