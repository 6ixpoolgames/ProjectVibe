## Written by Claude (claude-opus-5-5), 2026-11-07: headless self-test for ControllerManager and AIController. Checks the rule for who's
## in charge, the odd cases at the top of ControllerManager.gd, and that the AI takes over when a player lets go.
## Exits 0 on success, 1 on failure. Run from the project folder:
##   "C:\Git\Test 2\Godot_v4.7.2-stable_win64_console.exe" --headless --path . "res://assets/scripts/controllers/tests/controller_manager_selftest.tscn"
extends Node

const PAWN_SCENE := "res://assets/scenes/pawn/pawn.tscn"

var _failures := 0


## Stands in for a player's controller: always walks one way.
class FixedController extends ControllerBase:
	var direction := Vector3(0, 0, -1)

	func take_input_command(_tick: int) -> InputCommand:
		return InputCommand.make(direction)


func _ready() -> void:
	print("--- Controller manager self-test ---")
	await _test_parts_are_there()
	await _test_ai_drives_an_unpossessed_pawn()
	await _test_player_takes_over_and_lets_go()
	await _test_player_elsewhere()
	await _test_through_possession()
	await _test_odd_cases()
	_test_look_at_point()
	print("--- ALL PASSED ---" if _failures == 0 else "--- %d FAILED ---" % _failures)
	get_tree().quit(0 if _failures == 0 else 1)


func _test_parts_are_there() -> void:
	var pawn := _make_pawn()
	await get_tree().process_frame
	var manager := pawn.controller_manager
	_check(manager != null and manager.pawn == pawn, "a pawn gets a ControllerManager, which knows its pawn")
	_check(manager.ai_controller is AIController and manager.ai_controller.pawn == pawn, "with an AIController that knows the pawn too")
	_check(manager.get_controller_in_charge() == manager.ai_controller, "nobody has the pawn, so the AI is in charge")
	pawn.free()


func _test_ai_drives_an_unpossessed_pawn() -> void:
	var floor_body := _make_floor()
	var pawn := _make_pawn(Vector3(0, 0.1, 0))
	await _ticks(20)
	var ai: AIController = pawn.controller_manager.ai_controller
	ai.move_in_direction(Vector3(1, 0, 0))
	await _ticks(30)
	_check(pawn.position.x > 0.5, "the AI's direction moves the pawn (%.2f m)" % pawn.position.x)
	ai.stop()
	await _ticks(30)
	_check(pawn.velocity.length() < 0.01, "and stop() stands it still")
	ai.press(&"jump")
	await _ticks(1)
	_check(pawn.velocity.y > 0.0, "press() reaches the pawn as a press: it jumps")
	await _ticks(1)
	_check(not pawn.is_action_held(&"jump"), "and lasts one tick")
	ai.hold(&"sprint")
	await _ticks(1)
	_check(pawn.is_action_held(&"sprint"), "hold() keeps an action held")
	ai.release_all()
	await _ticks(1)
	_check(pawn.held_actions == 0 and pawn.move_input == Vector3.ZERO, "release_all() goes back to idle")
	pawn.free()
	floor_body.free()


func _test_player_takes_over_and_lets_go() -> void:
	var pawn := _make_pawn()
	await _ticks(1) # on a physics frame, so each _ticks(1) below holds exactly one tick
	var manager := pawn.controller_manager
	var ai: AIController = manager.ai_controller
	ai.move_in_direction(Vector3(1, 0, 0))
	var changes: Array = []
	manager.controller_changed.connect(func(controller): changes.append(controller))
	var player := FixedController.new()
	add_child(player)
	# The same order PossessionCoordinator uses: the pawn learns it has a player, then the controller attaches.
	pawn.set_has_player(true)
	manager.attach_player(player)
	_check(manager.get_controller_in_charge() == player, "a player's controller attached here is in charge")
	await _ticks(1)
	_check(pawn.move_input.is_equal_approx(Vector3(0, 0, -1)), "and the pawn follows it, not the AI (%s)" % str(pawn.move_input))
	manager.detach_player(player)
	pawn.set_has_player(false)
	_check(manager.get_controller_in_charge() == ai, "when the player lets go, the AI is in charge again")
	await _ticks(1)
	_check(pawn.move_input.is_equal_approx(Vector3(1, 0, 0)), "and the pawn carries on with what the AI was told")
	await get_tree().process_frame
	_check(changes.size() == 2 and changes[0] == player and changes[1] == ai,
			"controller_changed fires once per change, never with 'nobody' in between (%d times)" % changes.size())
	var stranger := FixedController.new()
	manager.detach_player(stranger)
	stranger.free()
	await get_tree().process_frame
	_check(changes.size() == 2, "letting go with a controller that isn't attached changes nothing")
	player.free()
	pawn.free()


## A client's pawn on the server: a player has it, but their controller is on another machine.
func _test_player_elsewhere() -> void:
	var pawn := _make_pawn()
	await _ticks(1) # on a physics frame, so each _ticks(1) below holds exactly one tick
	pawn.set_has_player(true)
	_check(pawn.controller_manager.get_controller_in_charge() == null, "a player elsewhere has it: nobody here is in charge")
	pawn.apply_input(InputCommand.make(Vector3(0, 0, 1))) # what the network would write
	await _ticks(1)
	_check(pawn.move_input.is_equal_approx(Vector3(0, 0, 1)), "so nothing here replaces the input that came over the network")
	pawn.free()


func _test_through_possession() -> void:
	var possession: PossessionCoordinator = GameMode.possession_coordinator
	if possession == null or possession.controller == null:
		_check(false, "this test needs PossessionCoordinator and its controller")
		return
	var pawn := _make_pawn()
	await get_tree().process_frame
	possession.possess(pawn)
	_check(pawn.controller_manager.get_controller_in_charge() == possession.controller, "possessing puts the player's controller in charge")
	possession.release()
	_check(pawn.controller_manager.get_controller_in_charge() == pawn.controller_manager.ai_controller, "and releasing hands the pawn to its AI")
	pawn.free()
	await get_tree().process_frame


func _test_odd_cases() -> void:
	# Not on a pawn.
	var loose := ControllerManager.new()
	print("  (a warning about a ControllerManager outside a pawn is expected next)")
	add_child(loose)
	_check(loose.pawn == null and loose.get_controller_in_charge() == null and loose.take_input_command(0) == null, "outside a pawn, nobody is ever in charge")
	loose.free()
	# A pawn whose manager has no AI controller.
	var pawn := _make_pawn()
	await _ticks(1) # on a physics frame, so each _ticks(1) below holds exactly one tick
	var manager := pawn.controller_manager
	manager.ai_controller.free()
	_check(manager.get_controller_in_charge() == null, "no AI controller: nobody is in charge of an unpossessed pawn")
	pawn.apply_input(InputCommand.make(Vector3(1, 0, 0)))
	await _ticks(1)
	_check(pawn.move_input.is_equal_approx(Vector3(1, 0, 0)), "and its input stays as it is")
	# A player's controller freed while attached.
	var player := FixedController.new()
	add_child(player)
	manager.attach_player(player)
	player.free()
	_check(manager.get_controller_in_charge() == null, "a freed player controller is ignored, as if it let go")
	await _ticks(1) # nothing should break
	pawn.free()


func _test_look_at_point() -> void:
	var pawn: Pawn = load(PAWN_SCENE).instantiate()
	add_child(pawn)
	var ai: AIController = pawn.controller_manager.ai_controller
	# Claude 2026-11-07: until it's told where to look, it keeps the pawn's own look, so taking over from a player doesn't snap it.
	pawn.look_yaw = 0.7
	pawn.look_pitch = -0.2
	var kept := ai.take_input_command(0)
	_check(is_equal_approx(kept.look_yaw, 0.7) and is_equal_approx(kept.look_pitch, -0.2), "not told where to look: it keeps the pawn's own look")
	ai.look_at_point(pawn.global_position + Vector3(0, 0, -5))
	var straight := ai.take_input_command(0)
	_check(is_zero_approx(straight.look_yaw) and is_zero_approx(straight.look_pitch), "look_at_point: straight ahead is yaw 0")
	ai.look_at_point(pawn.global_position + Vector3(-5, 5, 0))
	var left_up := ai.take_input_command(0)
	_check(is_equal_approx(left_up.look_yaw, PI / 2) and is_equal_approx(left_up.look_pitch, PI / 4), "and to the left and up is a quarter turn, 45 degrees up")
	ai.stop_looking()
	var back := ai.take_input_command(0)
	_check(is_equal_approx(back.look_yaw, 0.7), "stop_looking() goes back to keeping the pawn's look")
	pawn.free()


# --- Helpers ---


func _make_pawn(at := Vector3.ZERO) -> Pawn:
	var pawn: Pawn = load(PAWN_SCENE).instantiate()
	pawn.position = at
	add_child(pawn)
	return pawn


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


func _check(passed: bool, what: String) -> void:
	print("  %s %s" % ["ok  " if passed else "FAIL", what])
	if not passed:
		_failures += 1
