## Written by Claude (claude-opus-5-5), 2026-11-07: headless self-test for PawnInitializer. Checks the odd cases at the top of
## PawnInitializer.gd, and every way out: per pawn, per part, and for the whole game.
## Exits 0 on success, 1 on failure. Run from the project folder:
##   "C:\Git\Test 2\Godot_v4.7.2-stable_win64_console.exe" --headless --path . "res://assets/scripts/game_mode/tests/pawn_initializer_selftest.tscn"
extends Node

const PAWN_SCENE := "res://assets/scenes/pawn/pawn.tscn"
const MOVEMENT_PART := "res://assets/scenes/pawn/parts/GroundMovement.tscn"

var _failures := 0


func _ready() -> void:
	print("--- Pawn initializer self-test ---")
	_test_the_module_and_its_file()
	_test_default_parts()
	_test_a_designer_override()
	_test_ways_out()
	_test_entering_again()
	_test_odd_defaults()
	await _test_without_the_module()
	print("--- ALL PASSED ---" if _failures == 0 else "--- %d FAILED ---" % _failures)
	get_tree().quit(0 if _failures == 0 else 1)


func _test_the_module_and_its_file() -> void:
	var initializer: PawnInitializer = GameMode.pawn_initializer
	_check(initializer != null, "GameMode starts a PawnInitializer by default")
	_check(initializer.defaults != null and initializer.defaults.resource_path == PawnInitializer.DEFAULT_DEFAULTS_PATH, "it reads the game's defaults file")
	var names: Array[StringName] = []
	for scene in initializer.defaults.parts:
		names.append(PawnInitializer.part_name_of(scene))
	_check(names.size() == 2 and names[0] == &"ControllerManager" and names[1] == &"GroundMovement",
			"which lists today's parts, by their scenes' root names (%s)" % str(names))


func _test_default_parts() -> void:
	var pawn: Pawn = load(PAWN_SCENE).instantiate()
	_check(not pawn.has_node(^"GroundMovement") and not pawn.has_node(^"ControllerManager"), "pawn.tscn itself no longer holds the default parts")
	add_child(pawn)
	_check(pawn.get_node_or_null(^"ControllerManager") is ControllerManager, "entering the tree, the pawn gets a ControllerManager")
	_check(pawn.get_node_or_null(^"ControllerManager/AIController") is AIController, "with its AIController")
	_check(pawn.get_node_or_null(^"GroundMovement") is GroundMovement and pawn.movement is GroundMovement, "and GroundMovement, which the pawn uses")
	_check(pawn.controller_manager == pawn.get_node(^"ControllerManager"), "and the pawn knows its ControllerManager")
	var manager_index := pawn.get_node(^"ControllerManager").get_index()
	_check(pawn.get_node(^"GroundMovement").get_index() == manager_index + 1, "in the list's order, after the scene's own children")
	_check(pawn.get_node_or_null(^"TickState") != null and pawn.get_node_or_null(^"NetworkEntity") != null, "TickState and NetworkEntity stay in the scene")
	pawn.free()


func _test_a_designer_override() -> void:
	var pawn: Pawn = load(PAWN_SCENE).instantiate()
	var own := GroundMovement.new()
	own.name = "GroundMovement"
	own.max_speed = 9.0
	pawn.add_child(own)
	add_child(pawn)
	var all_movement := pawn.get_children().filter(func(child): return child is GroundMovement)
	_check(all_movement.size() == 1 and all_movement[0] == own and pawn.movement == own, "a part with the same name in the pawn is kept, and no default is added")
	_check(pawn.has_node(^"ControllerManager"), "the other defaults still are")
	pawn.free()


func _test_ways_out() -> void:
	var skipping: Pawn = load(PAWN_SCENE).instantiate()
	skipping.skip_default_parts = [&"GroundMovement"]
	add_child(skipping)
	_check(not skipping.has_node(^"GroundMovement") and skipping.has_node(^"ControllerManager"), "skip_default_parts leaves out just those parts")
	skipping.free()
	var bare: Pawn = load(PAWN_SCENE).instantiate()
	bare.fill_in_default_parts = false
	add_child(bare)
	_check(not bare.has_node(^"GroundMovement") and not bare.has_node(^"ControllerManager") and bare.controller_manager == null, "fill_in_default_parts off: no defaults at all")
	bare.free()


func _test_entering_again() -> void:
	var pawn: Pawn = load(PAWN_SCENE).instantiate()
	add_child(pawn)
	var count := pawn.get_child_count()
	remove_child(pawn)
	add_child(pawn)
	_check(pawn.get_child_count() == count, "entering the tree again adds nothing twice")
	pawn.free()


func _test_odd_defaults() -> void:
	var initializer := PawnInitializer.new()
	var pawn: Pawn = load(PAWN_SCENE).instantiate()
	pawn.fill_in_default_parts = false # so the game's own initializer leaves it alone; this one is called by hand
	add_child(pawn)
	var before := pawn.get_child_count()
	pawn.fill_in_default_parts = true
	initializer.initialize(pawn)
	_check(pawn.get_child_count() == before, "no defaults loaded: nothing is added")
	initializer.defaults = PawnDefaultsRes.new()
	var parts: Array[PackedScene] = [null, load(MOVEMENT_PART)]
	initializer.defaults.parts = parts
	initializer.initialize(pawn)
	_check(pawn.get_child_count() == before + 1 and pawn.has_node(^"GroundMovement"), "an empty slot in the list is skipped")
	initializer.initialize(null) # nothing to do, and nothing breaks
	# The wrong kind of file, or none, through the project setting.
	var had_setting := ProjectSettings.has_setting(PawnInitializer.DEFAULTS_SETTING)
	ProjectSettings.set_setting(PawnInitializer.DEFAULTS_SETTING, "res://no_such_defaults.tres")
	print("  (a warning about missing pawn defaults is expected next)")
	_check(initializer._load_defaults() == null, "no defaults file: a warning, and no defaults")
	ProjectSettings.set_setting(PawnInitializer.DEFAULTS_SETTING, PAWN_SCENE)
	print("  (and another, for a file that isn't a PawnDefaultsRes)")
	_check(initializer._load_defaults() == null, "a file that isn't a PawnDefaultsRes: the same")
	if not had_setting:
		ProjectSettings.set_setting(PawnInitializer.DEFAULTS_SETTING, null) # GDScript note: setting null removes it
	initializer.free()
	pawn.free()


## The whole game without the module: pawns get only what their scenes have.
func _test_without_the_module() -> void:
	var initializer: PawnInitializer = GameMode.pawn_initializer
	GameMode.remove_module(initializer)
	_check(GameMode.pawn_initializer == null, "removing the module clears GameMode.pawn_initializer")
	var pawn: Pawn = load(PAWN_SCENE).instantiate()
	add_child(pawn)
	_check(not pawn.has_node(^"GroundMovement") and pawn.controller_manager == null, "without it, a pawn gets only its scene's parts")
	await get_tree().physics_frame # and ticks without breaking
	pawn.free()
	GameMode.add_module(PawnInitializer.new())
	_check(GameMode.pawn_initializer != null and GameMode.pawn_initializer.defaults != null, "adding it back reads the defaults again")


func _check(passed: bool, what: String) -> void:
	print("  %s %s" % ["ok  " if passed else "FAIL", what])
	if not passed:
		_failures += 1
