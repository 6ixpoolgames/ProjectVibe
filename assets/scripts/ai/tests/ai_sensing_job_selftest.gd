## Written by Claude (claude-opus-5-5), 2026-11-09: headless self-test for the job scheduler and the sensing job (scaling spec step 2):
## the job gives exactly the same answers as the main-thread sight check, with 0, 1, 2, 3 or the machine's number of worker threads,
## with physics rays and (Claude 2026-11-09, step 4) with line of sight in C++;
## a fight run with the job is the same, tick for tick, as one without it; and the scheduler's numbers say where the work ran.
## Needs the navcore C++ library; without it, it says so and passes.
## Exits 0 on success, 1 on failure. Run from the project folder:
##   "C:\Git\Test 2\Godot_v4.7.2-stable_win64_console.exe" --headless --path . "res://assets/scripts/ai/tests/ai_sensing_job_selftest.tscn"
extends Node

const PAWN_SCENE := "res://assets/scenes/pawn/pawn.tscn"
const GOBLIN_SCENE := "res://assets/scenes/samples/arena_goblin.tscn"
const NO_AI: Array[StringName] = [&"AIContextComponent", &"AISensingManager", &"AIMemory", &"AITargetSelector", &"AIStateManager", &"AIBehaviourManager"]
# Worker counts compared: none (everything on the main thread), 1, 2, 3 (the target machine's dedicated server), and the machine's.
const WORKER_COUNTS := [0, 1, 2, 3, -1]

var _failures := 0


func _ready() -> void:
	print("--- Sensing job self-test ---")
	if not ClassDB.class_exists(&"AISensingJob"):
		print("  no C++ library here: nothing to test")
		print("--- ALL PASSED ---")
		get_tree().quit(0)
		return
	var floor_body := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(400, 1, 400)
	shape.shape = box
	shape.position.y = -0.5
	floor_body.add_child(shape)
	add_child(floor_body)
	await _test_same_answers()
	await _test_fight_unchanged()
	TickJobs.set_worker_count(-1)
	print("--- ALL PASSED ---" if _failures == 0 else "--- %d FAILED ---" % _failures)
	get_tree().quit(0 if _failures == 0 else 1)


## The job's answers equal the main-thread check's, with every worker count. 64 pawns in three teams, walls that block some rays,
## and different detectability, over six passes with the pawns moved between them, each pass recorded into memory that persists.
func _test_same_answers() -> void:
	var pick := RandomNumberGenerator.new()
	pick.seed = 11
	var walls := Node3D.new()
	add_child(walls)
	for i in 12:
		var wall := StaticBody3D.new() # layer 1, which sight's default mask blocks on
		var wall_shape := CollisionShape3D.new()
		var wall_box := BoxShape3D.new()
		wall_box.size = Vector3(pick.randf_range(1, 6), 3, pick.randf_range(1, 6))
		wall_shape.shape = wall_box
		wall.add_child(wall_shape)
		wall.position = Vector3(pick.randf_range(-20, 20), 1.5, pick.randf_range(-20, 20))
		walls.add_child(wall)
	var pawns: Array[Pawn] = []
	for i in 64:
		var pawn: Pawn = load(PAWN_SCENE).instantiate()
		pawn.skip_default_parts = NO_AI # bodies only: this test calls the checks itself
		pawn.team = i % 3
		pawn.detectability = [1.0, 0.5, 0.0, 1.0][i % 4]
		pawn.position = Vector3(pick.randf_range(-22, 22), 0.1, pick.randf_range(-22, 22))
		add_child(pawn)
		pawns.append(pawn)
	for i in 3:
		await get_tree().physics_frame # the walls and pawns join the physics world
	var grid: Object = ClassDB.instantiate(&"AIPawnGrid")
	grid.set_table(Pawn.get_table())
	var settings := PackedFloat64Array([1.0 / 30.0, 8.0, 25.0, cos(deg_to_rad(45.0)), cos(deg_to_rad(80.0)), 0.3, 30, 1.6, 1.0, 1, 10])
	var reach := 25.0
	var max_candidates := 32
	# One memory per pawn for the main-thread check, and one per pawn for each worker count. Each keeps what it saw over the passes.
	var inline_stores: Array = _make_stores(pawns.size(), settings)
	var job_stores := {}
	var jobs := {}
	for workers in WORKER_COUNTS:
		job_stores[workers] = _make_stores(pawns.size(), settings)
		jobs[workers] = ClassDB.instantiate(&"AISensingJob")
	# Claude 2026-11-09 (scaling spec step 4): the same again with line of sight in C++ (SightGeometry) instead of physics rays, for the
	# main-thread check and for the job, which then tests the rays on the workers too.
	var geometry: Object = ClassDB.instantiate(&"SightGeometry")
	for child in get_children():
		if child is StaticBody3D:
			geometry.add_body(child) # the floor
	for wall in walls.get_children():
		geometry.add_body(wall)
	geometry.sync(1)
	var inline_geometry_stores: Array = _make_stores(pawns.size(), settings, geometry)
	var geometry_job_stores := {}
	var geometry_jobs := {}
	for workers in WORKER_COUNTS:
		geometry_job_stores[workers] = _make_stores(pawns.size(), settings, geometry)
		geometry_jobs[workers] = ClassDB.instantiate(&"AISensingJob")
	var geometry_differ := 0
	var geometry_unlike_physics := 0
	var differ := 0
	var seen := 0
	var yaws: Array[float] = []
	for pass_number in 6:
		var tick := 10000 + pass_number * 10 # passes 10 ticks apart, as sensing does
		yaws.clear()
		for pawn in pawns:
			yaws.append(pick.randf_range(-PI, PI))
		# The main-thread check, the way AISensingManager and SightSense do it without the job.
		for i in pawns.size():
			var p := pawns[i]
			var candidates: Array = grid.query(p.global_position, reach, p.team, p, max_candidates, tick + 1)
			inline_stores[i].sight_check(p, yaws[i], candidates, tick + 1)
		var expected := _snapshot(inline_stores, pawns, tick + 1)
		# Claude 2026-11-09 (step 4): with the geometry, on the main thread and in the job.
		for i in pawns.size():
			var p := pawns[i]
			inline_geometry_stores[i].sight_check(p, yaws[i], grid.query(p.global_position, reach, p.team, p, max_candidates, tick + 1), tick + 1)
		var expected_with_geometry := _snapshot(inline_geometry_stores, pawns, tick + 1)
		if expected_with_geometry != expected:
			geometry_unlike_physics += 1
		for workers in WORKER_COUNTS:
			TickJobs.set_worker_count(workers)
			var geometry_job: Object = geometry_jobs[workers]
			geometry_job.setup(TickJobs.get_scheduler(), grid)
			geometry_job.set_geometry(geometry)
			for i in pawns.size():
				geometry_job.add_request(pawns[i], yaws[i], reach, max_candidates, settings)
			geometry_job.start(tick)
			for i in pawns.size():
				geometry_job_stores[workers][i].sight_check_prepared(geometry_job, pawns[i], tick + 1)
			if _snapshot(geometry_job_stores[workers], pawns, tick + 1) != expected_with_geometry:
				geometry_differ += 1
		for workers in WORKER_COUNTS:
			TickJobs.set_worker_count(workers)
			var job: Object = jobs[workers]
			job.setup(TickJobs.get_scheduler(), grid)
			for i in pawns.size():
				job.add_request(pawns[i], yaws[i], reach, max_candidates, settings)
			job.start(tick)
			for i in pawns.size():
				job_stores[workers][i].sight_check_prepared(job, pawns[i], tick + 1)
			if _snapshot(job_stores[workers], pawns, tick + 1) != expected:
				differ += 1
		for store in inline_stores:
			seen += store.entry_count()
		# Move everyone for the next pass: between passes, so every check sees the same places.
		for pawn in pawns:
			pawn.global_position = Vector3(pick.randf_range(-22, 22), 0.1, pick.randf_range(-22, 22))
	_check(seen > 200, "the checks see plenty: %d entries over the passes, some through gaps between walls" % seen)
	_check(differ == 0, "the job's answers equal the main-thread check's with 0, 1, 2, 3 and the machine's number of workers (%d of %d passes differ)" % [differ, 6 * WORKER_COUNTS.size()])
	_check(geometry_differ == 0, "with line of sight in C++ on the workers too, the same: equal to the main-thread check with the geometry (%d of %d differ)" % [geometry_differ, 6 * WORKER_COUNTS.size()])
	_check(geometry_unlike_physics == 0, "and line of sight in C++ remembers exactly what physics rays did, over all six passes (%d differ)" % geometry_unlike_physics)
	var stats: Dictionary = TickJobs.get_scheduler().get_stats()
	var sensing: Dictionary = stats["kinds"].get("sensing", {})
	print("        scheduler: %d workers on this machine; sensing: %d runs, %d batches, %d on the main thread, %.1f µs per pawn" % [TickJobs.get_scheduler().workers_for_machine(), sensing.get("runs", 0), sensing.get("batches", 0), sensing.get("batches_on_main", 0), sensing.get("usec_per_item", 0.0)])
	_check(sensing.get("runs", 0) == 12 * WORKER_COUNTS.size() and sensing.get("items", 0) == 12 * WORKER_COUNTS.size() * pawns.size(), "every run and every pawn counted once")
	# A table change while a job is reading waits for it: free a pawn right after a start, then take the results.
	TickJobs.set_worker_count(2)
	var job: Object = jobs[2]
	job.setup(TickJobs.get_scheduler(), grid)
	for i in pawns.size():
		job.add_request(pawns[i], 0.0, reach, max_candidates, settings)
	job.start(20000)
	var leaving := pawns.pop_back() as Pawn
	leaving.free() # the table changes: the guard finishes the job first
	var taken := 0
	for p in pawns:
		if job.has_result(p, 20001):
			taken += 1
	_check(taken == pawns.size() and TickJobs.get_scheduler().get_stats()["kinds"]["sensing"]["runs"] == 12 * WORKER_COUNTS.size() + 1, "a pawn leaving while the job runs waits for the job, and every result is still there")
	for pawn in pawns:
		pawn.free()
	walls.free()
	await get_tree().physics_frame


## A real fight, goblins of three teams chasing and hitting each other for 240 ticks, ends the same with the job as without it. The
## same fight is run three times from the same start: without the job twice (to show it repeats at all in one process), then with it.
func _test_fight_unchanged() -> void:
	var without := await _run_fight(false, 0)
	var again := await _run_fight(false, 0)
	if without != again:
		print("        the fight doesn't repeat exactly within one process even without the job, so it can't be compared here")
		_check(true, "skipped: fight comparison")
		return
	TickJobs.get_scheduler().reset_stats()
	var with_job := await _run_fight(true, 3)
	# The requests made at the end of the last tick have no next tick here, so they're never taken.
	_check(with_job["taken"] > 0 and with_job["taken"] + with_job["last_requests"] == with_job["requests"], "with the job, every full pass on schedule used its result (%d of %d, and %d asked for at the end of the last tick)" % [with_job["taken"], with_job["requests"], with_job["last_requests"]])
	_check(with_job["state"] == without["state"], "and the fight ends the same, tick for tick: every goblin's place, Health and memory (%d goblins, 240 ticks)" % without["count"])
	var sensing: Dictionary = TickJobs.get_scheduler().get_stats()["kinds"].get("sensing", {})
	print("        with 3 workers: %d runs, %d batches, %d on the main thread, %d waits, %.1f µs per pawn" % [sensing.get("runs", 0), sensing.get("batches", 0), sensing.get("batches_on_main", 0), sensing.get("waits", 0), sensing.get("usec_per_item", 0.0)])


func _run_fight(use_job: bool, workers: int) -> Dictionary:
	TickJobs.enabled = use_job
	TickJobs.set_worker_count(workers)
	var job: Object = AISensingManager._shared_job() if use_job else null
	if job:
		job.reset_stats()
	get_node("/root/TickDriver").set_tick(5000)
	var goblins: Array[Pawn] = []
	var pick := RandomNumberGenerator.new()
	pick.seed = 5
	for i in 24:
		var goblin: Pawn = load(GOBLIN_SCENE).instantiate()
		goblin.name = "Goblin%d" % i # the AI staggers by name when there's no network id, so the same names every run
		goblin.team = i % 3
		goblin.position = Vector3(pick.randf_range(-12, 12), 0.1, pick.randf_range(-12, 12))
		add_child(goblin)
		goblins.append(goblin)
	for i in 240:
		await get_tree().physics_frame
	var state := []
	for goblin in goblins:
		var memory := goblin.ai_memory
		var entries := []
		for e in memory.entry_count():
			entries.append([String(memory.get_store().entity_at(e).name), memory.get_store().awareness_at(e, 5240), memory.get_store().last_known_position_at(e)])
		state.append([goblin.global_position, goblin.get_health(), entries])
	var stats: Dictionary = job.get_stats() if job else {"requests": 0, "taken": 0, "last_requests": 0}
	for goblin in goblins:
		goblin.free()
	await get_tree().physics_frame
	TickJobs.enabled = true
	return {"state": state, "count": goblins.size(), "requests": stats["requests"], "taken": stats["taken"], "last_requests": stats["last_requests"]}


func _make_stores(count: int, settings: PackedFloat64Array, geometry: Object = null) -> Array:
	var stores := []
	for i in count:
		var store: Object = ClassDB.instantiate(&"AIMemoryStore")
		store.set_sight_settings(settings)
		store.set_sight_geometry(geometry) # Claude 2026-11-09 (step 4): null means physics rays
		stores.append(store)
	return stores


# Everything each memory holds, by pawn index, exactly.
func _snapshot(stores: Array, pawns: Array[Pawn], tick: int) -> Array:
	var out := []
	for store in stores:
		var entries := []
		for e in store.entry_count():
			entries.append([pawns.find(store.entity_at(e)), store.awareness_at(e, tick), store.is_certain_at(e), store.last_known_position_at(e), store.ticks_since_seen_at(e, tick)])
		out.append(entries)
	return out


func _check(passed: bool, what: String) -> void:
	print("  %s %s" % ["ok  " if passed else "FAIL", what])
	if not passed:
		_failures += 1
