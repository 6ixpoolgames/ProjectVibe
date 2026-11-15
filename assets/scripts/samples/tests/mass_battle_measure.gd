## Written by Claude (claude-opus-5-5), 2026-11-15: measures the mass battle, the owner's request: how close three factions of a
## given size get to the edge of a tick, through the march and the fight in the middle. Not pass/fail: it prints a row every 10 s of
## game time, the PerformanceOverlay's numbers averaged over those 10 s. One size per run, since the game mode and session carry over
## between arenas in one process. Headless, so nothing is drawn: a windowed game adds rendering on top (F4 in the sample shows it).
## Run from the project folder (add --tick-rate=30 to measure at 30 ticks a second):
##   "C:\Git\Test 2\Godot_v4.7.2-stable_win64_console.exe" --headless --fixed-fps 60 --path . "res://assets/scripts/samples/tests/mass_battle_measure.tscn" -- --size=50 --seconds=150
## --fixed-fps 60 runs it as fast as the computer can while every frame still counts as 1/60 s, so the game time is the same however
## slow the ticks are. Leave it out to measure in real time, where slow ticks get dropped (the dropped column).
extends Node

var _size := 50
var _seconds := 150


func _ready() -> void:
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--size="):
			_size = int(argument.trim_prefix("--size="))
		elif argument.begins_with("--seconds="):
			_seconds = int(argument.trim_prefix("--seconds="))
	var arena: Node = load("res://assets/scenes/samples/mass_battle_sample.tscn").instantiate()
	arena.team_size = _size
	add_child(arena)
	await get_tree().physics_frame
	var overlay: PerformanceOverlay = arena._overlay
	overlay.refresh_seconds = 10.0
	arena._start_offline()
	print("--- Mass battle, %d a faction, %d ticks a second ---" % [_size, TickDriver.get_tick_rate()])
	print(" time   pawns frozen dead   input+AI  simulate  record  other   tick ms  budget%  physics frame (worst)  outside ticks  dropped/s  chunks (waiting)")
	var started := Time.get_ticks_msec()
	var shown := {}
	var ticks_per_row := 10 * TickDriver.get_tick_rate()
	for i in _seconds * TickDriver.get_tick_rate():
		await get_tree().physics_frame
		var n: Dictionary = overlay.get_numbers()
		if n.is_empty() or shown.has(n) or i < ticks_per_row:
			continue
		shown[n] = true
		@warning_ignore("integer_division") # whole seconds on purpose
		print("%4ds   %5d %6d %4d   %8.2f  %8.2f  %6.2f  %5.2f   %7.2f  %6d%%  %8.1f (%6.1f)  %13.1f  %9.1f  %6d (%d)" % [i / TickDriver.get_tick_rate(), n["pawns"], n["frozen"], n["dead"], n["input_ms"], n["simulate_ms"], n["record_ms"], n["other_ms"], n["tick_ms"], int(100.0 * n["tick_ms"] / n["budget_ms"]), n["physics_ms"], n["physics_worst_ms"], n["outside_ticks_ms"], n["dropped_per_second"], n["chunks_built"], n["chunks_queued"]])
	print("--- done in %.0f s ---" % ((Time.get_ticks_msec() - started) / 1000.0))
	get_tree().quit(0)
