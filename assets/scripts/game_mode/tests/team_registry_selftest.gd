## Written by Claude (claude-opus-5-5), 2026-11-16 (pawn M1): headless self-test for TeamRegistry: it counts the pawns on each team as
## they arrive, leave and change team, and AI sensing asks it whether anyone is on another team.
## Exits 0 on success, 1 on failure. Run from the project folder:
##   godot --headless --path . "res://assets/scripts/game_mode/tests/team_registry_selftest.tscn"
extends SelfTest # Claude 2026-11-16 (wider audit): _check and _failures come from tests/SelfTest.gd now

const PAWN_SCENE := "res://assets/scenes/pawn/pawn.tscn"
const NO_AI: Array[StringName] = [&"AISensingManager", &"AIMemory", &"AITargetSelector", &"AIStateManager", &"AIBehaviourManager"]


func _ready() -> void:
	print("--- Team registry self-test ---")
	var registry: TeamRegistry = GameMode.team_registry
	_check(registry != null, "GameMode has a team registry by default")
	if registry == null:
		_finish()
		return
	var before := registry.get_counts()
	var red := _pawn(1)
	var blue := _pawn(2)
	var also_red := _pawn(1)
	await get_tree().process_frame
	_check(registry.count_on_team(1) == before.get(1, 0) + 2 and registry.count_on_team(2) == before.get(2, 0) + 1, "it counts pawns as they arrive")
	_check(registry.count_not_on_team(1) == registry.count_on_team(2) + registry.count_on_team(0), "and those on other teams")
	blue.team = 1
	_check(registry.count_on_team(2) == before.get(2, 0) and registry.count_on_team(1) == before.get(1, 0) + 3, "a pawn changing team moves between the counts")
	also_red.free()
	_check(registry.count_on_team(1) == before.get(1, 0) + 2, "a pawn that leaves is no longer counted")
	var outside: Pawn = load(PAWN_SCENE).instantiate()
	outside.team = 5
	_check(registry.count_on_team(5) == 0, "a pawn not in the tree isn't counted, even when its team is set")
	outside.free()
	red.free()
	blue.free()
	_check(registry.get_counts() == before, "with them all gone, the counts are as they were")
	_finish()


func _pawn(team: int) -> Pawn:
	var pawn: Pawn = load(PAWN_SCENE).instantiate()
	pawn.skip_default_parts = NO_AI
	pawn.team = team
	add_child(pawn)
	return pawn


func _finish() -> void:
	print("--- ALL PASSED ---" if _failures == 0 else "--- %d FAILED ---" % _failures)
	get_tree().quit(0 if _failures == 0 else 1)
