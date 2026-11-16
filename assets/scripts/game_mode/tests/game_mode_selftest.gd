## Written by Claude (claude-opus-5-5), 2026-11-07: headless self-test for the GameMode shell and AIActivationManager.
## Exits 0 on success, 1 on failure. Run from the project folder:
##   "C:\Git\Test 2\Godot_v4.7.2-stable_win64_console.exe" --headless --path . "res://assets/scripts/game_mode/tests/game_mode_selftest.tscn"
extends SelfTest # Claude 2026-11-16 (wider audit): _check and _failures come from tests/SelfTest.gd now


## A pawn that only records what it's told.
class StubPawn extends Node3D:
	var active := true
	var changes := 0

	func set_frozen(frozen: bool) -> void: # Claude 2026-11-16 (pawn M1): renamed from set_simulation_active
		active = not frozen
		changes += 1


class StubModule extends GameModeModule:
	var added := false
	var removed := false

	func _on_module_added(_game_mode: GameModeSingleton) -> void:
		added = true

	func _on_module_removed(_game_mode: GameModeSingleton) -> void:
		removed = true


# Claude 2026-11-16: a game's own module with match options: a number with a range and a choice.
class OptionsModule extends GameModeModule:
	@export_range(0, 10, 1) var waves := 3
	@export_enum("Easy:0", "Hard:5") var difficulty := 0

	func get_match_options() -> PackedStringArray:
		return PackedStringArray(["waves", "difficulty"])


class FakeClientSession extends Node:
	func is_client() -> bool:
		return true


func _ready() -> void:
	print("--- GameMode self-test ---")
	_test_defaults()
	_test_adding_and_removing()
	_test_bad_settings()
	_test_empty_settings()
	await _test_no_terrain()
	await _test_rule()
	await _test_on_a_client()
	await _test_freed_pawns()
	_test_module_removed()
	_test_match_options() # Claude 2026-11-16
	await _measure_a_horde()
	print("--- ALL PASSED ---" if _failures == 0 else "--- %d FAILED ---" % _failures)
	get_tree().quit(0 if _failures == 0 else 1)


func _test_defaults() -> void:
	_check(GameMode is GameModeSingleton, "GameMode is an autoload")
	_check(GameMode.ai_activation_manager != null, "AIActivationManager starts by default")
	_check(GameMode.get_module(AIActivationManager) == GameMode.ai_activation_manager, "and can be found by its script")
	_check(not GameMode.is_processing() and not GameMode.is_physics_processing(), "the shell itself does no per-frame work")


func _test_adding_and_removing() -> void:
	var module := StubModule.new()
	var added_signal := [false]
	var on_added := func(_m: GameModeModule) -> void: added_signal[0] = true
	GameMode.module_added.connect(on_added)
	GameMode.add_module(module)
	GameMode.module_added.disconnect(on_added)
	_check(module.added and added_signal[0], "a game's own module can be added, and is told")
	_check(GameMode.get_module(module.get_script()) == module, "and found")
	var second := StubModule.new()
	GameMode.add_module(second) # warns and frees the second
	_check(not is_instance_valid(second), "a second of the same type isn't added")
	_check(GameMode.get_modules().count(module) == 1, "and the first stays")
	var kept := module
	var removed_flag := [false]
	var on_removed := func(m: GameModeModule) -> void: removed_flag[0] = (m == kept) and kept.removed
	GameMode.module_removed.connect(on_removed)
	GameMode.remove_module(module)
	GameMode.module_removed.disconnect(on_removed)
	_check(removed_flag[0], "removing it tells it first")
	_check(GameMode.get_module(StubModule) == null, "and it's gone")
	GameMode.remove_module(null)
	_check(true, "removing nothing does nothing")


# Claude 2026-11-16 (the owner's request: match options in the start menu, proving out the GameMode's modularity): the panel lists the
# options of whichever modules the game has, a row sets its setting, and a module taken out takes its options with it.
func _test_match_options() -> void:
	var module := OptionsModule.new()
	GameMode.add_module(module)
	var panel := MatchOptionsPanel.new()
	add_child(panel)
	panel.add_from_game_mode()
	var rows := {}
	for row: Array in panel._rows:
		rows[[row[0], row[1]]] = row[2]
	var activation: AIActivationManager = GameMode.ai_activation_manager
	_check(rows.has([activation, "steps_by_distance"]) and rows[[activation, "steps_by_distance"]] is CheckBox, "the panel has the AIActivationManager's options, a bool as a check box")
	var waves: Variant = rows.get([module, "waves"])
	_check(waves is SpinBox and is_equal_approx((waves as SpinBox).max_value, 10.0) and is_equal_approx((waves as SpinBox).value, 3.0), "and a game's own module's: a number with its range and value")
	(waves as SpinBox).value = 7
	_check(module.waves == 7, "changing a row sets the setting")
	var difficulty: Variant = rows.get([module, "difficulty"])
	_check(difficulty is OptionButton and (difficulty as OptionButton).item_count == 2, "an enum is a drop-down of its names")
	(difficulty as OptionButton).select(1)
	(difficulty as OptionButton).item_selected.emit(1)
	_check(module.difficulty == 5, "and picking one sets its value")
	activation.steps_by_distance = false
	panel.refresh()
	_check(not (rows[[activation, "steps_by_distance"]] as CheckBox).button_pressed, "refresh() reads changed values back")
	activation.steps_by_distance = true
	panel.free()
	GameMode.remove_module(module)
	var without := MatchOptionsPanel.new()
	add_child(without)
	without.add_from_game_mode()
	_check(without._rows.all(func(row: Array) -> bool: return not (row[0] is OptionsModule)), "with the module taken out, its options are gone, and nothing names it")
	without.free()
	# Claude 2026-11-16: autoloads name their own too (the tick driver's load ladder, the network session's snapshots).
	var autoloads := MatchOptionsPanel.new()
	add_child(autoloads)
	autoloads.add_from_autoloads()
	var found := autoloads._rows.map(func(row: Array) -> String: return String(row[1]))
	_check(found.has("load_ladder_enabled") and found.has("delta_snapshots_enabled") and autoloads._rows.all(func(row: Array) -> bool: return not (row[0] is GameModeSingleton)),
		"autoloads that name options get sections too, and GameMode itself doesn't (%s)" % ", ".join(found))
	autoloads.free()


func _test_bad_settings() -> void:
	# Claude 2026-11-08: the "not a module" example was GlobalTools.gd, which moved to assets/legacy/. InputCommand is a
	# plain tier 0 data script, so the test no longer leans on legacy code.
	ProjectSettings.set_setting(GameModeSingleton.MODULES_SETTING, ["res://no/such/script.gd", "res://assets/scripts/controllers/InputCommand.gd"])
	var other := GameModeSingleton.new()
	add_child(other)
	_check(other.get_modules().is_empty(), "paths that don't load, or aren't modules, are skipped with a warning")
	ProjectSettings.set_setting(GameModeSingleton.MODULES_SETTING, null)
	other.free()


func _test_empty_settings() -> void:
	ProjectSettings.set_setting(GameModeSingleton.MODULES_SETTING, [])
	var other := GameModeSingleton.new()
	add_child(other)
	_check(other.get_modules().is_empty() and other.ai_activation_manager == null, "an empty list starts no modules, and nothing breaks")
	ProjectSettings.set_setting(GameModeSingleton.MODULES_SETTING, null)
	other.free()


func _test_no_terrain() -> void:
	var pawn := _make_pawn(Vector3.ZERO)
	await _physics_frames(10)
	_check(pawn.active and GameMode.ai_activation_manager.is_active(pawn), "with no terrain in the scene, AI stays on")
	GameMode.ai_activation_manager.remove_pawn(pawn)
	pawn.free()


func _test_rule() -> void:
	var terrain := _make_terrain()
	var pawn := _make_pawn(Vector3(16.0, 5.0, 16.0))
	_check(not pawn.active, "added where no chunk is built, it's off straight away, before any tick")
	terrain.load_chunk(Vector2i.ZERO)
	var activated := [0]
	var deactivated := [0]
	var on_activated := func(_p: Node3D) -> void: activated[0] += 1
	var on_deactivated := func(_p: Node3D) -> void: deactivated[0] += 1
	GameMode.ai_activation_manager.ai_activated.connect(on_activated)
	GameMode.ai_activation_manager.ai_deactivated.connect(on_deactivated)
	await _physics_frames(10)
	_check(pawn.active, "when its chunk is built, it comes back on")
	_check(activated[0] == 1 and deactivated[0] == 0, "and says so once")
	terrain.unload_chunk(Vector2i.ZERO)
	await _physics_frames(10)
	_check(not pawn.active, "when its chunk goes, it goes off")
	_check(deactivated[0] == 1, "and says so once")

	# Near a chunk's edge, the next chunk counts too, so it goes off before stepping over nothing.
	terrain.load_chunk(Vector2i.ZERO)
	pawn.position = Vector3(31.0, 5.0, 16.0)
	await _physics_frames(10)
	_check(not pawn.active, "within edge_margin of an unbuilt chunk, it stays off")
	terrain.load_chunk(Vector2i(1, 0))
	await _physics_frames(10)
	_check(pawn.active, "and comes on once that chunk is there too")
	GameMode.ai_activation_manager.ai_activated.disconnect(on_activated)
	GameMode.ai_activation_manager.ai_deactivated.disconnect(on_deactivated)
	GameMode.ai_activation_manager.remove_pawn(pawn)
	pawn.free()
	terrain.free()


func _test_on_a_client() -> void:
	var terrain := _make_terrain()
	var real_session: Node = GameMode.ai_activation_manager._session
	var fake := FakeClientSession.new()
	GameMode.ai_activation_manager._session = fake
	var pawn := _make_pawn(Vector3(16.0, 5.0, 16.0))
	await _physics_frames(10)
	_check(pawn.active, "on a client it does nothing, because AI only runs on the server")
	GameMode.ai_activation_manager._session = real_session
	GameMode.ai_activation_manager.remove_pawn(pawn)
	pawn.free()
	fake.free()
	terrain.free()


func _test_freed_pawns() -> void:
	var terrain := _make_terrain()
	var before := GameMode.ai_activation_manager.get_watched_count()
	var pawn := _make_pawn(Vector3(16.0, 5.0, 16.0))
	pawn.free()
	await _physics_frames(10)
	_check(GameMode.ai_activation_manager.get_watched_count() == before, "a freed pawn is dropped from the list")
	_check(GameMode.ai_activation_manager.get_inactive_count() == 0, "including from the ones that are off")
	terrain.free()


func _test_module_removed() -> void:
	var terrain := _make_terrain()
	var pawn := _make_pawn(Vector3(16.0, 5.0, 16.0))
	_check(not pawn.active, "(off, with no ground)")
	GameMode.remove_module(GameMode.ai_activation_manager)
	_check(pawn.active, "removing the module puts every pawn back on")
	_check(GameMode.ai_activation_manager == null, "and its line on GameMode is cleared")
	GameMode.add_module(AIActivationManager.new())
	_check(GameMode.ai_activation_manager != null, "and it can be added back")
	pawn.free()
	terrain.free()


## Not a pass or fail, just numbers.
func _measure_a_horde() -> void:
	var terrain := _make_terrain()
	terrain.load_chunk(Vector2i.ZERO)
	var pawns: Array[StubPawn] = []
	var started := Time.get_ticks_usec()
	for i in 10000:
		var pawn := StubPawn.new()
		pawn.position = Vector3(5.0 + (i % 20), 0.0, 5.0 + (i % 20))
		add_child(pawn)
		pawns.append(pawn)
		GameMode.ai_activation_manager._pawns.append(pawn) # skips the duplicate check, which is a slow way to add 10,000
	print("        making 10,000 stub pawns: %d ms" % ((Time.get_ticks_usec() - started) / 1000))
	var worst := 0
	var total := 0
	for i in 12:
		started = Time.get_ticks_usec()
		GameMode.ai_activation_manager._physics_process(1.0 / 60.0)
		var spent := Time.get_ticks_usec() - started
		total += spent
		worst = maxi(worst, spent)
	print("        checking 10,000 pawns, a sixth per frame: %.2f ms a frame on average, %.2f ms at worst" % [total / 12000.0, worst / 1000.0])
	GameMode.ai_activation_manager._pawns.clear()
	GameMode.ai_activation_manager._inactive.clear()
	for pawn in pawns:
		pawn.free()
	terrain.free()
	await get_tree().process_frame


# --- Helpers ---


func _make_terrain() -> TerrainGenerator:
	var terrain := TerrainGenerator.new()
	terrain.name = "Terrain"
	terrain.build_on_start = false
	terrain.chunk_size = 32.0
	terrain.chunk_resolution = 4
	terrain.build_collision = false
	add_child(terrain)
	return terrain


func _make_pawn(at: Vector3) -> StubPawn:
	var pawn := StubPawn.new()
	pawn.position = at
	add_child(pawn)
	GameMode.ai_activation_manager.add_pawn(pawn)
	return pawn


func _physics_frames(count: int) -> void:
	for i in count:
		await get_tree().physics_frame
