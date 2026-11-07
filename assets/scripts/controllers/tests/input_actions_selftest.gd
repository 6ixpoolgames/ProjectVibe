## Written by Claude (claude-opus-5-5), 2026-11-07: headless self-test for InputActions, InputCommand, ControllerBase, and how
## PlayerController turns keys into named actions. Checks the odd cases listed at the top of InputActions.gd.
## Exits 0 on success, 1 on failure. Run from the project folder:
##   "C:\Git\Test 2\Godot_v4.7.2-stable_win64_console.exe" --headless --path . "res://assets/scripts/controllers/tests/input_actions_selftest.tscn"
extends Node

var _failures := 0


## A controller with scripted keys, as a test needs. GDScript note: an inner class is a class declared inside this file.
class ScriptedController extends PlayerController:
	var held := {} # action -> true
	var pressed := {} # action -> true, used up when read

	func _read_move() -> Vector2:
		return Vector2.ZERO

	func _read_action_held(action: StringName) -> bool:
		return held.has(action)

	func _read_action_pressed(action: StringName) -> bool:
		return pressed.erase(action) # GDScript note: erase returns true if the key was there


func _ready() -> void:
	print("--- Input actions self-test ---")
	_test_the_list_file()
	_test_bits()
	_test_late_and_blank()
	_test_limit()
	_test_commands()
	_test_controller_base()
	await _test_player_controller_actions()
	InputActions.reset() # leave it as the game would find it
	print("--- ALL PASSED ---" if _failures == 0 else "--- %d FAILED ---" % _failures)
	get_tree().quit(0 if _failures == 0 else 1)


func _test_the_list_file() -> void:
	InputActions.reset()
	var res: InputActionsRes = load(InputActions.LIST_PATH)
	_check(res != null and InputActions.get_actions() == res.actions, "the list file is read, in its own order")
	_check(InputActions.get_actions().has(&"jump") and InputActions.get_actions().has(&"sprint"), "and has jump and sprint")


func _test_bits() -> void:
	InputActions.use_list([&"jump", &"sprint", &"primary"])
	_check(InputActions.mask_of(&"jump") == 1 and InputActions.mask_of(&"sprint") == 2 and InputActions.mask_of(&"primary") == 4,
			"each action gets the bit of its place in the list")
	_check(InputActions.mask_of_list([&"jump", &"primary"]) == 5, "a list gives all its bits")
	_check(InputActions.all_listed_mask() == 7, "and every listed action together")
	var names := InputActions.names_in(6)
	_check(names.size() == 2 and names[0] == &"sprint" and names[1] == &"primary", "a mask reads back as names")
	_check(InputActions.mask_of(&" jump ") == 1, "spaces around a name are ignored")
	# Two machines reading the same list give the same bits.
	var first := InputActions.mask_of(&"primary")
	InputActions.use_list([&"jump", &"sprint", &"primary"])
	_check(InputActions.mask_of(&"primary") == first, "the same list always gives the same bits")


func _test_late_and_blank() -> void:
	InputActions.use_list([&"jump"])
	_check(InputActions.mask_of(&"") == 0 and InputActions.mask_of(&"   ") == 0, "a blank name has no bit")
	print("  (a warning about 'dodge' is expected next)")
	_check(InputActions.mask_of(&"dodge") == 2, "an unlisted action is added at the end, with a warning")
	_check(InputActions.mask_of(&"dodge") == 2, "and keeps its bit")
	_check(InputActions.all_listed_mask() == 3, "and counts as listed from then on")


func _test_limit() -> void:
	var many: Array[StringName] = []
	for i in InputActions.MAX_ACTIONS:
		many.append(StringName("action_%d" % i))
	InputActions.use_list(many)
	_check(InputActions.mask_of(&"action_63") == 1 << 63, "the 64th action gets the last bit")
	_check(InputActions.all_listed_mask() == -1, "and with 64, every bit is listed")
	print("  (a warning about more than 64 actions is expected next)")
	_check(InputActions.mask_of(&"one_too_many") == 0, "a 65th action gets no bit")
	InputActions.reset()


func _test_commands() -> void:
	InputActions.use_list([&"jump", &"sprint"])
	var command := InputCommand.make(Vector3(1, 0, 0), [&"sprint"], 0.5, -0.2)
	_check(command.move == Vector3(1, 0, 0) and command.look_yaw == 0.5 and command.look_pitch == -0.2, "make() fills in every field")
	_check(command.is_held(&"sprint") and not command.is_held(&"jump"), "and only the actions it was given are held")
	command.set_held(&"jump")
	command.set_held(&"sprint", false)
	_check(command.held_actions == InputActions.mask_of(&"jump"), "set_held() turns actions on and off")
	var idle := InputCommand.new()
	_check(idle.move == Vector3.ZERO and idle.held_actions == 0, "a new command is idle")
	InputActions.reset()


func _test_controller_base() -> void:
	var controller := ControllerBase.new()
	var command := controller.take_input_command(0)
	_check(command != null and command.move == Vector3.ZERO and command.held_actions == 0, "the base controller gives an idle command")
	_check(controller.pawn == null, "and starts with no pawn")
	controller.free()
	var player := PlayerController.new()
	_check(player is ControllerBase, "PlayerController is a ControllerBase")
	_check(player.action_keys.get(&"jump") == &"move_jump" and player.action_keys.get(&"sprint") == &"move_sprint",
			"and maps jump and sprint to the project's keys by default")
	player.free()


func _test_player_controller_actions() -> void:
	InputActions.reset()
	var controller := ScriptedController.new()
	add_child(controller)
	var pawn: Pawn = load("res://assets/scenes/pawn/pawn.tscn").instantiate()
	await get_tree().process_frame
	# Set straight on the field, not with take_pawn(), which would make the tick driver read the controller every tick and use up the
	# presses before this test reads them. The controller only needs to know it has a pawn.
	controller.pawn = pawn
	# A tap: pressed and let go within one frame, before any tick reads it.
	controller.pressed[&"jump"] = true
	await get_tree().process_frame
	var tapped := controller.take_input_command(0)
	_check(tapped.is_held(&"jump"), "a tap shorter than a tick still reaches the next tick")
	_check(not controller.take_input_command(1).is_held(&"jump"), "and only that one")
	controller.held[&"sprint"] = true
	_check(controller.take_input_command(2).is_held(&"sprint"), "a held key is held in every command")
	controller.held.clear()
	# An action with no key in action_keys is never pressed by the player.
	controller.action_keys.erase(&"sprint")
	controller.held[&"sprint"] = true
	_check(not controller.take_input_command(3).is_held(&"sprint"), "an action with no key is never held")
	controller.pawn = null
	controller.free()
	pawn.free()
	await get_tree().process_frame


func _check(passed: bool, what: String) -> void:
	print("  %s %s" % ["ok  " if passed else "FAIL", what])
	if not passed:
		_failures += 1
