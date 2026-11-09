## Written by Claude (claude-opus-5-5), 2026-11-09: what whole pawns cost per tick at crowd sizes, to find the next bottleneck after
## the AI (the owner asked for pawn physics diagnostics). Not a pass/fail test: it prints tables.
##
## Three scenes, each at 100, 200, 400 and 800 pawns on flat ground, one tick per physics frame:
##   standing   the default parts, nobody moving: the floor cost of a pawn existing
##   wandering  one team, every pawn wandering: movement and collisions, with sensing skipped (no other team)
##   fighting   two teams mixed together, every pawn with the t0 behaviours: chasing, attacking, knockback, deaths
## For each it prints TickDriver's phases per tick (input, which includes the AI; simulate, which is abilities, gravity and
## move_and_slide; record, which saves rollback state), and Godot's whole physics frame, which adds the physics engine's own step.
## (Claude 2026-11-09: the physics frame column is a median and is noisier than the others; see _measure.)
##
## Run from the project folder (takes a few minutes):
##   "C:\Git\Test 2\Godot_v4.7.2-stable_win64_console.exe" --headless --path . "res://assets/scripts/pawn/tests/pawn_stress.tscn"
## Add "-- --sizes=100,200" to choose the crowd sizes.
## Claude 2026-11-09, for the rollback recording work (pawn spec 12.1):
##   --history=every|snapshots|never   which ticks each pawn saves: every (a client's own pawn, and the old default everywhere),
##                                     snapshots (every 2nd, as a server does at 30 snapshots a second), never (offline)
##   --gdscript-record                 record in GDScript instead of C++
##   --breakdown                       also splits simulate per pawn into the abilities (locomotion, actions, counters) and the
##                                     rest, which is mostly move_and_slide, through the test-only TimedAbilityManager
## Claude 2026-11-09, for tier 1 step 2 (scaling spec section 0):
##   --workers=3                       job worker threads (TickJobs.set_worker_count): 3 is the target machine's dedicated server
##   --stretch=1.6                     acts like the target machine's slower CPU: after each tick, waits so the tick took this many
##                                     times as long. Only the main thread; worker threads and the physics engine run at full speed.
##                                     The phase columns don't include the wait; "all phases" and the physics frame do
##   --no-jobs                         no worker jobs (TickJobs.enabled off): the old main-thread way, to compare
##   --physics-rays                    line of sight with physics rays on the main thread, not in C++ (SightGeometryFeeder.enabled
##                                     off). Claude 2026-11-09, step 4
extends Node

const PAWN_SCENE := "res://assets/scenes/pawn/pawn.tscn"
const WARM_UP_TICKS := 60
const MEASURED_TICKS := 240
const AI_PARTS: Array[StringName] = [&"AIContextComponent", &"AISensingManager", &"AIMemory", &"AITargetSelector", &"AIStateManager", &"AIBehaviourManager"]

var _sizes: Array[int] = [100, 200, 400, 800]
var _history_interval := 1 # Claude 2026-11-09: --history=
var _breakdown := false # Claude 2026-11-09: --breakdown, simulate split into abilities and the rest (TimedAbilityManager)
var _stretch := 1.0 # Claude 2026-11-09: --stretch
var _tick_started_usec := 0


func _ready() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--sizes="):
			_sizes.clear()
			for part in arg.trim_prefix("--sizes=").split(","):
				_sizes.append(int(part))
		# Claude 2026-11-09
		elif arg.begins_with("--history="):
			_history_interval = {"every": 1, "snapshots": 2, "never": 0}.get(arg.trim_prefix("--history="), 1)
		elif arg == "--gdscript-record":
			TickStateComponent.use_native = false
		elif arg == "--breakdown":
			_breakdown = true
		# Claude 2026-11-09 (step 2)
		elif arg.begins_with("--workers="):
			TickJobs.set_worker_count(int(arg.trim_prefix("--workers=")))
		elif arg.begins_with("--stretch="):
			_stretch = maxf(float(arg.trim_prefix("--stretch=")), 1.0)
		elif arg == "--no-jobs":
			TickJobs.enabled = false
		elif arg == "--physics-rays": # Claude 2026-11-09 (step 4)
			SightGeometryFeeder.enabled = false
	if _stretch > 1.0:
		TickDriver.before_tick.connect(func(_dt: float, _tick: int) -> void: _tick_started_usec = Time.get_ticks_usec())
		TickDriver.after_tick.connect(_stretch_tick)
	var floor_body := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(1000, 1, 1000)
	shape.shape = box
	shape.position.y = -0.5
	floor_body.add_child(shape)
	add_child(floor_body)
	print("--- Pawn stress: ms per tick (memory store: %s; recording: %s, history %s) ---" % [
		"C++" if ClassDB.class_exists(&"AIMemoryStore") else "GDScript",
		"C++" if TickStateComponent.use_native and ClassDB.class_exists(&"TickStateRecorder") else "GDScript", # Claude 2026-11-09
		["never", "every tick", "every 2nd tick"][_history_interval]])
	# Claude 2026-11-09 (step 2)
	var scheduler: Object = TickJobs.get_scheduler()
	print("line of sight: %s" % ("C++ (SightGeometry)" if SightGeometryFeeder.get_geometry() != null else "physics rays")) # Claude 2026-11-09 (step 4)
	print("jobs: %s; main thread stretched %.1f times" % [
		"off" if scheduler == null else "on, %d worker threads (%s)" % [scheduler.workers_for_machine() if TickJobs.get_worker_count_setting() < 0 else TickJobs.get_worker_count_setting(), "sized to this machine" if TickJobs.get_worker_count_setting() < 0 else "fixed"],
		_stretch])
	for scene in ["standing", "wandering", "fighting"]:
		print("")
		print("%s:" % scene)
		print("pawns    input+AI   simulate     record   all phases   physics frame   per pawn (frame)")
		for count in _sizes:
			var row := await _measure(scene, count)
			print("%5d   %8.2f   %8.2f   %8.2f   %10.2f   %13.2f   %16.4f" % [count, row.input, row.simulate, row.record, row.phases, row.frame, row.frame / count])
			if row.has("sensing_runs"): # Claude 2026-11-09 (step 2): where the sensing job's work ran
				print("        sensing job: %.1f pawns a tick, %.1f µs each; batches %d, %d of them on the main thread; %d waits" % [row.sensing_items, row.sensing_usec, row.sensing_batches, row.sensing_on_main, row.sensing_waits])
			if _breakdown: # Claude 2026-11-09: microseconds per pawn per tick
				print("        simulate per pawn: %.1f us = abilities %.1f (locomotion %.1f, actions %.1f, counters and locks %.1f) + the rest %.1f (move_and_slide, gravity, bookkeeping)" % [
					row.simulate * 1000.0 / count, row.abilities, row.locomotion, row.actions, row.abilities - row.locomotion - row.actions, row.simulate * 1000.0 / count - row.abilities])
	print("")
	print("--- done ---")
	get_tree().quit(0)


func _measure(scene: String, count: int) -> Dictionary:
	var per_row := ceili(sqrt(count))
	var pawns: Array[Pawn] = []
	for i in count:
		var pawn: Pawn = load(PAWN_SCENE).instantiate()
		pawn.name = "P%d" % i
		pawn.position = Vector3((i % per_row) * 4.0 - per_row * 2.0, 0.1, (i / per_row) * 4.0 - per_row * 2.0)
		(pawn.get_node("TickState") as TickStateComponent).history_interval_ticks = _history_interval # Claude 2026-11-09
		match scene:
			"standing":
				pawn.skip_default_parts = AI_PARTS.duplicate()
			"wandering":
				pawn.team = 0
				pawn.add_child(_behaviours([["Wander", AIWanderBehaviour]]))
			"fighting":
				pawn.team = i % 2
				pawn.add_child(_behaviours([["Wander", AIWanderBehaviour], ["LookToward", AILookTowardBehaviour], ["Investigate", AIInvestigateBehaviour], ["Search", AISearchBehaviour], ["Chase", AIChaseBehaviour], ["Attack", AIAttackBehaviour]]))
		if _breakdown:
			# Claude 2026-11-09: the default AbilityManager part with the timed subclass as its script. Placed before the pawn enters
			# the tree, so PawnInitializer keeps it instead of adding the default one.
			var manager: Node = load("res://assets/scenes/pawn/parts/AbilityManager.tscn").instantiate()
			manager.set_script(TimedAbilityManager)
			manager.name = "AbilityManager"
			pawn.add_child(manager)
		add_child(pawn)
		pawns.append(pawn)
	for i in WARM_UP_TICKS:
		await get_tree().physics_frame
	TickDriver.reset_profile()
	TickDriver.profile_enabled = true
	if TickJobs.get_scheduler(): # Claude 2026-11-09 (step 2)
		TickJobs.get_scheduler().reset_stats()
	TimedAbilityManager.reset_timings() # Claude 2026-11-09
	# Claude 2026-11-09: the median, not the average. Godot's monitor adds up every physics step taken in one rendered frame, so
	# when a frame runs late it reads double or more, and an average swung from 18 to 37 ms between two identical runs. The median
	# ignores those frames. The TickDriver phase columns don't have this problem and are the numbers to trust.
	var frame_times: Array[float] = []
	for i in MEASURED_TICKS:
		await get_tree().physics_frame
		# GDScript note: TIME_PHYSICS_PROCESS is how long the last physics frame took, in seconds: our ticks and Godot's physics step.
		frame_times.append(Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS))
	frame_times.sort()
	TickDriver.profile_enabled = false
	var profile: Dictionary = TickDriver.profile
	var ticks: float = maxf(profile["ticks"], 1)
	var row := {
		"input": profile["input"] / 1000.0 / ticks,
		"simulate": profile["simulate"] / 1000.0 / ticks,
		"record": profile["record"] / 1000.0 / ticks,
		"phases": (profile["before_tick"] + profile["input"] + profile["capture"] + profile["simulate"] + profile["record"] + profile["after_tick"]) / 1000.0 / ticks,
		"frame": frame_times[frame_times.size() / 2] * 1000.0, # Claude 2026-11-09: the median, see above
		# Claude 2026-11-09: --breakdown, in microseconds per pawn per tick
		"abilities": TimedAbilityManager.usec_all / ticks / count,
		"locomotion": TimedAbilityManager.usec_locomotion / ticks / count,
		"actions": TimedAbilityManager.usec_actions / ticks / count,
	}
	# Claude 2026-11-09 (step 2): the sensing job's numbers, when it ran
	var scheduler: Object = TickJobs.get_scheduler()
	var sensing: Dictionary = scheduler.get_stats()["kinds"].get("sensing", {}) if scheduler else {}
	if sensing.get("runs", 0) > 0:
		row["sensing_runs"] = sensing["runs"]
		row["sensing_items"] = float(sensing["items"]) / ticks
		row["sensing_usec"] = sensing["usec_per_item"]
		row["sensing_batches"] = sensing["batches"]
		row["sensing_on_main"] = sensing["batches_on_main"]
		row["sensing_waits"] = sensing["waits"]
	for pawn in pawns:
		pawn.free()
	await get_tree().physics_frame
	await get_tree().physics_frame
	return row


# Claude 2026-11-09: --stretch. Waits at the end of each tick so the tick took _stretch times as long, like a slower CPU's main thread.
func _stretch_tick(_dt: float, _tick: int) -> void:
	var until := Time.get_ticks_usec() + int((Time.get_ticks_usec() - _tick_started_usec) * (_stretch - 1.0))
	while Time.get_ticks_usec() < until:
		pass


func _behaviours(list: Array) -> AIBehaviourManager:
	var manager := AIBehaviourManager.new()
	manager.name = "AIBehaviourManager"
	for pair in list:
		var behaviour: AIBehaviourBase = pair[1].new()
		behaviour.name = pair[0]
		manager.add_child(behaviour)
	return manager
