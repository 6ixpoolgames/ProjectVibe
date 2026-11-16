## Written by Claude (claude-opus-5-5), 2026-11-15: measures the mass battle, the owner's request: how close three factions of a
## given size get to the edge of a tick, through the march and the fight in the middle. Not pass/fail: it prints a row every 10 s of
## game time, diagnostics v0's numbers averaged over those 10 s (Claude 2026-11-16: was the PerformanceOverlay's). One size per run, since the game mode and session carry over
## between arenas in one process. Headless, so nothing is drawn: a windowed game adds rendering on top (F4 in the sample shows it).
## Run from the project folder (add --tick-rate=30 to measure at 30 ticks a second):
##   "C:\Git\Test 2\Godot_v4.7.2-stable_win64_console.exe" --headless --fixed-fps 60 --path . "res://assets/scripts/samples/tests/mass_battle_measure.tscn" -- --size=50 --seconds=150
## --fixed-fps 60 runs it as fast as the computer can while every frame still counts as 1/60 s, so the game time is the same however
## slow the ticks are. Leave it out to measure in real time, where slow ticks get dropped (the dropped column).
## Claude 2026-11-16: --scopes adds a line per row with every timed part in ms a tick, to see what each phase spends its time on.
## Claude 2026-11-15: the sample records a replay, as playing it does; --no-record leaves that out, to measure what recording costs.
## Recording runs in TickDriver's after_tick, so it shows in the "other" column.
## Claude 2026-11-16, for windowed runs (leave out --headless and --fixed-fps to measure what playing feels like): each row also
## shows the frame, the per-frame scripts (process), drawing on the CPU and GPU, and draw calls. --no-visuals hides the toy figures
## and swords and stops their per-frame scripts; --no-shadows switches the lights' shadows off. Comparing runs shows what each costs.
extends Node

var _size := 50
var _seconds := 150
var _record := true # Claude 2026-11-15
var _visuals := true # Claude 2026-11-16
var _shadows := true
var _max_slides := -1 # Claude 2026-11-16 (movement experiments): -1: as the scenes have it (Godot's default, 6)
var _pawn_collision := true
var _skip_still_moves := false
var _steps := true # Claude 2026-11-16 (pawn spec 8.21): off with --no-steps
var _scopes := false # Claude 2026-11-16: --scopes prints every timed part each row (the owner's question: what does simulate spend it on?)


func _ready() -> void:
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--size="):
			_size = int(argument.trim_prefix("--size="))
		elif argument.begins_with("--seconds="):
			_seconds = int(argument.trim_prefix("--seconds="))
		elif argument == "--no-record": # Claude 2026-11-15
			_record = false
		elif argument == "--no-visuals": # Claude 2026-11-16
			_visuals = false
		elif argument == "--no-shadows":
			_shadows = false
		elif argument.begins_with("--max-slides="): # Claude 2026-11-16 (movement experiments)
			_max_slides = int(argument.trim_prefix("--max-slides="))
		elif argument == "--no-pawn-collision":
			_pawn_collision = false
		elif argument == "--skip-still-moves":
			_skip_still_moves = true
		elif argument == "--no-steps": # Claude 2026-11-16 (pawn spec 8.21): every AI pawn every tick, for comparing
			_steps = false
		elif argument == "--scopes": # Claude 2026-11-16
			_scopes = true
	if not _visuals:
		get_tree().node_added.connect(_on_node_added)
	# Claude 2026-11-16 (movement experiments): each pawn's movement settings, set as it enters the tree.
	get_tree().node_added.connect(func(node: Node) -> void:
		var pawn := node as Pawn
		if pawn == null:
			return
		if _max_slides > 0:
			pawn.max_slides = _max_slides
		if not _pawn_collision:
			pawn.collision_mask &= ~2 # pawns are on layer 2 (pawn.tscn); the ground stays on 1
		pawn.skip_move_when_still = _skip_still_moves)
	if not _record and GameMode.replay_recorder:
		GameMode.replay_recorder.enabled = false
	var arena: Node = load("res://assets/scenes/samples/mass_battle_sample.tscn").instantiate()
	arena.team_size = _size
	add_child(arena)
	await get_tree().physics_frame
	if not _shadows: # Claude 2026-11-16
		for light: Node in arena.find_children("*", "Light3D", true, false):
			(light as Light3D).shadow_enabled = false
	# Claude 2026-11-16: the numbers come from diagnostics v0 now (the PerformanceOverlay is gone), as 10 s averages.
	var diagnostics := GameMode.get_module(DiagnosticsManager) as DiagnosticsManager
	if diagnostics == null:
		print("--- no DiagnosticsManager: check the project setting project_base/game_mode/modules ---")
		get_tree().quit(1)
		return
	arena._start_offline()
	# Claude 2026-11-16: in a window, the overview of the middle, where the fight is: the most there is to draw. Now the spectator at the
	# overview point (V), keeping nothing loaded, as the old overhead camera did; the player's pawn stands where it started, under its AI.
	if DisplayServer.get_name() != "headless":
		arena._go_to_overview()
	# Claude 2026-11-16: and how far out the factions start (the sample's --spawn-distance=, 300 as laid out)
	print("--- Mass battle, %d a faction, spawns %.0f m out, %d ticks a second, %s%s%s%s%s%s ---" % [_size, arena.spawn_distance, TickDriver.get_tick_rate(), "recording a replay" if _record else "no replay",
		"" if _visuals else ", no toy visuals", "" if _shadows else ", no shadows", ", max_slides %d" % _max_slides if _max_slides > 0 else "",
		"" if _pawn_collision else ", no pawn-pawn collision", ", skipping still moves" if _skip_still_moves else ""])
	# Claude 2026-11-16 (pawn spec 8.21): --no-steps runs every AI pawn every tick (no distance steps, no load ladder), for comparing.
	if not _steps:
		if GameMode.ai_activation_manager:
			GameMode.ai_activation_manager.steps_by_distance = false
		TickDriver.load_step_override = 1
	print("--- %s ---" % ("AI pawns step by distance and load (each row: load step, and AI pawns at every tick/2nd/4th)" if _steps else "every AI pawn every tick (--no-steps)"))
	print(" time   pawns frozen dead   input+AI  simulate  record  other   tick ms  budget%  physics a step (worst frame)  outside ticks  dropped/s")
	var started := Time.get_ticks_msec()
	var ticks_per_row := 10 * TickDriver.get_tick_rate()
	for i in _seconds * TickDriver.get_tick_rate():
		await get_tree().physics_frame
		if i == 0 or i % ticks_per_row != 0:
			continue
		var s: Dictionary = diagnostics.get_summary(10.0)
		var parts: Dictionary = s.tick_parts
		var outside: float = maxf(s.physics_ms - s.tick_ms * s.steps_per_frame, 0.0)
		var n := {"pawns": s.pawns, "frozen": s.frozen, "dead": s.dead, "input_ms": parts.get("input", 0.0) + parts.get("capture", 0.0),
			"simulate_ms": parts.get("simulate", 0.0), "record_ms": parts.get("record", 0.0),
			"other_ms": parts.get("before_tick", 0.0) + parts.get("after_tick", 0.0), "tick_ms": s.tick_ms, "budget_ms": 1000.0 / TickDriver.get_tick_rate(),
			"physics_ms": s.physics_ms / maxf(s.steps_per_frame, 1.0), "physics_worst_ms": s.frame_worst_ms, "outside_ticks_ms": outside,
			"dropped_per_second": s.dropped_per_second, "frame_ms": s.frame_ms, "fps": s.fps,
			"process_ms": s.scripts_ms, "render_cpu_ms": s.render_cpu_ms, "render_gpu_ms": s.render_gpu_ms, "draw_calls": s.draw_calls,
			"objects": s.objects}
		@warning_ignore("integer_division") # whole seconds on purpose
		print("%4ds   %5d %6d %4d   %8.2f  %8.2f  %6.2f  %5.2f   %7.2f  %6d%%  %15.1f (%6.1f)  %13.1f  %9.1f" % [i / TickDriver.get_tick_rate(), n["pawns"], n["frozen"], n["dead"], n["input_ms"], n["simulate_ms"], n["record_ms"], n["other_ms"], n["tick_ms"], int(100.0 * n["tick_ms"] / n["budget_ms"]), n["physics_ms"], n["physics_worst_ms"], n["outside_ticks_ms"], n["dropped_per_second"]])
		print("        load step %d   AI pawns at every tick/2nd/4th %s" % [s.get("load_step", 1), DiagnosticsManager.steps_text(s.get("step_counts", {}))]) # Claude 2026-11-16
		# Claude 2026-11-16 (movement experiments): movement: move_and_slide's cost and calls a frame, and skipped moves.
		var moves: Array = s.scopes.get(&"pawn.move_and_slide", [0.0, 0.0])
		var skipped: Array = s.scopes.get(&"pawn.move_skipped", [0.0, 0.0])
		print("        move_and_slide %.2f ms a frame, %.0f calls, %.1f us each; %.0f skipped" % [moves[0], moves[1], 1000.0 * moves[0] / maxf(moves[1], 1.0), skipped[1]])
		# Claude 2026-11-16: the frame as a whole, for windowed runs
		print("        frame %.1f ms (%d fps)   scripts %.1f ms   drawing CPU %.1f ms, GPU %.1f ms   %d draw calls, %d objects" % [n["frame_ms"], n["fps"], n["process_ms"], n["render_cpu_ms"], n["render_gpu_ms"], n["draw_calls"], n["objects"]])
		# Claude 2026-11-16: --scopes: every timed part, most expensive first. Claude 2026-11-16 (audit): TickDriver's phases ("tick.")
		# as ms a tick, from the summary's tick_parts; everything else as ms a frame, as it's summed, since some run once a frame
		# (animation.*) and others inside ticks (pawn.move_and_slide is inside simulate), and a frame can hold more or fewer ticks.
		if _scopes:
			var per_tick := PackedStringArray()
			var per_frame := PackedStringArray()
			for part: String in s.tick_parts:
				if float(s.tick_parts[part]) >= 0.02:
					per_tick.append("%s %.2f" % [part, s.tick_parts[part]])
			for scope: StringName in s.scopes:
				var entry: Array = s.scopes[scope]
				if not String(scope).begins_with("tick.") and float(entry[0]) >= 0.02:
					per_frame.append("%s %.2f (%.0f calls)" % [scope, entry[0], entry[1]])
			print("        ms a tick: " + ", ".join(per_tick))
			print("        ms a frame (%.2f ticks a frame): %s" % [s.steps_per_frame, ", ".join(per_frame)])
	# Claude 2026-11-15: the replay's size, before stopping it
	var recorder: ReplayRecorder = GameMode.replay_recorder
	if recorder and recorder.is_recording():
		var ticks := recorder.get_ticks_recorded()
		recorder.stop_recording()
		var size := FileAccess.get_file_as_bytes(recorder.get_recording_path()).size()
		print("replay: %.2f MB for %d ticks, %.1f MB a minute, %s" % [size / 1048576.0, ticks, size / 1048576.0 / (ticks / 60.0 / 60.0) if ticks > 0 else 0.0, recorder.get_recording_path()])
	print("--- done in %.0f s ---" % ((Time.get_ticks_msec() - started) / 1000.0))
	get_tree().quit(0)


# Claude 2026-11-16: --no-visuals: each toy figure and sword is hidden once it's ready, and its per-frame script stopped, so the run
# shows what the game costs without them. GDScript note: CONNECT_ONE_SHOT disconnects after the first call; ready is waited for
# because Godot switches processing on at ready for any script with a _process.
func _on_node_added(node: Node) -> void:
	if node is ToyWaddle or node is FloatingSword:
		node.ready.connect(func() -> void:
			node.set_process(false)
			(node as Node3D).visible = false, CONNECT_ONE_SHOT)
