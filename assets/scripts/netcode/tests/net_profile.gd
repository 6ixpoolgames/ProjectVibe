## Written by Claude (claude-opus-5-5), 2026-11-05: where the time goes as pawn counts grow, to plan any move to C++ from real data.
## Two parts. Micro-timings of the hot operations, one at a time, in this process. Then a real server with AI pawns walking nav paths
## on hills, at growing counts, with one client watching them and one client with pawns of its own. Prints tables; it doesn't pass or
## fail. Takes several minutes.
##   Godot_v4.4.1-stable_win64.exe --headless --path . "res://assets/scripts/netcode/tests/net_profile.tscn"
## Add -- --micro to run only the micro-timings, -- --counts=50,100 to choose the pawn counts, and -- --nav to run only the
## navigation rows: heavy path demand, and terrain edits during play. -- --script-encoding sends snapshots through NetPackets instead
## of C++, to compare.
##
## How to read the tables: "whole physics frame" is everything in a physics frame, including the physics engine's own step. "Tick work"
## is NetworkTime's ticks inside that. All of it has to fit in 16.7 ms at 60 ticks/s. The rest of the frame is rendering, which a
## headless server doesn't have and a real client does.
extends Node

const SECONDS := 18
const MEASURE_AFTER := 6.0
const CLIENT_WALKERS := 4
const DEFAULT_COUNTS := [25, 50, 100, 200, 400]
const PHASES := ["before_tick", "input", "capture", "simulate", "record", "after_tick"]
const SESSION_PARTS := ["flush", "reconcile", "remote", "send_inputs", "send_snapshots"]

var _port := NetRun.first_port()
var _counts: Array = DEFAULT_COUNTS
var _micro_only := false
var _nav_only := false
var _script_encoding := false # Claude 2026-11-05


func _ready() -> void:
	for argument in OS.get_cmdline_user_args():
		if argument == "--micro":
			_micro_only = true
		elif argument == "--nav":
			_nav_only = true
		elif argument == "--script-encoding":
			_script_encoding = true
		elif argument.begins_with("--counts="):
			_counts = Array(argument.trim_prefix("--counts=").split(",")).map(func(c: String) -> int: return int(c))
	print("--- Multiplayer profile (physics engine: %s) ---" % ProjectSettings.get_setting("physics/3d/physics_engine", "DEFAULT"))
	await _micro_timings()
	if not _micro_only and not _nav_only:
		for count: int in _counts:
			await _measure(count)
	if not _micro_only:
		await _measure_nav("100 pawns, paths as needed", {})
		await _measure_nav("100 pawns, every pawn finds a new path every second", {"repath-every": 60})
		await _measure_nav("100 pawns, every pawn finds a new path 6 times a second", {"repath-every": 10})
		await _measure_nav("100 pawns, terrain edit every 3 s", {"edit-every": 180})
		await _measure_nav("100 pawns, terrain edit every 1 s, new paths every second", {"edit-every": 60, "repath-every": 60})
		await _measure_nav("100 pawns, terrain edit every 0.5 s until tick 800, then none", {"edit-every": 30, "edit-until": 800})
	print("--- DONE ---")
	get_tree().quit(0)


# --- One operation at a time ---------------------------------------------------------------------

func _micro_timings() -> void:
	var session: NetworkSessionSingleton = get_node("/root/NetworkSession")
	var nav: Object = Engine.get_singleton(&"NavServer")
	nav.configure({"worker_threads": 2})
	nav.add_interest(Vector3.ZERO, 130.0, 160.0, 1)
	var world := Node3D.new()
	add_child(world)
	var terrain: Node3D = load("res://assets/scripts/navigation/nav_test_terrain.gd").new()
	terrain.set("nav_hooks", NavHooks.new())
	terrain.set("build_collision", true)
	world.add_child(terrain)
	for i in 240:
		nav.tick(1.0 / 60.0)
		await get_tree().physics_frame
	session.world_root = world
	session.register_type("pawn", load("res://assets/scripts/netcode/tests/net_test_pawn.tscn"))
	NetTestPawn.default_mode = "idle"
	var body: NetTestPawn = session.spawn("pawn", 1, Vector3(20, float(terrain.call("height_at", 20.0, 20.0)) + 0.3, 20))
	var state: TickStateComponent = body.get_node("TickState")
	var entity: NetworkEntity = body.get_node("NetworkEntity")
	for i in 30:
		await get_tree().physics_frame
	var tick: int = (get_node("/root/NetworkTime") as NetworkTimeSingleton).tick

	print("")
	print("Microseconds per call, one pawn on hills, in GDScript unless it says otherwise:")
	body.velocity = Vector3(3, 0, 1)
	_report("move_and_slide alone (engine, C++)", _time_calls(2000, func() -> void:
		body.velocity = Vector3(3, 0, 1)
		body.position = Vector3(20, body.position.y, 20)
		body.move_and_slide()))
	_report("whole simulate of a pawn (includes move_and_slide)", _time_calls(2000, func() -> void:
		body.position = Vector3(20, body.position.y, 20)
		body.move_dir = Vector3(1, 0, 0)
		body._tick_simulate(1.0 / 60.0, tick)))
	_report("save input for a tick (_tick_capture_input)", _time_calls(5000, func() -> void: state._tick_capture_input(tick)))
	_report("save state for a tick (_tick_record)", _time_calls(5000, func() -> void: state._tick_record(tick)))
	_report("load state for a rollback, without the engine floor refresh", _time_calls(5000, func() -> void: state._restore_slot(tick % state.history_size)))
	_report("load hook: refresh the engine's floor state", _time_calls(1000, func() -> void: body._on_state_loaded(tick)))
	_report("collision sync (static flip)", _time_calls(5000, func() -> void: state._sync_collision()))
	var values := state.get_state_values(tick)
	var encodings := state.get_state_encodings()
	# Claude 2026-11-05: what _send_snapshots asks each pawn for before any encoding. The C++ encoding test can't speed this up.
	_report("gather a pawn's lists for a snapshot", _time_calls(5000, func() -> void:
		state.get_state_values(tick)
		state.get_state_encodings()
		state.get_sync_values()
		state.get_sync_encodings()
		state.get_input_encodings()
		state.get_custom_values(tick)))
	_report("encode a pawn's state for a snapshot", _time_calls(5000, func() -> void:
		var buffer := NetPackets.new_buffer()
		NetPackets.write_list(buffer, values, encodings)))
	var encoded := NetPackets.new_buffer()
	NetPackets.write_list(encoded, values, encodings)
	var encoded_bytes := encoded.data_array
	_report("decode a pawn's state from a snapshot", _time_calls(5000, func() -> void: NetPackets.read_list(NetPackets.reader(encoded_bytes))))
	var dictionary := state.state_values_to_dictionary(values)
	_report("turn decoded values into a state dictionary", _time_calls(5000, func() -> void: state.state_values_to_dictionary(values)))
	_report("store server state for later drawing", _time_calls(5000, func() -> void: state.receive_authoritative_state(tick, dictionary)))
	state.receive_authoritative_state(tick - 2, dictionary)
	state.receive_authoritative_state(tick, dictionary)
	_report("place a remote pawn between two snapshots", _time_calls(5000, func() -> void: state.follow_server_at(tick - 1.0, true)))
	_report("rewind one pawn for lag compensation and back", _time_calls(2000, func() -> void:
		entity.rewind_to(float(tick))
		entity.restore_after_rewind()))
	var from := body.position
	for trip: Array in [["short", Vector3(30, 0, 25)], ["across the arena", Vector3(-45, 0, -40)], ["to the far side of the test wall", Vector3(25, 0, -30)], ["to nowhere it can stand", Vector3(9000, 0, 9000)]]:
		var goal: Vector3 = trip[1]
		var found: PackedVector3Array = nav.find_path_now(from, goal, 0)
		var length := 0.0
		for i in range(1, found.size()):
			length += found[i - 1].distance_to(found[i])
		_report("find a nav path, %s: %.0f m, %d points (engine, C++ navcore)" % [trip[0], length, found.size()], _time_calls(300, func() -> void: nav.find_path_now(from, goal, 0)))
	session.leave()
	world.queue_free()
	await get_tree().physics_frame


func _time_calls(count: int, work: Callable) -> float:
	var started := Time.get_ticks_usec()
	for i in count:
		work.call()
	return float(Time.get_ticks_usec() - started) / count


func _report(label: String, microseconds: float) -> void:
	print("  %7.1f us  %s" % [microseconds, label])


# --- A real server, at growing counts --------------------------------------------------------------

func _measure(count: int) -> void:
	_port += 1
	var shared := {"terrain": 1, "profile": 1, "no-log": 1, "measure-after": MEASURE_AFTER}
	if _script_encoding:
		shared["script-encoding"] = 1
	var server: Dictionary = {"role": "server", "seconds": SECONDS + 3, "walkers": CLIENT_WALKERS, "ai": count, "ai-mode": "walk"}
	var client: Dictionary = {"role": "client", "seconds": SECONDS, "mode": "walk", "bench-ping": 100}
	server.merge(shared)
	client.merge(shared)
	var results := await NetRun.run(self, "profile_%d" % count, {"server": server, "client": client}, _port)
	print("")
	print("[%d AI pawns, plus %d of one client's]" % [count, CLIENT_WALKERS])
	if results["server"].has("timed_out") or results["client"].has("timed_out"):
		print("didn't finish")
		return
	_print_machine("server", results["server"], count + CLIENT_WALKERS)
	_print_machine("client", results["client"], count + CLIENT_WALKERS)


## Navigation under load: what it costs, and whether pawns on top of it still behave.
func _measure_nav(label: String, extra: Dictionary) -> void:
	_port += 1
	var shared := {"terrain": 1, "profile": 1, "no-log": 1, "measure-after": MEASURE_AFTER}
	var server: Dictionary = {"role": "server", "seconds": SECONDS + 3, "walkers": CLIENT_WALKERS, "ai": 100, "ai-mode": "walk"}
	var client: Dictionary = {"role": "client", "seconds": SECONDS, "mode": "walk", "bench-ping": 100}
	server.merge(shared)
	client.merge(shared)
	server.merge(extra)
	client.merge(extra)
	var results := await NetRun.run(self, "profile_nav_%d" % _port, {"server": server, "client": client}, _port)
	print("")
	print("[%s]" % label)
	if results["server"].has("timed_out") or results["client"].has("timed_out"):
		print("didn't finish")
		return
	for machine_name: String in ["server", "client"]:
		var machine: Dictionary = results[machine_name]
		var nav: Dictionary = machine.get("nav_stats", {})
		var stuck := 0
		var failures := 0
		var fell := 0
		for entity: Dictionary in machine.get("summaries", []):
			stuck += int(entity.get("stuck", 0))
			failures += int(entity.get("path_failures", 0))
			if float(entity.get("y", 0.0)) < -30.0:
				fell += 1
		print("%s: whole physics frame avg %.1f ms, worst %.0f ms; tick work %.1f ms; nav tick avg %.2f ms, worst %.1f ms" % [machine_name, float(machine.get("physics_average_ms", 0.0)), float(machine.get("physics_worst_ms", 0.0)), float(machine["loop_average_ms"]), float(machine.get("nav_tick_average_ms", 0.0)), float(machine.get("nav_tick_worst_ms", 0.0))])
		print("  paths: %d found, %.0f us each, %d failed, %d stuck, %d fell. Edits: %d, avg %.1f ms, worst %.1f ms. Tiles built: %d, avg %.2f ms, worst %.2f ms, commit worst %.2f ms, %d stale, %d failed" % [
			int(machine.get("path_calls", 0)), float(machine.get("path_usec", 0)) / maxi(int(machine.get("path_calls", 0)), 1), failures, stuck, fell,
			int(machine.get("edits", 0)), float(machine.get("edit_average_ms", 0.0)), float(machine.get("edit_worst_ms", 0.0)),
			int(nav.get("builds_committed", 0)), float(nav.get("avg_build_ms", 0.0)), float(nav.get("max_build_ms", 0.0)), float(nav.get("max_commit_ms", 0.0)), int(nav.get("builds_stale", 0)), int(nav.get("failed", 0))])
		if machine_name == "client":
			print("  corrections: %d, worst %.2f m, largest jump %.2f m; %d resyncs" % [int(machine["stats"]["corrections"]), float(machine["stats"]["correction_worst"]), float(machine["stats"]["jump_worst"]), int(machine["stats"]["resyncs"])])
		print("  physics frame ms, each second: %s" % str(machine.get("physics_by_second", [])))


func _print_machine(label: String, machine: Dictionary, pawns: int) -> void:
	var profile: Dictionary = machine.get("profile", {})
	var ticks := maxf(float(profile.get("ticks", 1)), 1.0)
	var per_tick := func(key: String) -> float: return float(profile.get(key, 0)) / ticks / 1000.0
	var phase_text := PackedStringArray()
	for phase: String in PHASES:
		phase_text.append("%s %.2f" % [phase, per_tick.call(phase)])
	var part_text := PackedStringArray()
	for part: String in SESSION_PARTS:
		if float(profile.get(part, 0)) > 0.0:
			part_text.append("%s %.2f" % [part, per_tick.call(part)])
	var band := NetRun.bandwidth(machine)
	print("%s: whole physics frame avg %.1f ms, worst %.0f ms; tick work %.1f ms, or %.0f us per pawn; %d of %d frames over 16.7 ms; %d ticks dropped" % [
		label, float(machine.get("physics_average_ms", 0.0)), float(machine.get("physics_worst_ms", 0.0)), float(machine["loop_average_ms"]),
		1000.0 * float(machine["loop_average_ms"]) / pawns, int(machine.get("physics_over_budget", 0)), int(machine.get("physics_frames", 0)), int(machine["dropped_ticks"])])
	print("  ms per tick: %s" % ", ".join(phase_text))
	print("  of which network: %s" % ", ".join(part_text))
	print("  nav paths: %d, %.0f us each. %.1f KB/s sent, %.1f KB/s received. Physics engine reports %d active objects." % [
		int(machine.get("path_calls", 0)), float(machine.get("path_usec", 0)) / maxi(int(machine.get("path_calls", 0)), 1), band["sent"] / 1000.0, band["received"] / 1000.0, int(machine.get("active_objects", 0))])
	if int(profile.get("rollbacks", 0)) > 0:
		print("  rollbacks: %d, %.0f us each, replaying %.1f ticks on average" % [int(profile["rollbacks"]), float(profile["rollback"]) / int(profile["rollbacks"]), float(profile["rollback_ticks"]) / int(profile["rollbacks"])])
