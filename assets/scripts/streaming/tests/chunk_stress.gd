## Written by Claude (claude-opus-5-5), 2026-11-06: stress test for chunk streaming, aimed at slower machines than the
## one it runs on. It prints a table, and fails only if the rows that stand for the target machine go over their limits.
##
## The target: the bottom third or so of the Steam hardware survey, which the owner asked for. The survey doesn't report
## that directly, so this is an estimate: about 4 to 6 older cores, 8 to 16 GB, and an entry-level graphics card. Two
## settings stand in for that machine, both of them assumptions, not measurements:
##   - SLOWER_CPU: the streamer's work takes 3 times as long as on this machine, a 5900X. That's meant to be cautious.
##   - NAV_WORKERS: nav builds on 3 background threads, as a 4-core machine would leave after the main thread.
## What this can't show: the graphics card, memory speed, physics on a slower CPU, or anything else a real game is doing.
## Only a real low-end machine can answer those.
##
## Every row runs with collision, nav and a real frame rate cap. Run from the project folder, about 6 minutes:
##   "C:\Git\Test 2\Godot_v4.7.2-stable_win64_console.exe" --headless --path . "res://assets/scripts/streaming/tests/chunk_stress.tscn"
extends Node

const SLOWER_CPU := 3.0
const NAV_WORKERS := 3
const LOAD_DISTANCE := 320.0
const NAV_DISTANCE := 96.0
const MAX_MS_PER_FRAME := 2.0
const MOVE_SECONDS := 8.0
# The limits for the target rows. The streamer may use about half of a 60 fps frame at its very worst.
const TARGET_WORST_FRAME_MS := 8.0

# Chunk width in metres, and squares per side. Each keeps squares of about 6 m, so the ground looks about the same.
const SIZES := [[256.0, 43], [128.0, 21], [64.0, 11]]
# Name, sources, speed in metres per second, and whether it counts as the target. A sprinting pawn and a vehicle are what
# a game must handle. Flying very fast is there to find where it breaks.
const SCENARIOS := [
	["walk", 1, 8.0, true],
	["vehicle", 1, 40.0, true],
	["8 players", 8, 8.0, false],
	["fly", 1, 200.0, false],
]

var _failures := 0


func _ready() -> void:
	print("--- Chunk stress test ---")
	Engine.max_fps = 60
	NavMarkerManager.report_quiet_seconds = 1000000.0
	NavServer.configure({"worker_threads": NAV_WORKERS})
	print("cpu  chunk  scenario   | start s  KB/chunk | worst frame  worst step  avg frame | chunks  backlog  no ground | late frames | nav tiles  nav backlog")
	for slowdown in [1.0, SLOWER_CPU]:
		for size in SIZES:
			for scenario in SCENARIOS:
				await _run_row(slowdown, size[0], size[1], scenario)
	NavMarkerManager.report_quiet_seconds = 2.0
	NavMarkerManager.reset()
	print("--- ALL PASSED ---" if _failures == 0 else "--- %d FAILED ---" % _failures)
	get_tree().quit(0 if _failures == 0 else 1)


func _run_row(slowdown: float, chunk_size: float, chunk_resolution: int, scenario: Array) -> void:
	var memory_before := Performance.get_monitor(Performance.MEMORY_STATIC)
	var terrain := TerrainGenerator.new()
	terrain.name = "Terrain"
	terrain.build_on_start = false
	terrain.chunk_size = chunk_size
	terrain.chunk_resolution = chunk_resolution
	var link := TerrainNavFeeder.new() # Claude 2026-11-07: a terrain feeds nav through this now, and it ticks nav
	link.nav_hooks = NavHooks.new()
	link.tick_nav = true
	terrain.add_child(link)
	add_child(terrain)

	var streamer := SlowChunkStreamer.new() # Claude 2026-11-07: the slower CPU moved out of ChunkStreamer
	streamer.terrain = terrain
	streamer.max_ms_per_frame = MAX_MS_PER_FRAME
	streamer.simulate_slower_cpu = slowdown
	add_child(streamer)

	var sources: Array[StreamingSource] = []
	var source_count: int = scenario[1]
	for i in source_count:
		var source := StreamingSource.new()
		source.load_distance = LOAD_DISTANCE
		source.nav_distance = NAV_DISTANCE
		# Players are spread out in a line, so their areas barely overlap. The start is near a chunk corner, the worst
		# place, since it wants the most chunks.
		source.position = Vector3(i * 800.0 + 1.0, 0.0, 1.0)
		add_child(source)
		sources.append(source)

	# Starting up: all the chunks around the start, as a game with no loading screen would.
	var started := Time.get_ticks_msec()
	await get_tree().process_frame
	await get_tree().process_frame
	while streamer.get_stats().queued > 0:
		await get_tree().process_frame
	var start_seconds := (Time.get_ticks_msec() - started) / 1000.0
	var chunks_at_start := terrain.get_loaded_chunks().size()
	var kb_per_chunk := (Performance.get_monitor(Performance.MEMORY_STATIC) - memory_before) / 1024.0 / maxi(chunks_at_start, 1)
	streamer.reset_worst_times()
	var loaded_before: int = streamer.get_stats().total_loaded

	# Moving. Late frames are ones that took more than 20 ms, which can't happen at 60 fps unless something ran over.
	var speed: float = scenario[2]
	var frames := 0
	var late_frames := 0
	var no_ground_frames := 0
	var biggest_backlog := 0
	var total_frame_ms := 0.0
	var biggest_nav_backlog := 0
	var moved_seconds := 0.0
	var last := Time.get_ticks_usec()
	while moved_seconds < MOVE_SECONDS:
		await get_tree().process_frame
		var now := Time.get_ticks_usec()
		var real_delta := (now - last) / 1000000.0
		last = now
		moved_seconds += real_delta
		frames += 1
		if real_delta > 0.020:
			late_frames += 1
		for source in sources:
			source.position.x += speed * real_delta
			source.position.z += speed * real_delta * 0.3 # at a slight angle, so it crosses borders both ways
			if not terrain.has_chunk(terrain.chunk_of(source.position)):
				no_ground_frames += 1
		var stats := streamer.get_stats()
		total_frame_ms += stats.last_frame_ms
		biggest_backlog = maxi(biggest_backlog, stats.queued)
		var nav_stats := NavServer.get_stats()
		biggest_nav_backlog = maxi(biggest_nav_backlog, nav_stats.queued + nav_stats.dirty + nav_stats.building)

	var stats := streamer.get_stats()
	var nav_stats := NavServer.get_stats()
	print("x%d   %3d m  %-9s  | %6.1f  %8.0f | %8.2f ms  %7.2f ms  %6.2f ms | %6d  %7d  %9d | %4d of %-4d | %9d  %11d" % [
		int(slowdown), int(chunk_size), scenario[0],
		start_seconds, kb_per_chunk,
		stats.worst_frame_ms, stats.worst_step_ms, total_frame_ms / maxi(frames, 1),
		stats.total_loaded - loaded_before, biggest_backlog, no_ground_frames,
		late_frames, frames,
		nav_stats.live_detour_tiles, biggest_nav_backlog,
	])

	if slowdown == SLOWER_CPU and scenario[3]:
		var what := "x%d %d m %s" % [int(slowdown), int(chunk_size), scenario[0]]
		_check(no_ground_frames == 0, "%s: the ground under the source was always built" % what)
		_check(stats.worst_frame_ms <= TARGET_WORST_FRAME_MS, "%s: worst frame within %.0f ms (%.2f ms)" % [what, TARGET_WORST_FRAME_MS, stats.worst_frame_ms])

	for source in sources:
		source.free()
	streamer.free()
	terrain.free()
	# Let nav empty out, so one row's leftovers don't count against the next.
	for i in 2000:
		NavServer.tick(1.0 / 60.0)
		if i > 2 and NavServer.is_idle():
			break
		OS.delay_msec(1)


func _check(passed: bool, what: String) -> void:
	print("  %s %s" % ["ok  " if passed else "FAIL", what])
	if not passed:
		_failures += 1
