## Written by Claude (claude-opus-5-5), 2026-11-09: measures what the AI costs per tick with a crowd, to decide whether sensing and
## memory move to C++ (pawn spec step 8b, 10.1). Not a pass/fail test: it prints a table.
##
## Two teams of pawns mixed together on flat ground, every one with the default AI parts and all five t0 behaviours, so they wander,
## notice each other, chase and search. Each row runs the same crowd with and without the AI parts and prints the time per tick in
## TickDriver's input phase, where the AI runs; the difference is the AI's cost.
##
## Run from the project folder (takes about a minute):
##   "C:\Git\Test 2\Godot_v4.7.2-stable_win64_console.exe" --headless --path . "res://assets/scripts/ai/tests/ai_stress.tscn"
## To see where the time goes, add one of these after "--":
##   --no-sensing      the AI parts, but senses never run
##   --no-behaviours   the AI parts and senses, but no behaviours
##   --no-refresh      full passes only, no refreshes between them
##   --breakdown       200 pawns with AI only, timing each AI part separately (test-only subclasses that wrap each call)
##   --gdscript-store  the GDScript memory store and physics query, even where the C++ library is available (Claude 2026-11-09)
extends Node

var _no_sensing := false
var _no_behaviours := false
var _no_refresh := false
var _breakdown := false
var _totals := {} # part -> [microseconds, calls], shared by the timed parts below

const PAWN_SCENE := "res://assets/scenes/pawn/pawn.tscn"
const AI_PARTS: Array[StringName] = [&"AIContextComponent", &"AISensingManager", &"AIMemory", &"AITargetSelector", &"AIStateManager", &"AIBehaviourManager"]
const CROWDS := [50, 100, 200, 400]
const WARM_UP_TICKS := 60
const MEASURED_TICKS := 300


## Test-only: the same parts, with each call timed into a shared dictionary. Shipping code is untouched.
class TimedSensing extends AISensingManager:
	var totals: Dictionary
	func _note(part: String, started: int) -> void:
		var entry: Array = totals.get(part, [0, 0])
		entry[0] += Time.get_ticks_usec() - started
		entry[1] += 1
		totals[part] = entry
	func tick_sensing(tick: int) -> void:
		var started := Time.get_ticks_usec()
		super(tick)
		_note("sensing (passes, refreshes, memory)", started)
	func _find_candidates(tick: int) -> void:
		var started := Time.get_ticks_usec()
		super(tick)
		_note("  of which: nearby-pawns query", started)

class TimedSight extends SightSense:
	var totals: Dictionary
	func _note(part: String, started: int) -> void:
		var entry: Array = totals.get(part, [0, 0])
		entry[0] += Time.get_ticks_usec() - started
		entry[1] += 1
		totals[part] = entry
	func _check_all(targets: Array, tick: int) -> void:
		var started := Time.get_ticks_usec()
		super(targets, tick)
		_note("  of which: sight checks and rays (memory store)", started)

class TimedHands extends AIController:
	var totals: Dictionary
	func _note(part: String, started: int) -> void:
		var entry: Array = totals.get(part, [0, 0])
		entry[0] += Time.get_ticks_usec() - started
		entry[1] += 1
		totals[part] = entry
	func move_to(point: Vector3) -> bool:
		var started := Time.get_ticks_usec()
		var found := super(point)
		_note("  AIController.move_to", started)
		return found
	func take_input_command(tick: int) -> InputCommand:
		var started := Time.get_ticks_usec()
		var command := super(tick)
		_note("AIController.take_input_command (path following)", started)
		return command

class TimedNavigation extends NavigationManager:
	var totals: Dictionary
	func _note(part: String, started: int) -> void:
		var entry: Array = totals.get(part, [0, 0])
		entry[0] += Time.get_ticks_usec() - started
		entry[1] += 1
		totals[part] = entry
	func move_to(point: Vector3) -> bool:
		var started := Time.get_ticks_usec()
		var found := super(point)
		_note("    of which: NavigationManager.move_to (path request)", started)
		return found

class TimedSelector extends AITargetSelector:
	var totals: Dictionary
	func _note(part: String, started: int) -> void:
		var entry: Array = totals.get(part, [0, 0])
		entry[0] += Time.get_ticks_usec() - started
		entry[1] += 1
		totals[part] = entry
	func update_target(tick: int) -> void:
		var started := Time.get_ticks_usec()
		super(tick)
		_note("target selection", started)

class TimedStates extends AIStateManager:
	var totals: Dictionary
	func _note(part: String, started: int) -> void:
		var entry: Array = totals.get(part, [0, 0])
		entry[0] += Time.get_ticks_usec() - started
		entry[1] += 1
		totals[part] = entry
	func update_state(tick: int) -> void:
		var started := Time.get_ticks_usec()
		super(tick)
		_note("state check", started)

class TimedBehaviours extends AIBehaviourManager:
	var totals: Dictionary
	func _note(part: String, started: int) -> void:
		var entry: Array = totals.get(part, [0, 0])
		entry[0] += Time.get_ticks_usec() - started
		entry[1] += 1
		totals[part] = entry
	func decide(tick: int) -> void:
		var started := Time.get_ticks_usec()
		super(tick)
		_note("behaviour decision", started)
	func tick_running(tick: int) -> void:
		var running := get_running_behaviour()
		var which := String(running.name) if running else "none"
		var started := Time.get_ticks_usec()
		super(tick)
		_note("running behaviour's tick (Chase etc.)", started)
		_note("  of which: " + which, started)


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	_no_sensing = args.has("--no-sensing")
	_no_behaviours = args.has("--no-behaviours")
	_no_refresh = args.has("--no-refresh")
	_breakdown = args.has("--breakdown")
	AIMemory.use_native = not args.has("--gdscript-store")
	print("memory store: %s" % ("C++ (AIMemoryStore, AIPawnGrid)" if AIMemory.use_native and ClassDB.class_exists(&"AIMemoryStore") else "GDScript (AIMemoryStoreGD, physics query)"))
	print("switches: %s" % (" ".join(args) if not args.is_empty() else "none"))
	var floor_body := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(400, 1, 400)
	shape.shape = box
	shape.position.y = -0.5
	floor_body.add_child(shape)
	add_child(floor_body)
	if _breakdown:
		await _run_breakdown(200)
		get_tree().quit(0)
		return
	print("--- AI stress: ms per tick in TickDriver's input phase, where the AI runs ---")
	print("pawns   without AI   with AI   AI per tick   AI per pawn per tick (ms)")
	for count: int in CROWDS:
		var without := await _measure(count, false)
		var with_ai := await _measure(count, true)
		print("%5d   %10.3f   %7.3f   %11.3f   %12.4f" % [count, without, with_ai, with_ai - without, (with_ai - without) / count])
	print("--- done ---")
	get_tree().quit(0)


## Average ms per tick spent in TickDriver's input phase for this crowd: the AI step, then asking controllers for input. The crowd
## stands on a grid 4 m apart, mixed teams, so every pawn has enemies in sight.
func _measure(count: int, with_ai: bool) -> float:
	var per_row := ceili(sqrt(count))
	var pawns: Array[Pawn] = []
	for i in count:
		var pawn: Pawn = load(PAWN_SCENE).instantiate()
		pawn.name = "P%d" % i
		pawn.team = i % 2
		pawn.position = Vector3((i % per_row) * 4.0 - per_row * 2.0, 0.1, (i / per_row) * 4.0 - per_row * 2.0)
		if with_ai:
			if _breakdown:
				_add_timed_parts(pawn)
			elif not _no_behaviours:
				pawn.add_child(_behaviours())
		else:
			pawn.skip_default_parts = AI_PARTS.duplicate()
		add_child(pawn)
		if with_ai and _no_sensing:
			pawn.ai_sensing_manager.sense_interval_ticks = 100000000
			pawn.ai_sensing_manager.refresh_interval_ticks = 100000000
		elif with_ai and _no_refresh:
			pawn.ai_sensing_manager.refresh_interval_ticks = 100000000
		pawns.append(pawn)
	for i in WARM_UP_TICKS:
		await get_tree().physics_frame
	# GDScript note: TickDriver's profile adds up microseconds per tick phase while profile_enabled is on (test-only switch).
	TickDriver.reset_profile()
	TickDriver.profile_enabled = true
	for i in MEASURED_TICKS:
		await get_tree().physics_frame
	TickDriver.profile_enabled = false
	var ticks: int = maxi(TickDriver.profile["ticks"], 1)
	var input_ms: float = TickDriver.profile["input"] / 1000.0 / ticks
	for pawn in pawns:
		pawn.free()
	await get_tree().physics_frame
	return input_ms


func _behaviours() -> AIBehaviourManager:
	var manager := AIBehaviourManager.new()
	manager.name = "AIBehaviourManager"
	for pair in [["Wander", AIWanderBehaviour], ["LookToward", AILookTowardBehaviour], ["Investigate", AIInvestigateBehaviour], ["Search", AISearchBehaviour], ["Chase", AIChaseBehaviour]]:
		var behaviour: AIBehaviourBase = pair[1].new()
		behaviour.name = pair[0]
		manager.add_child(behaviour)
	return manager


## Runs the crowd with timed parts, and prints each part's ms per tick and calls per tick.
func _run_breakdown(count: int) -> void:
	var input_ms := await _measure(count, true)
	print("--- AI stress breakdown: %d pawns, %d ticks ---" % [count, MEASURED_TICKS])
	print("TickDriver input phase: %.3f ms per tick (AI plus asking controllers for input)" % input_ms)
	print("part                                         ms per tick   calls per tick   us per call")
	for part: String in _totals:
		var entry: Array = _totals[part]
		print("%-44s %11.3f   %14.1f   %11.2f" % [part, entry[0] / 1000.0 / MEASURED_TICKS, float(entry[1]) / MEASURED_TICKS, float(entry[0]) / maxi(entry[1], 1)])
	print("(a running behaviour that finishes decides inside its tick, so that decision counts in both lines)")


## The AI parts with timing wrapped round them, swapped in before the pawn joins the tree, so PawnInitializer keeps them.
func _add_timed_parts(pawn: Pawn) -> void:
	var controllers: ControllerManager = load("res://assets/scenes/pawn/parts/ControllerManager.tscn").instantiate()
	var hands := controllers.get_node("AIController")
	hands.set_script(TimedHands)
	hands.totals = _totals
	pawn.add_child(controllers)
	var navigation: NavigationManager = load("res://assets/scenes/pawn/parts/NavigationManager.tscn").instantiate()
	navigation.set_script(TimedNavigation)
	navigation.totals = _totals
	pawn.add_child(navigation)
	var sensing: AISensingManager = load("res://assets/scenes/pawn/parts/AISensingManager.tscn").instantiate()
	sensing.set_script(TimedSensing)
	sensing.totals = _totals
	var sight := sensing.get_node("Sight")
	sight.set_script(TimedSight)
	sight.totals = _totals
	pawn.add_child(sensing)
	var selector := TimedSelector.new()
	selector.name = "AITargetSelector"
	selector.totals = _totals
	pawn.add_child(selector)
	var states: AIStateManager = load("res://assets/scenes/pawn/parts/AIStateManager.tscn").instantiate()
	states.set_script(TimedStates)
	states.totals = _totals
	pawn.add_child(states)
	var behaviours := TimedBehaviours.new()
	behaviours.name = "AIBehaviourManager"
	behaviours.totals = _totals
	for pair in [["Wander", AIWanderBehaviour], ["LookToward", AILookTowardBehaviour], ["Investigate", AIInvestigateBehaviour], ["Search", AISearchBehaviour], ["Chase", AIChaseBehaviour]]:
		var behaviour: AIBehaviourBase = pair[1].new()
		behaviour.name = pair[0]
		behaviours.add_child(behaviour)
	pawn.add_child(behaviours)
