## Written by Claude (claude-opus-5-5), 2026-11-07: headless self-test for StatManager and Stat. Checks the odd cases at the top of
## StatManager.gd.
## Exits 0 on success, 1 on failure. Run from the project folder:
##   "C:\Git\Test 2\Godot_v4.7.2-stable_win64_console.exe" --headless --path . "res://assets/scripts/stats/tests/stat_selftest.tscn"
extends Node

var _failures := 0


func _ready() -> void:
	print("--- Stat self-test ---")
	_test_values_and_fallbacks()
	_test_adding_and_removing()
	_test_the_default_stats()
	print("--- ALL PASSED ---" if _failures == 0 else "--- %d FAILED ---" % _failures)
	get_tree().quit(0 if _failures == 0 else 1)


func _test_values_and_fallbacks() -> void:
	var manager := StatManager.new()
	var speed := Stat.new()
	speed.name = "MoveSpeed"
	speed.base_value = 6.5
	manager.add_child(speed)
	var not_a_stat := Node.new()
	not_a_stat.name = "Helper"
	manager.add_child(not_a_stat)
	add_child(manager)
	_check(manager.get_value(&"MoveSpeed", 1.0) == 6.5, "a stat gives its value")
	_check(speed.value == 6.5, "which starts as its base value")
	_check(manager.get_value(&"NoSuchStat", 1.25) == 1.25, "a stat that isn't there gives the fallback")
	_check(manager.get_stat(&"NoSuchStat") == null and not manager.has_stat(&"NoSuchStat"), "and get_stat gives null")
	_check(not manager.has_stat(&"Helper"), "a child that isn't a Stat is ignored")
	speed.value = 2.0
	_check(manager.get_value(&"MoveSpeed") == 2.0, "the value can change during play")
	var early := Stat.new()
	early.base_value = 3.0
	_check(early.value == 3.0, "setting the base value sets the value, even before it's in the tree")
	early.free()
	manager.free()


func _test_adding_and_removing() -> void:
	var manager := StatManager.new()
	add_child(manager)
	var health := Stat.new()
	health.name = "Health"
	health.base_value = 100.0
	manager.add_child(health)
	_check(manager.get_value(&"Health") == 100.0, "a stat added while running is found")
	var names := manager.get_stat_names()
	_check(names.size() == 1 and names[0] == &"Health", "and listed")
	health.free()
	_check(not manager.has_stat(&"Health") and manager.get_value(&"Health", -1.0) == -1.0, "a removed stat is gone")
	manager.free()


func _test_the_default_stats() -> void:
	var pawn: Pawn = load("res://assets/scenes/pawn/pawn.tscn").instantiate()
	add_child(pawn)
	var stats := pawn.stat_manager
	_check(stats != null, "a pawn gets a StatManager by default")
	var wanted := {&"MoveSpeed": 5.0, &"SprintSpeed": 9.0, &"Acceleration": 30.0, &"Deceleration": 40.0, &"AirControl": 0.3,
			&"TurnRate": 720.0, &"JumpVelocity": 5.0}
	var all_there := true
	for stat_name: StringName in wanted:
		all_there = all_there and is_equal_approx(stats.get_value(stat_name, -1.0), wanted[stat_name])
	_check(all_there, "with the movement stats GroundMovement used to hold, at the same values")
	pawn.free()


func _check(passed: bool, what: String) -> void:
	print("  %s %s" % ["ok  " if passed else "FAIL", what])
	if not passed:
		_failures += 1
