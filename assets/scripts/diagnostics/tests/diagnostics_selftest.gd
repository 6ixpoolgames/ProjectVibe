## Written by Claude (claude-opus-5-5), 2026-11-16: headless self-test for diagnostics v0 (docs/diagnostics/DIAGNOSTICS_SPEC.md):
## PerfScopes, the DiagnosticsManager's history, spikes, warnings, session log, summaries, the editor's monitors, its replay channel,
## captures, the panels, and always-on recordings.
## Exits 0 on success, 1 on failure. Run from the project folder:
##   godot --headless --path . "res://assets/scripts/diagnostics/tests/diagnostics_selftest.tscn"
extends SelfTest # Claude 2026-11-16 (wider audit): _check and _failures come from tests/SelfTest.gd now

const PAWN_SCENE := "res://assets/scenes/pawn/pawn.tscn"
const NO_AI: Array[StringName] = [&"AISensingManager", &"AIMemory", &"AITargetSelector", &"AIStateManager", &"AIBehaviourManager"]
const FOLDER := "user://diagnostics_selftest"

var _slow_frames := 0 # a frame that busy-waits this many times 40 ms, to make a spike


func _ready() -> void:
	print("--- Diagnostics self-test ---")
	TickDriver.tick_rate = TickDriver.REFERENCE_RATE
	var manager := GameMode.get_module(DiagnosticsManager) as DiagnosticsManager
	_check(manager != null and PerfScopes.enabled, "GameMode has diagnostics in a debug build (the project setting), and scopes are on")
	if manager == null:
		_finish()
		return
	_test_scopes()
	var floor_body := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(20, 1, 20)
	shape.shape = box
	shape.position.y = -0.5
	floor_body.add_child(shape)
	add_child(floor_body)
	var pawn: Pawn = load(PAWN_SCENE).instantiate()
	pawn.name = "Inspected"
	pawn.skip_default_parts = NO_AI
	pawn.position = Vector3(0, 0.1, 0)
	add_child(pawn)
	await _frames(40)
	_test_history(manager)
	await _test_spike(manager)
	await _test_warnings(manager)
	await _test_replay(manager)
	_test_capture(manager)
	_test_panels(manager, pawn)
	_check(Performance.has_custom_monitor(&"Diagnostics/Frame (ms)") and Performance.has_custom_monitor(&"Diagnostics/Orphan nodes"),
		"the editor's Debugger > Monitors get its numbers")
	pawn.free()
	_finish()


func _test_scopes() -> void:
	PerfScopes.take_frame()
	for i in 3:
		var started := PerfScopes.begin()
		OS.delay_usec(200)
		PerfScopes.end(&"test.work", started)
	PerfScopes.add(&"test.added", 1500, 2)
	var frame := PerfScopes.take_frame()
	_check(frame.has(&"test.work") and frame[&"test.work"][1] == 3 and frame[&"test.work"][0] >= 600, "scopes add up their time and count calls (%s)" % str(frame.get(&"test.work")))
	_check(frame.get(&"test.added", []) == [1500, 2] and PerfScopes.take_frame().is_empty(), "add() takes a time measured elsewhere, and take_frame() starts afresh")
	PerfScopes.enabled = false
	_check(PerfScopes.begin() == 0, "off, begin() gives 0, so end() does nothing")
	PerfScopes.end(&"test.off", 0)
	PerfScopes.enabled = true
	_check(not PerfScopes.take_frame().has(&"test.off"), "and nothing is recorded")


func _test_history(manager: DiagnosticsManager) -> void:
	var frames := manager.get_frames()
	_check(frames.size() >= 30, "it keeps a history of frames (%d)" % frames.size())
	var last: Dictionary = frames[-1]
	var keys := ["frame", "frame_ms", "physics_ms", "scripts_ms", "rest_ms", "steps", "objects", "nodes", "orphans", "memory_kb", "scopes"]
	_check(keys.all(func(key: String) -> bool: return last.has(key)), "each frame has its times and counts")
	var seen := {}
	for record: Dictionary in frames:
		for scope: StringName in record.scopes:
			seen[scope] = true
	# Claude 2026-11-16 (pawn spec 8.22): its move is by physics (pawn.move_and_slide) or by the CrowdMover (movement.crowd)
	_check(seen.has(&"pawn.abilities") and (seen.has(&"pawn.move_and_slide") or seen.has(&"movement.crowd")) and seen.has(&"tick.simulate"),
		"the pawn's own scopes and TickDriver's phases are in it (%s)" % ", ".join(seen.keys().slice(0, 8)))
	var summary := manager.get_summary(0.5)
	_check(summary.frames > 0 and summary.has("tick_parts") and summary.scopes.size() > 0 and summary.pawns >= 1,
		"a summary averages the last seconds (%d frames, %d scopes)" % [summary.frames, summary.scopes.size()])
	_check(manager.summary_text(summary).begins_with("[summary"), "and reads as one line of text")
	# Claude 2026-11-16 (the owner's request: the server's tick rate in diagnostics): offline, the server is this machine, so its rate is
	# the tick rate and its ticks are this machine's.
	var server: Dictionary = summary.get("server", {})
	var quick := manager.get_server_ticks(0.5)
	_check(server.get("tick_rate", 0) == TickDriver.get_tick_rate() and float(server.get("ticks_per_second", 0.0)) > 0.0 and float(quick.ticks_per_second) > 0.0,
		"the summary has the server's tick rate and how fast it ran (%.1f ticks/s; get_server_ticks %.1f)" % [float(server.get("ticks_per_second", 0.0)), float(quick.ticks_per_second)])
	_check(manager.summary_text(summary).contains("server %d ticks/s" % TickDriver.get_tick_rate()), "and the log line says it")
	# Claude 2026-11-16 (the owner's request): the animation category, every animation.* scope added up, in the summary and the log line.
	_check(summary.has("animation_ms") and manager.summary_text(summary).contains("(animation "),
		"the animation category is in the summary and the log line (%.3f ms a frame)" % float(summary.get("animation_ms", -1.0)))


func _test_spike(manager: DiagnosticsManager) -> void:
	var before := manager.get_spikes().size()
	_slow_frames = 1
	await _frames(5)
	var spikes := manager.get_spikes()
	_check(spikes.size() > before and spikes[-1].frame_ms > 35.0 and spikes[-1].scripts_ms > 30.0,
		"a frame over budget is kept as a spike, with its parts (%.1f ms, scripts %.1f)" % [spikes[-1].frame_ms if not spikes.is_empty() else 0.0, spikes[-1].scripts_ms if not spikes.is_empty() else 0.0])


func _test_warnings(manager: DiagnosticsManager) -> void:
	for i in 10:
		push_warning("diagnostics self-test warning")
	await _frames(2)
	var line: Array = manager.get_log_lines().filter(func(entry: Array) -> bool: return entry[1] == "diagnostics self-test warning").front()
	_check(line != null and line[0] == "warning" and line[3] == 10, "warnings are caught and counted (%s)" % str(line))
	var log_text := FileAccess.get_file_as_string(manager.get_log_path())
	_check(log_text.begins_with("     ") or log_text.contains("session "), "a session log is written, starting with how it was run")
	_check(log_text.count("diagnostics self-test warning") == manager.repeats_logged, "a repeated warning is written in full only %d times" % manager.repeats_logged)


func _test_replay(manager: DiagnosticsManager) -> void:
	var recorder: ReplayRecorder = GameMode.replay_recorder
	recorder.folder = FOLDER
	_clear(FOLDER.path_join("host"))
	# Always on: a player taking a pawn offline starts a recording when none is running.
	manager._on_possessed(0, null)
	_check(recorder.is_recording(), "a player taking a pawn offline starts a recording (always-on replays)")
	await _frames(20)
	push_warning("diagnostics self-test warning while recording")
	await _frames(70)
	var path := recorder.get_recording_path()
	recorder.stop_recording()
	var reader := ReplayReader.new()
	reader.open(path)
	var frames := reader.get_diagnostics(reader.get_first_tick(), reader.get_last_tick())
	_check(frames.size() >= 80, "the recording holds every frame's diagnostics (%d)" % frames.size())
	# Claude 2026-11-16 (pawn spec 8.22): pawn.abilities, which every awake pawn records; an AI-driven pawn's move is the CrowdMover's now,
	# not pawn.move_and_slide.
	var named := frames.any(func(entry: Array) -> bool: return entry[1].scopes.has(&"pawn.abilities") or entry[1].scopes.has("pawn.abilities"))
	_check(named, "with the scopes by name, even read from the middle")
	var middle := reader.get_frame(floori((reader.get_first_tick() + reader.get_last_tick()) / 2.0))
	_check(not middle.diagnostics.is_empty() and middle.diagnostics[0].has("frame_ms"), "a tick's frame has its diagnostics")
	var logs := reader.get_events(reader.get_first_tick(), reader.get_last_tick()).filter(func(event: Dictionary) -> bool: return event.kind == "log")
	_check(logs.any(func(event: Dictionary) -> bool: return str(event.data.get("text", "")).contains("while recording")), "and warnings are events in it")


func _test_capture(manager: DiagnosticsManager) -> void:
	manager.folder = FOLDER
	var path := manager.capture()
	_check(FileAccess.file_exists(path.path_join("frames.csv")) and FileAccess.file_exists(path.path_join("capture.txt")),
		"a capture saves the history as a table and a summary (%s)" % path)
	_check(FileAccess.get_file_as_string(path.path_join("capture.txt")).contains("spikes"), "with the spikes and the warnings")


func _test_panels(manager: DiagnosticsManager, pawn: Pawn) -> void:
	var panels: DiagnosticsPanels = manager._panels
	for key: Key in [KEY_F1, KEY_F2, KEY_F4, KEY_F6, KEY_F7, KEY_F8]:
		panels.toggle(key)
	panels.inspect(pawn)
	panels._refresh_left = 0.0
	panels._process(0.0)
	_check(panels.is_shown(KEY_F4) and panels.get_text(KEY_F4).contains("F4 timings") and panels.get_text(KEY_F4).contains("ms/frame"), # Claude 2026-11-20: any scope rows, since which ones make the list varies (the move check pushed pawn.abilities out)
		"F4 shows the timings, scopes included")
	_check(panels.get_text(KEY_F7).contains("Inspected") and panels.get_text(KEY_F7).contains("running:"), "F7 shows the inspected pawn")
	_check(panels.get_text(KEY_F6).contains("spikes") and panels.get_text(KEY_F8).contains("x10"), "F6 shows spikes, and F8 the warnings with counts")
	panels.toggle(KEY_F4)
	_check(not panels.is_shown(KEY_F4), "a key hides its panel again")
	# Claude 2026-11-17: F9, the nav view (its drawing is checked in nav_debug_view_selftest).
	panels.toggle(KEY_F9)
	_check(panels.is_shown(KEY_F9) and manager.get_node_or_null(^"NavDebugView") is NavDebugView, "F9 shows the nav view")
	panels.toggle(KEY_F9)
	_check(not panels.is_shown(KEY_F9), "and hides it again")


func _process(_delta: float) -> void:
	if _slow_frames > 0:
		_slow_frames -= 1
		OS.delay_msec(40)


func _frames(count: int) -> void:
	for i in count:
		await get_tree().process_frame


func _clear(path: String) -> void:
	if DirAccess.dir_exists_absolute(path):
		for file_name in DirAccess.get_files_at(path):
			DirAccess.remove_absolute(path.path_join(file_name))


func _finish() -> void:
	print("--- ALL PASSED ---" if _failures == 0 else "--- %d FAILED ---" % _failures)
	get_tree().quit(0 if _failures == 0 else 1)
