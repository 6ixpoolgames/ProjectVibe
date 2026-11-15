## Written by Claude (claude-opus-5-5), 2026-11-12: headless self-test for KillFloor: a pawn that falls below it dies, one above it
## doesn't, a dead one isn't hit again, and a revived one back on the ground stays alive. Players coming back after dying is
## SpawnManager's, checked in game_mode/tests/spawn_manager_selftest.
## Exits 0 on success, 1 on failure. Run from the project folder:
##   "C:\Git\Test 2\Godot_v4.7.2-stable_win64_console.exe" --headless --path . "res://assets/scripts/world/tests/kill_floor_selftest.tscn"
extends Node

const PAWN_SCENE := "res://assets/scenes/pawn/pawn.tscn"
const NO_AI: Array[StringName] = [&"AISensingManager", &"AIMemory", &"AITargetSelector", &"AIStateManager", &"AIBehaviourManager"]

var _failures := 0


func _ready() -> void:
	print("--- Kill floor self-test ---")
	TickDriver.tick_rate = TickDriver.REFERENCE_RATE
	# A floor under one spot only: a pawn placed off it falls.
	var floor_body := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(10, 1, 10)
	shape.shape = box
	shape.position.y = -0.5
	floor_body.add_child(shape)
	add_child(floor_body)
	var kill_floor := KillFloor.new()
	kill_floor.position.y = -20.0
	add_child(kill_floor)
	var standing := _pawn(Vector3(0, 0.1, 0))
	var falling := _pawn(Vector3(40, 0.1, 0))
	var deaths := []
	falling.ability_manager.died.connect(func(_who: Pawn, hit: HitInfo) -> void: deaths.append(hit)) # Claude 2026-11-15: _who, as _pawn shadowed the _pawn() helper (an editor warning)
	await _ticks(5)
	_check(kill_floor.kill_effect != null and kill_floor.kill_effect.effect_name == &"kill self", "by default it uses the kill_self effect")
	for i in 240:
		await get_tree().physics_frame
		if falling.is_dead():
			break
	_check(falling.is_dead() and falling.global_position.y < -20.0 and falling.global_position.y > -40.0, "a pawn that falls below it dies soon after (at %.1f m)" % falling.global_position.y)
	_check(not standing.is_dead() and standing.get_health() == 100.0, "one standing on the ground above it is left alone")
	await _ticks(60)
	_check(deaths.size() == 1, "a dead pawn below it isn't hit again (%d deaths)" % deaths.size())
	falling.ability_manager.revive()
	falling.global_position = Vector3(0, 0.1, 0)
	await _ticks(30)
	_check(not falling.is_dead(), "revived and back on the ground, it stays alive")
	_test_reports(kill_floor, standing)
	standing.free()
	falling.free()
	kill_floor.free()
	print("--- ALL PASSED ---" if _failures == 0 else "--- %d FAILED ---" % _failures)
	get_tree().quit(0 if _failures == 0 else 1)


# Claude 2026-11-12: the report of a fall (report_falls): where the pawn last stood, and whether it went through ground or off the
# edge of it. Read with fall_report, since a warning can't be caught here.
func _test_reports(kill_floor: KillFloor, standing: Pawn) -> void:
	var last_seen: Variant = kill_floor._last_on_ground.get(standing.get_instance_id())
	_check(last_seen != null and (last_seen[0] as Vector3).is_equal_approx(standing.global_position), "it remembers where a pawn last stood")
	var no_terrain := kill_floor.fall_report(standing, last_seen, int(last_seen[2]) + 120)
	_check(no_terrain.contains("last standing 2.0 s before") and not no_terrain.contains("ground where"), "a report says where and when it last stood (%s)" % no_terrain)
	_check(kill_floor.fall_report(standing, null, 0).contains("wasn't seen standing"), "or that it never stood anywhere")
	# A small terrain, with only the chunks at the world's middle built (no collision, so nothing here stands on it).
	var terrain := TerrainGenerator.new()
	terrain.build_on_start = false
	terrain.chunk_size = 32.0
	terrain.chunk_resolution = 4
	terrain.build_collision = false
	add_child(terrain)
	# Claude 2026-11-16: the four chunks around the world's middle, not just one: the standing pawn is at (0, 0), the corner of four, and a
	# hair's push from the revived pawn placed on the same spot can move it into a neighbour (a check that failed on float noise).
	for key: Vector2i in [Vector2i(0, 0), Vector2i(-1, 0), Vector2i(0, -1), Vector2i(-1, -1)]:
		terrain.load_chunk(key)
	var through := kill_floor.fall_report(standing, last_seen, 0)
	var old_spot := standing.global_position
	standing.global_position = Vector3(500, -30, 500)
	var off_edge := kill_floor.fall_report(standing, last_seen, 0)
	standing.global_position = old_spot
	_check(through.contains("went through solid ground"), "over built ground, it says the pawn went through it (%s)" % through) # Claude 2026-11-16: with the report, for diagnosing
	_check(off_edge.contains("off the edge of the loaded world"), "over none, that it went off the edge")
	terrain.free()


func _pawn(at: Vector3) -> Pawn:
	var pawn: Pawn = load(PAWN_SCENE).instantiate()
	pawn.skip_default_parts = NO_AI
	pawn.position = at
	add_child(pawn)
	return pawn


func _ticks(count: int) -> void:
	for i in count:
		await get_tree().physics_frame


func _check(passed: bool, what: String) -> void:
	print("  %s %s" % ["ok  " if passed else "FAIL", what])
	if not passed:
		_failures += 1
