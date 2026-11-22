## Written by Claude (claude-opus-5-5), 2026-11-16: headless self-test for ability steps and their timeline (AbilityStep, TimelineEntry
## and the runner in AbilityBase, ability spec 6), with test steps that log what happens to them: entries in order and side by side, one
## following another's start and a step's count waiting for it (the windup and turn), failing, the safety limit, cancel windows from step
## thresholds, invulnerable steps, the step signals, state rolling back, one step in two entries, start rules and the timeline's checks.
## Exits 0 on success, 1 on failure. Run from the project folder:
##   godot --headless --path . "res://assets/scripts/abilities/tests/ability_steps_selftest.tscn"
extends SelfTest # Claude 2026-11-16 (wider audit): _check and _failures come from tests/SelfTest.gd now

const PAWN_SCENE := "res://assets/scenes/pawn/pawn.tscn"


## A step that logs its enter, ticks and exit, and finishes or fails after a number of its own ticks.
class LogStep extends AbilityStep:
	var log: Array = [] # shared by the steps of one test: [step name, what, tick]
	var done_after := -1 # DONE on this tick of its own (counted), -1: never by itself
	var fail_after := -1
	var restart_on_exit: AbilityStep = null # a step this one starts when it stops: with stop_on_enter, a loop within one tick
	var stop_on_enter: AbilityStep = null
	var counts_while_stopped: AbilityStep = null # its length only counts while that step isn't running

	func enter() -> void:
		log.append([String(name), "enter", TickDriver.tick])
		if stop_on_enter:
			ability.stop_step(stop_on_enter)

	func tick(_dt: float) -> Status:
		log.append([String(name), "tick", TickDriver.tick])
		# GDScript note: step_ticks is the ticks counted before this one, so this is tick number step_ticks + 1.
		if fail_after >= 0 and step_ticks + 1 >= fail_after:
			return Status.FAILED
		if done_after >= 0 and step_ticks + 1 >= done_after:
			return Status.DONE
		return Status.RUNNING

	func exit(reason: String) -> void:
		log.append([String(name), "exit:" + reason, TickDriver.tick])
		if restart_on_exit:
			ability.start_step(restart_on_exit)

	func counts_this_tick() -> bool:
		return counts_while_stopped == null or not ability.is_step_running(counts_while_stopped)


## The ability the steps belong to: an attack on primary that roots the pawn.
class StepAttack extends AbilityBase:
	var starts := 0
	var stops := 0

	func _init() -> void:
		super()
		kind = Kind.ACTION
		trigger_action = &"primary"
		category = Tags.ABILITY.COMBAT_MELEE
		locks_out = [Tags.ABILITY.MOVEMENT, Tags.ABILITY.COMBAT]
		cooldown = 0.5
		interrupt_priority = 15
		interrupt_threshold = 50

	func start() -> void:
		starts += 1

	func stop() -> void:
		stops += 1


## Something that tries to cancel it: a dash with interrupt_priority 20.
class Canceller extends AbilityBase:
	func _init() -> void:
		super()
		kind = Kind.ACTION
		trigger_action = &"dash"
		category = Tags.ABILITY.MOVEMENT_DASH
		duration = 0.2
		interrupt_priority = 20


func _ready() -> void:
	TickDriver.tick_rate = TickDriver.REFERENCE_RATE # these count exact ticks at 60 a second
	print("--- Ability steps self-test ---")
	var floor_body := _make_floor()
	await _test_order_and_side_by_side()
	await _test_step_starting_a_step()
	await _test_failing()
	await _test_safety_limit()
	await _test_cancel_windows()
	await _test_invulnerable_step()
	await _test_rollback()
	await _test_loop_in_one_tick()
	await _test_going_along()
	await _test_released()
	await _test_one_step_twice()
	await _test_start_rules()
	await _test_timeline_checks()
	floor_body.free()
	print("--- ALL PASSED ---" if _failures == 0 else "--- %d FAILED ---" % _failures)
	get_tree().quit(0 if _failures == 0 else 1)


# A (3 ticks) first, then B (2 ticks) and C (done on its 4th tick) side by side.
func _test_order_and_side_by_side() -> void:
	var log: Array = []
	var attack := StepAttack.new()
	attack.name = "StepAttack"
	var a := _step(attack, "A", log)
	a.length_ticks = 3
	var b := _step(attack, "B", log)
	b.length_ticks = 2
	var c := _step(attack, "C", log)
	c.done_after = 4
	attack.step_timeline = [TimelineEntry.at(&"A"), TimelineEntry.after_end_of(&"B", &"A"), TimelineEntry.after_end_of(&"C", &"A")]
	var pawn := _make_pawn([attack])
	var manager := pawn.ability_manager
	var heard := {"started": 0, "finished": 0}
	manager.step_started.connect(func(_ability: AbilityBase, _step: AbilityStep) -> void: heard.started += 1)
	manager.step_finished.connect(func(_ability: AbilityBase, _step: AbilityStep, _reason: String) -> void: heard.finished += 1)
	await _ticks(10)
	_check(attack.is_stepped() and attack.steps.size() == 3 and attack.timeline.size() == 3, "an ability with AbilityStep children is stepped, and finds them and its timeline")
	_ai(pawn).press(&"primary")
	await _ticks(1)
	_check(attack.is_running_timed() and a.running and not b.running, "pressed: it starts, and only the entry at +0 runs")
	await _ticks(12)
	_check(_count(log, "A", "tick") == 3 and _tick_of(log, "A", "exit:done") == _tick_of(log, "B", "enter"), "A runs its 3 ticks, and B starts on the tick A is done")
	_check(_tick_of(log, "B", "enter") == _tick_of(log, "C", "enter"), "and C with it: both side by side")
	_check(_tick_of(log, "B", "tick") == _tick_of(log, "B", "enter") + 1, "a step started during a tick has its first tick on the next one")
	_check(_count(log, "B", "tick") == 2 and _count(log, "C", "tick") == 4, "B runs 2 ticks and C 4, at the same time")
	_check(not attack.is_running_timed() and attack.stops == 1 and attack.cooldown_ticks_left() > 0, "the ability ends when its last step does, with its cooldown")
	_check(_count(log, "C", "exit:done") == 1 and _count(log, "B", "exit:cancelled") == 0, "every step said done, none cancelled")
	_check(heard.started == 3 and heard.finished == 3, "step_started and step_finished for each step (%d, %d)" % [heard.started, heard.finished])
	pawn.free()


# The windup and turn: T starts when W starts, and W's 3 ticks only count once T is done (T takes 2).
func _test_step_starting_a_step() -> void:
	var log: Array = []
	var attack := StepAttack.new()
	attack.name = "StepAttack"
	var w := _step(attack, "W", log)
	w.length_ticks = 3
	var t := _step(attack, "T", log)
	t.done_after = 2
	w.counts_while_stopped = t
	var with_w := TimelineEntry.new()
	with_w.step = &"T"
	with_w.after = &"W"
	with_w.after_event = TimelineEntry.After.STARTS
	attack.step_timeline = [TimelineEntry.at(&"W"), with_w]
	var pawn := _make_pawn([attack])
	await _ticks(10)
	_ai(pawn).press(&"primary")
	await _ticks(1)
	_check(w.running and t.running and attack.get_running_step_names() == PackedStringArray(["W", "T"]), "an entry can follow another's start: T starts with W, and both run (%s)" % " + ".join(attack.get_running_step_names()))
	await _ticks(10)
	_check(_count(log, "T", "tick") == 2 and _count(log, "W", "tick") == 5, "W's 3 ticks only counted once T was done: 5 ticks in all")
	_check(not attack.is_running_timed(), "then the ability ends")
	pawn.free()


# F fails on its 2nd tick while G runs beside it: everything ends, with "failed".
func _test_failing() -> void:
	var log: Array = []
	var attack := StepAttack.new()
	attack.name = "StepAttack"
	var f := _step(attack, "F", log)
	f.fail_after = 2
	_step(attack, "G", log)
	attack.step_timeline = [TimelineEntry.at(&"F"), TimelineEntry.at(&"G")]
	var pawn := _make_pawn([attack])
	await _ticks(10)
	_ai(pawn).press(&"primary")
	await _ticks(5)
	_check(_count(log, "F", "exit:failed") == 1 and _count(log, "G", "exit:failed") == 1, "a step failing stops the others with \"failed\"")
	_check(not attack.is_running_timed() and attack.stops == 1 and attack.cooldown_ticks_left() > 0, "and ends the ability, with its cooldown")
	pawn.free()


# A step that never finishes: the ability ends at max_steps_ticks anyway.
func _test_safety_limit() -> void:
	var log: Array = []
	var attack := StepAttack.new()
	attack.name = "StepAttack"
	attack.max_steps_ticks = 8
	_step(attack, "Forever", log)
	var pawn := _make_pawn([attack])
	await _ticks(10)
	_ai(pawn).press(&"primary")
	await _ticks(12)
	_check(not attack.is_running_timed() and _count(log, "Forever", "tick") == 8 and _count(log, "Forever", "exit:cancelled") == 1,
			"a step that never finishes is stopped at max_steps_ticks (%d ticks), as cancelled" % _count(log, "Forever", "tick"))
	pawn.free()


# X (threshold 100) then Y (threshold 0), with no timeline: one after another. The ability's own is 50, and the dash's priority 20.
func _test_cancel_windows() -> void:
	var log: Array = []
	var attack := StepAttack.new()
	attack.name = "StepAttack"
	var x := _step(attack, "X", log)
	x.length_ticks = 10
	x.interrupt_threshold = 100
	var y := _step(attack, "Y", log)
	y.length_ticks = 10
	y.interrupt_threshold = 0
	var dash := Canceller.new()
	dash.name = "Dash"
	var pawn := _make_pawn([attack, dash])
	var manager := pawn.ability_manager
	await _ticks(10)
	_ai(pawn).press(&"primary")
	await _ticks(3)
	_check(manager.interrupt_threshold_now(attack) == 100, "while X runs, the ability's threshold is X's (100), not its own 50")
	_ai(pawn).press(&"dash")
	await _ticks(2)
	_check(attack.is_running_timed() and not dash.is_running_timed(), "so the dash (20) can't cancel it")
	await _ticks(10)
	_check(y.running and manager.interrupt_threshold_now(attack) == 0, "with no timeline its steps run one after another: while Y runs, it's Y's (0)")
	_ai(pawn).press(&"dash")
	await _ticks(2)
	_check(not attack.is_running_timed() and dash.is_running_timed() and _count(log, "Y", "exit:cancelled") == 1,
			"so the dash cancels it, and Y is told it was cancelled")
	pawn.free()


func _test_invulnerable_step() -> void:
	var log: Array = []
	var attack := StepAttack.new()
	attack.name = "StepAttack"
	var shield := _step(attack, "Shield", log)
	shield.length_ticks = 5
	var dodge := InvulnerabilityInterceptor.new() # Claude 2026-11-17 (pawn spec 8.23): was the step's invulnerable flag
	dodge.name = "Invulnerable"
	shield.add_child(dodge)
	var open := _step(attack, "Open", log)
	open.length_ticks = 5
	var pawn := _make_pawn([attack])
	var manager := pawn.ability_manager
	await _ticks(10)
	_ai(pawn).press(&"primary")
	await _ticks(2)
	_check(manager.is_invulnerable(), "a running step with an InvulnerabilityInterceptor makes the pawn invulnerable")
	await _ticks(6)
	_check(open.running and not manager.is_invulnerable(), "and not once the next step runs")
	pawn.free()


func _test_rollback() -> void:
	var log: Array = []
	var attack := StepAttack.new()
	attack.name = "StepAttack"
	var a := _step(attack, "A", log)
	a.length_ticks = 6
	var b := _step(attack, "B", log)
	b.length_ticks = 20
	var pawn := _make_pawn([attack])
	await _ticks(10)
	var listed: Array[String] = (pawn.get_node("TickState") as TickStateComponent).state_properties
	# Claude 2026-11-22 (ability spec 6.2): the timeline's state, one value on the ability, as step_state was.
	_check(listed.has("AbilityManager/StepAttack:timeline_state pushed") and not listed.has("AbilityManager/StepAttack/A:running"), "the timeline's state rolls back, as one value on its ability")
	_ai(pawn).press(&"primary")
	await _ticks(10)
	await get_tree().physics_frame
	var real := [a.running, b.running, a.step_ticks, b.step_ticks, attack.ticks_left()]
	var went_back: bool = TickDriver.rollback(TickDriver.tick - 8) # back to while A was running
	var after := [a.running, b.running, a.step_ticks, b.step_ticks, attack.ticks_left()]
	_check(went_back and after == real, "a replay from inside A ends in the same steps on the same tick (%s, was %s)" % [str(after), str(real)])
	pawn.free()


# The safeguard: code that stops Loop when it starts and starts it again when it stops would go round forever in one tick.
func _test_loop_in_one_tick() -> void:
	var log: Array = []
	var attack := StepAttack.new()
	attack.name = "StepAttack"
	var loop := _step(attack, "Loop", log)
	loop.stop_on_enter = loop
	loop.restart_on_exit = loop
	var pawn := _make_pawn([attack])
	await _ticks(10)
	print("  (a warning about too many step starts is expected next)")
	_ai(pawn).press(&"primary")
	await _ticks(3)
	var starts := _count(log, "Loop", "enter")
	_check(starts <= AbilityBase.MAX_STEP_STARTS_PER_TICK and not attack.is_running_timed(),
			"steps started from code in a loop within one tick are stopped at %d starts, and the ability ends (%d)" % [AbilityBase.MAX_STEP_STARTS_PER_TICK, starts])
	pawn.free()


# Along runs forever beside Main (3 ticks), but has keeps_ability_running off: the ability ends with Main, and Along stops with "done".
func _test_going_along() -> void:
	var log: Array = []
	var attack := StepAttack.new()
	attack.name = "StepAttack"
	var main := _step(attack, "Main", log)
	main.length_ticks = 3
	var along := _step(attack, "Along", log)
	along.keeps_ability_running = false
	attack.step_timeline = [TimelineEntry.at(&"Main"), TimelineEntry.at(&"Along")]
	var pawn := _make_pawn([attack])
	await _ticks(10)
	_ai(pawn).press(&"primary")
	await _ticks(6)
	_check(not attack.is_running_timed() and _count(log, "Along", "exit:done") == 1 and _count(log, "Along", "tick") == 3,
			"a step with keeps_ability_running off doesn't keep it going: it ends with the main step, and stops with done")
	pawn.free()


# Claude 2026-11-16: any step can end on release (ends_when_released): Hold ends the tick its action is let go, with "released", and
# what follows it (After) starts as if it were done.
func _test_released() -> void:
	var log: Array = []
	var attack := StepAttack.new()
	attack.name = "StepAttack"
	var hold := _step(attack, "Hold", log)
	hold.ends_when_released = true
	var after := _step(attack, "After", log)
	after.length_ticks = 3
	var pawn := _make_pawn([attack])
	var ai := _ai(pawn)
	await _ticks(10)
	_check(hold.hold_bit == InputActions.mask_of(&"primary"), "with no while_held, a step watches its ability's own action")
	ai.hold(&"primary", true)
	await _ticks(8)
	_check(hold.running and hold.is_held(), "held: it keeps running")
	ai.hold(&"primary", false)
	await _ticks(2)
	_check(not hold.running and _count(log, "Hold", "exit:released") == 1 and after.running, "let go: it ends as released, and its next step starts")
	await _ticks(5)
	_check(not attack.is_running_timed(), "and the ability finishes as usual")
	pawn.free()


# Claude 2026-11-22 (ability spec 6.2): one step in two entries, with values of their own (a second sweep on a backswing).
func _test_one_step_twice() -> void:
	var log: Array = []
	var attack := StepAttack.new()
	attack.name = "StepAttack"
	var swing := _step(attack, "Swing", log)
	swing.length_ticks = 5
	attack.step_timeline = [TimelineEntry.at(&"Swing", 0, {"length_ticks": 2}),
		TimelineEntry.after_end_of(&"Swing", &"Swing", {"length_ticks": 4}, &"Backswing")]
	var pawn := _make_pawn([attack])
	await _ticks(10)
	_ai(pawn).press(&"primary")
	await _ticks(12)
	_check(_count(log, "Swing", "enter") == 2 and _count(log, "Swing", "tick") == 6, "one step runs in two entries, each with its own length (2, then 4)")
	_check(not attack.is_running_timed() and swing.length_ticks == 5, "and its own value comes back when the ability ends")
	pawn.free()


# Claude 2026-11-22: entries by time, after a delay, on a condition, and an end reason that doesn't count.
func _test_start_rules() -> void:
	var log: Array = []
	var attack := StepAttack.new()
	attack.name = "StepAttack"
	var a := _step(attack, "A", log)
	a.length_ticks = 2
	var late := _step(attack, "Late", log)
	late.length_ticks = 1
	var delayed := _step(attack, "Delayed", log)
	delayed.length_ticks = 1
	var on_condition := _step(attack, "OnCondition", log)
	on_condition.length_ticks = 1
	var after_delay := TimelineEntry.after_end_of(&"Delayed", &"A")
	after_delay.delay_ticks = 3
	var running_long := AbilityCondition.new()
	running_long.input = AbilityCondition.Reads.TICKS_RUNNING
	running_long.comparison = AbilityCondition.Comparison.AT_LEAST
	running_long.value = 4
	var by_condition := TimelineEntry.new()
	by_condition.step = &"OnCondition"
	by_condition.condition = running_long
	attack.step_timeline = [TimelineEntry.at(&"A"), TimelineEntry.at(&"Late", 8), after_delay, by_condition]
	var pawn := _make_pawn([attack])
	await _ticks(10)
	_ai(pawn).press(&"primary")
	await _ticks(14)
	var start := _tick_of(log, "A", "enter")
	_check(_tick_of(log, "Late", "enter") == start + 8, "at_tick 8: it starts 8 ticks after the ability (+%d)" % (_tick_of(log, "Late", "enter") - start))
	_check(_tick_of(log, "Delayed", "enter") == _tick_of(log, "A", "exit:done") + 3, "a delay: 3 ticks after A is done")
	_check(_tick_of(log, "OnCondition", "enter") == start + 4, "a condition: the first tick it holds (+%d)" % (_tick_of(log, "OnCondition", "enter") - start))
	_check(_count(log, "Late", "exit:done") == 1 and attack.stops == 1, "nothing ran between ticks 5 and 8, yet the ability waited for the entry still due")
	pawn.free()
	# Cut, A ends "cancelled": what follows its end (done or released) doesn't start, so a cancelled windup doesn't swing.
	log.clear()
	var cut_attack := StepAttack.new()
	cut_attack.name = "StepAttack"
	var cut_a := _step(cut_attack, "A", log)
	cut_a.length_ticks = 5
	var cutter := _step(cut_attack, "Cutter", log)
	cutter.length_ticks = 2
	cutter.stop_on_enter = cut_a
	_step(cut_attack, "B", log)
	cut_attack.step_timeline = [TimelineEntry.at(&"A"), TimelineEntry.at(&"Cutter"), TimelineEntry.after_end_of(&"B", &"A")]
	pawn = _make_pawn([cut_attack])
	await _ticks(10)
	_ai(pawn).press(&"primary")
	await _ticks(6)
	_check(_count(log, "A", "exit:cancelled") == 1 and _count(log, "B", "enter") == 0 and not cut_attack.is_running_timed(), "an end that isn't done or released doesn't start what follows")
	pawn.free()


# Claude 2026-11-22: a timeline is checked once, when it's worked out.
func _test_timeline_checks() -> void:
	var log: Array = []
	var attack := StepAttack.new()
	attack.name = "StepAttack"
	_step(attack, "A", log)
	_step(attack, "Spare", log)
	var lost := TimelineEntry.after_end_of(&"A", &"Nowhere", {}, &"Second")
	attack.step_timeline = [TimelineEntry.at(&"A"), TimelineEntry.at(&"Missing"), lost]
	print("  (warnings about a missing step and an \"after\" naming no entry are expected next)")
	var pawn := _make_pawn([attack])
	await _ticks(2)
	var labels: Array = attack.timeline.map(func(entry: TimelineEntry) -> String: return "%s%s" % [entry.get_label(), " (manual)" if entry.manual else ""])
	_check(labels == ["A", "Second", "Spare (manual)"], "an entry naming a missing step is left out, and a step none names gets a manual entry (%s)" % str(labels))
	pawn.free()


# --- Helpers ---


func _step(attack: AbilityBase, step_name: String, log: Array) -> LogStep:
	var step := LogStep.new()
	step.name = step_name
	step.log = log
	attack.add_child(step)
	return step


func _make_pawn(abilities: Array) -> Pawn:
	var pawn: Pawn = load(PAWN_SCENE).instantiate()
	pawn.position = Vector3(0, 0.1, 0)
	var manager := AbilityManager.new()
	manager.name = "AbilityManager" # the same name as the default, so PawnInitializer leaves this one alone
	var walk := WalkAbility.new()
	walk.name = "Walk"
	manager.add_child(walk)
	for ability: AbilityBase in abilities:
		manager.add_child(ability)
	pawn.add_child(manager)
	add_child(pawn)
	return pawn


func _count(log: Array, step_name: String, what: String) -> int:
	return log.filter(func(entry: Array) -> bool: return entry[0] == step_name and entry[1] == what).size()


# The tick of the first entry like this, or -1.
func _tick_of(log: Array, step_name: String, what: String) -> int:
	for entry: Array in log:
		if entry[0] == step_name and entry[1] == what:
			return entry[2]
	return -1


func _ai(pawn: Pawn) -> AIController:
	return pawn.controller_manager.ai_controller as AIController


func _make_floor() -> StaticBody3D:
	var body := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(200.0, 1.0, 200.0)
	shape.shape = box
	shape.position.y = -0.5
	body.add_child(shape)
	add_child(body)
	return body


func _ticks(count: int) -> void:
	for i in count:
		await get_tree().physics_frame
