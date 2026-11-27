# Written by Claude (claude-opus-5-5), 2026-11-27. History: steps/CHANGELOG.md.
## Headless self-test for the step library and AI behaviours hosting steps (pawn spec 16.7, 16.10 step 7): buttons, looks, moves and
## flow steps on a behaviour's timeline, the thin AI controller handing over what they write, the move step's repath rules, step
## conditions, and the order stream's hook.
##   godot --headless --path . "res://assets/scripts/steps/tests/step_library_selftest.tscn"
extends SelfTest

const PAWN_SCENE := "res://assets/scenes/pawn/pawn.tscn"
const NEVER := 100000000 # a decision interval so long the pawn never decides on its own


## A behaviour holding one of every library step, started by the test; it never ends on its own.
class Driver extends AIBehaviourBase:
	func make_steps() -> Array[Step]:
		return [made_step(MoveToStep, &"MoveTo"), made_step(FollowStep, &"Follow"), made_step(KeepAwayFromStep, &"KeepAway"),
			made_step(StopMovingStep, &"StopMoving"), made_step(LookAtStep, &"LookAt"), made_step(LookInDirectionStep, &"LookDir"),
			made_step(StopLookingStep, &"StopLooking"), made_step(PressStep, &"Press", {"action": &"jump"}), made_sprint_step(),
			made_step(ReleaseStep, &"Release"), made_step(DelayStep, &"Delay"), made_step(WaitUntilStep, &"WaitUntil"),
			made_step(RepeatStep, &"Repeat", {"step": &"Press", "times": 3})]


func _ready() -> void:
	TickDriver.tick_rate = TickDriver.REFERENCE_RATE
	print("--- Step library self-test ---")
	var floor_body := _make_floor(200.0)
	var pawn := _make_pawn(Vector3(0, 0.1, 0))
	await _ticks(10)
	var driver := pawn.ai.behaviour_manager.get_node("Driver") as Driver
	_decide(pawn)
	_check(pawn.ai.behaviour_manager.get_running_behaviour() == driver, "(the driver behaviour runs)")
	_test_buttons(pawn, driver)
	_test_looks(pawn, driver)
	await _test_moves(pawn, driver)
	await _test_flow(pawn, driver)
	_test_conditions(pawn, driver)
	_test_order_hook(pawn, driver)
	pawn.free()
	floor_body.free()
	_finish()


func _test_buttons(pawn: Pawn, driver: Driver) -> void:
	var ai := pawn.ai.controller
	var sprint := InputActions.mask_of(&"sprint")
	var jump := InputActions.mask_of(&"jump")
	driver.start_step(AIBehaviourBase.SPRINT_STEP)
	_check(ai.take_input_command(TickDriver.tick).held_actions & sprint != 0, "Hold: its action is held")
	_check(ai.take_input_command(TickDriver.tick).held_actions & sprint != 0, "and stays held")
	driver.start_step(&"Press")
	_check(ai.take_input_command(TickDriver.tick).held_actions & jump != 0, "Press: its action for one input")
	_check(ai.take_input_command(TickDriver.tick).held_actions & jump == 0 and not driver.is_step_running(&"Press"),
			"then let go, and the step is done")
	_check_equal(driver.step_result(&"Press"), "done", "step_result says how it ended")
	driver.start_step(&"Release", {"action": &"sprint"})
	_check(not driver.is_step_running(AIBehaviourBase.SPRINT_STEP), "Release stops the Hold of its action")
	_check(ai.take_input_command(TickDriver.tick).held_actions & sprint == 0, "so it's let go")
	driver.start_step(&"Repeat")
	var presses := 0
	for i in 12:
		if ai.take_input_command(TickDriver.tick).held_actions & jump != 0:
			presses += 1
	_check(presses == 3 and not driver.is_step_running(&"Repeat"), "Repeat runs Press three times, then is done (%d presses)" % presses)
	# A fresh press: the last input held the action, so the hold starts a tick late.
	pawn.controller_manager.held_actions = sprint
	var hold := driver.start_step(AIBehaviourBase.SPRINT_STEP, {"fresh_press": true}) as HoldStep
	_check(hold.hold_from_tick() == TickDriver.tick + 1, "Hold with fresh_press: held last input, so it holds from the next tick")
	_check(ai.take_input_command(TickDriver.tick).held_actions & sprint == 0, "and lets go this tick, so its hold starts with a press")
	driver.stop_step(AIBehaviourBase.SPRINT_STEP)
	pawn.controller_manager.held_actions = 0


func _test_looks(pawn: Pawn, driver: Driver) -> void:
	var ai := pawn.ai.controller
	var eye := pawn.global_position + Vector3(0, pawn.eye_height, 0)
	driver.start_step(&"LookAt", {"target": null, "point": eye + Vector3(0, 0, -5)})
	var ahead := ai.take_input_command(TickDriver.tick)
	_check(is_zero_approx(ahead.look_yaw) and is_zero_approx(ahead.look_pitch), "LookAt a point straight ahead from the eyes: yaw 0, pitch 0")
	_check(ai.is_looking_at_something(), "and the controller says it's looking at something (AI sight faces that way)")
	driver.start_step(&"StopLooking")
	pawn.controller_manager.look_yaw = 0.4
	var own := ai.take_input_command(TickDriver.tick)
	_check(not driver.is_step_running(&"LookAt") and is_equal_approx(own.look_yaw, 0.4), "StopLooking: the pawn's own look again")
	_check(not ai.is_looking_at_something(), "and nothing is looked at")
	driver.start_step(&"LookDir", {"yaw_degrees": 90.0, "pitch_degrees": 0.0})
	_check(is_equal_approx(ai.take_input_command(TickDriver.tick).look_yaw, PI / 2), "LookInDirection: 90 degrees is a quarter turn left")
	driver.stop_step(&"LookDir")


func _test_moves(pawn: Pawn, driver: Driver) -> void:
	var target := Node3D.new()
	add_child(target)
	target.global_position = Vector3(6, 0, 0)
	driver.start_step(&"Follow", {"target": target, "stop_distance": 1.5, "band": 0.3})
	await _ticks(150)
	var follow := driver.get_step(&"Follow") as FollowStep
	_check(follow.is_standing() and _flat(pawn, target) < 1.5 + 0.3, "Follow closes in and stands within its distance (%.2f m)" % _flat(pawn, target))
	target.global_position = Vector3(-6, 0, 0)
	await _ticks(240)
	_check(_flat(pawn, target) < 1.5 + 0.3, "and follows the target when it moves (%.2f m)" % _flat(pawn, target))
	driver.start_step(&"StopMoving")
	_check(not driver.is_step_running(&"Follow"), "StopMoving stops it")
	driver.start_step(&"KeepAway", {"target": target, "stop_distance": 5.0, "band": 1.0})
	await _ticks(180)
	_check(absf(_flat(pawn, target) - 5.0) <= 1.0, "KeepAwayFrom backs off to its distance (%.2f m)" % _flat(pawn, target))
	driver.stop_step(&"KeepAway")
	# A dropped path (charge changing hands) is found again when the step next runs.
	var walk := driver.start_step(&"MoveTo", {"goal": Vector3(5, 0, 5)}) as MoveToStep
	await _ticks(2)
	walk.follower.stop()
	_check(not walk.follower.is_under_way(), "(its path dropped)")
	await _ticks(2)
	_check(walk.follower.is_under_way(), "MoveTo finds its path again after it was dropped")
	# Knocked off the path: with off_path_metres set, a new path from where it stands.
	walk.off_path_metres = 0.5
	pawn.global_position += Vector3(0, 0, -3)
	await _ticks(3)
	_check(walk.follower.distance_off_path() < 0.5, "knocked off its path, it finds a new one (%.2f m off)" % walk.follower.distance_off_path())
	# A rollback loading old state: a fresh path too. A straight walk's new path has the same corners, so the check reads when the
	# step last asked for one.
	var asked_before: int = walk._path_tick
	TickDriver.rollbacks_loaded += 1
	await _ticks(1)
	_check(walk._path_tick > asked_before and walk._rollbacks_seen == TickDriver.rollbacks_loaded, "after a rollback loaded old state, a fresh path")
	var waited := 0
	while driver.is_step_running(&"MoveTo") and waited < 600:
		await _ticks(1)
		waited += 1
	_check_equal(driver.step_result(&"MoveTo"), "done", "and it arrives (%d ticks)" % waited)
	_check(walk.follower.has_arrived(), "its follower still says it arrived once the step is done")
	walk.off_path_metres = 0.0
	target.free()


func _test_flow(_pawn: Pawn, driver: Driver) -> void:
	driver.start_step(&"Delay", {"until_tick": TickDriver.tick + 5})
	await _ticks(3)
	_check(driver.is_step_running(&"Delay"), "Delay runs until its tick")
	await _ticks(5)
	_check_equal(driver.step_result(&"Delay"), "done", "then is done")
	driver.start_step(&"WaitUntil", {"condition": StepCondition.make(StepCondition.Reads.GROUNDED, StepCondition.Comparison.EQUAL, 1.0)})
	await _ticks(2)
	_check_equal(driver.step_result(&"WaitUntil"), "done", "WaitUntil is done once its condition holds (on the ground)")
	driver.start_step(AIBehaviourBase.SPRINT_STEP)
	var never := StepCondition.make(StepCondition.Reads.STAT, StepCondition.Comparison.AT_LEAST, 5.0)
	never.stat = &"NoSuchStat"
	driver.start_step(&"WaitUntil", {"condition": never, "length_ticks": 4})
	await _ticks(8)
	_check_equal(driver.step_result(&"WaitUntil"), "failed", "with a length, it fails once that runs out")
	_check(not driver.is_step_running(AIBehaviourBase.SPRINT_STEP), "and a failed step ends the run: the others stop too")


func _test_conditions(pawn: Pawn, driver: Driver) -> void:
	var other := Node3D.new()
	add_child(other)
	other.global_position = pawn.global_position + Vector3(6, 0, 0)
	var band := StepCondition.make(StepCondition.Reads.TARGET_DISTANCE, StepCondition.Comparison.BETWEEN, 4.0, 8.0)
	_check_equal(band.read(driver.timeline), AIInputs.FAR, "TARGET_DISTANCE with no target: FAR")
	pawn.ai.current_target = other
	_check(band.holds(driver.timeline), "TARGET_DISTANCE BETWEEN 4 and 8: holds at 6 m")
	other.global_position = pawn.global_position + Vector3(9, 0, 0)
	_check(not band.holds(driver.timeline), "and not at 9 m")
	pawn.ai.current_target = null
	other.free()
	var held := StepCondition.make(StepCondition.Reads.ACTION_HELD, StepCondition.Comparison.EQUAL, 1.0)
	held.action = &"primary"
	pawn.controller_manager.held_actions = InputActions.mask_of(&"primary")
	_check(held.holds(driver.timeline), "ACTION_HELD: 1 while its action is held")
	pawn.controller_manager.held_actions = 0
	_check(not held.holds(driver.timeline), "and 0 once let go")
	_check_equal(driver.default_action(), driver.settings.presses_action, "with no action it reads the behaviour's presses_action (default_action())")


func _test_order_hook(_pawn: Pawn, driver: Driver) -> void:
	var heard: Array = []
	AIBehaviourManager.order_listener = func(_manager: AIBehaviourManager, event: StringName, args: Array) -> void: heard.append([event, args])
	driver.start_step(&"MoveTo", {"goal": Vector3(1, 0, 1)})
	driver.stop_step(&"MoveTo", "cancelled")
	AIBehaviourManager.order_listener = Callable()
	_check(heard.size() == 2 and heard[0][0] == &"step_started" and heard[0][1][1] == &"MoveTo" and heard[0][1][2]["goal"] == Vector3(1, 0, 1),
			"the order hook hears a step started, with its values")
	_check(heard.size() == 2 and heard[1][0] == &"step_stopped", "and stopped by code")


# --- Helpers ---


func _make_pawn(at: Vector3) -> Pawn:
	var pawn: Pawn = load(PAWN_SCENE).instantiate()
	pawn.position = at
	var manager := AIBehaviourManager.new()
	manager.name = "AIBehaviourManager"
	var driver := Driver.new()
	driver.name = "Driver"
	manager.add_child(driver)
	AITestPawns.ai_of(pawn).add_child(manager)
	add_child(pawn)
	pawn.ai.decision_interval_ticks = NEVER
	return pawn


func _decide(pawn: Pawn) -> void:
	var context := pawn.ai
	context.current_tick = TickDriver.tick
	context.request_decision()
	if context.state_manager:
		context.state_manager.update_state(TickDriver.tick)
	context.behaviour_manager.decide(TickDriver.tick)


func _make_floor(size: float) -> StaticBody3D:
	var body := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(size, 1.0, size)
	shape.shape = box
	shape.position.y = -0.5
	body.add_child(shape)
	add_child(body)
	return body


func _flat(pawn: Pawn, node: Node3D) -> float:
	return Vector2(pawn.global_position.x - node.global_position.x, pawn.global_position.z - node.global_position.z).length()


func _ticks(count: int) -> void:
	for i in count:
		await get_tree().physics_frame
