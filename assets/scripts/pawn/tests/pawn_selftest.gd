## Written by Claude (claude-opus-5-5), 2026-11-07: headless self-test for the tier -1 Pawn and GroundMovement, offline.
## Exits 0 on success, 1 on failure. Run from the project folder:
##   "C:\Git\Test 2\Godot_v4.7.2-stable_win64_console.exe" --headless --path . "res://assets/scripts/pawn/tests/pawn_selftest.tscn"
extends Node

const PAWN_SCENE := "res://assets/scenes/pawn/pawn.tscn"

var _failures := 0


func _ready() -> void:
	print("--- Pawn self-test ---")
	await _test_on_flat_ground()
	await _test_running_and_stopping()
	await _test_jumping()
	await _test_on_slopes()
	await _test_rollback_is_exact()
	await _test_no_movement_module()
	_test_bad_input()
	await _test_swapping_movement()
	await _test_source_rules()
	await _test_ai_with_no_ground()
	await _test_no_arms_by_default()
	await _test_visual_smoothing()
	await _measure_a_crowd()
	print("--- ALL PASSED ---" if _failures == 0 else "--- %d FAILED ---" % _failures)
	get_tree().quit(0 if _failures == 0 else 1)


func _test_on_flat_ground() -> void:
	var floor_body := _make_floor()
	var pawn := _make_pawn(Vector3(0.0, 0.2, 0.0))
	await _ticks(30)
	_check(pawn.grounded, "a pawn falls and lands")
	_check(absf(pawn.position.y) < 0.02, "on the floor (%.3f m)" % pawn.position.y)
	_check(is_zero_approx(pawn.velocity.y), "and stops falling")
	_check(pawn.rotation == Vector3.ZERO, "and its body never rotates")
	pawn.free()
	floor_body.free()


func _test_running_and_stopping() -> void:
	var floor_body := _make_floor()
	var pawn := _make_pawn(Vector3(0.0, 0.1, 0.0))
	var movement: GroundMovement = pawn.movement
	await _ticks(20)
	pawn.apply_player_input(Vector3(1.0, 0.0, 0.0), 0.0, 0.0, false, false)
	await _ticks(1)
	_check(pawn.velocity.x > 0.0 and pawn.velocity.x < movement.max_speed, "it accelerates, not instantly (%.2f m/s after a tick)" % pawn.velocity.x)
	await _ticks(30)
	_check(is_equal_approx(pawn.velocity.x, movement.max_speed), "and reaches its speed (%.2f m/s)" % pawn.velocity.x)
	_check(absf(angle_difference(pawn.yaw, atan2(-1.0, 0.0))) < 0.01, "and turns to face where it's going")
	var before := pawn.position.x
	await _ticks(60)
	_check(absf(pawn.position.x - before - movement.max_speed) < 0.05, "one second moves it its speed in metres (%.2f m)" % (pawn.position.x - before))
	pawn.apply_player_input(Vector3(1.0, 0.0, 0.0), 0.0, 0.0, true, false)
	await _ticks(60)
	_check(is_equal_approx(pawn.velocity.x, movement.max_speed * movement.sprint_multiplier), "sprinting is faster (%.2f m/s)" % pawn.velocity.x)
	pawn.apply_player_input(Vector3.ZERO, 0.0, 0.0, false, false)
	await _ticks(60)
	_check(is_zero_approx(pawn.velocity.x), "and with no input, it stops")
	pawn.apply_player_input(Vector3(100.0, 0.0, 0.0), 0.0, 0.0, false, false)
	await _ticks(60)
	_check(is_equal_approx(pawn.velocity.x, movement.max_speed), "input longer than 1 doesn't go faster")
	pawn.free()
	floor_body.free()


func _test_jumping() -> void:
	var floor_body := _make_floor()
	var pawn := _make_pawn(Vector3(0.0, 0.1, 0.0))
	await _ticks(20)
	pawn.apply_player_input(Vector3.ZERO, 0.0, 0.0, false, true)
	await _ticks(1)
	pawn.apply_player_input(Vector3.ZERO, 0.0, 0.0, false, false)
	_check(not pawn.grounded and pawn.velocity.y > 0.0, "a jump leaves the ground")
	var highest := 0.0
	for i in 120:
		await _ticks(1)
		highest = maxf(highest, pawn.position.y)
	_check(highest > 0.5, "and rises (%.2f m)" % highest)
	_check(pawn.grounded and absf(pawn.position.y) < 0.02, "and lands again")
	# Held in the air: nothing happens until it's on the ground.
	pawn.apply_player_input(Vector3.ZERO, 0.0, 0.0, false, true)
	await _ticks(1)
	pawn.apply_player_input(Vector3(1.0, 0.0, 0.0), 0.0, 0.0, false, false)
	await _ticks(5)
	var air_speed := pawn.velocity.x
	_check(air_speed < 30.0 * 0.3 * 6.0 / 60.0 + 0.01, "steering in the air is weaker (%.2f m/s)" % air_speed)
	pawn.free()
	floor_body.free()


func _test_on_slopes() -> void:
	var terrain := TerrainGenerator.new()
	terrain.name = "SlopeTerrain"
	terrain.chunk_radius = 1
	add_child(terrain)
	await get_tree().physics_frame
	var start := Vector3(5.0, terrain.height_at(5.0, 5.0) + 0.1, 5.0)
	var pawn := _make_pawn(start)
	await _ticks(20)
	pawn.apply_player_input(Vector3(1.0, 0.0, 0.3).normalized(), 0.0, 0.0, false, false)
	var worst := 0.0
	var climbed := 0.0
	var last_y := pawn.position.y
	for i in 600:
		await _ticks(1)
		worst = maxf(worst, absf(pawn.position.y - terrain.height_at(pawn.position.x, pawn.position.z)))
		climbed += absf(pawn.position.y - last_y)
		last_y = pawn.position.y
	var walked := Vector2(pawn.position.x - start.x, pawn.position.z - start.z).length()
	_check(walked > 30.0, "it walks across hills, past chunk edges (%.0f m, %.1f m up and down)" % [walked, climbed])
	_check(worst < 0.6, "and stays on the ground (worst %.2f m off)" % worst)
	pawn.free()
	terrain.free()


## The whole point of keeping movement in plain data. Load a past tick and run it again: it has to land in the same place.
func _test_rollback_is_exact() -> void:
	var terrain := TerrainGenerator.new()
	terrain.name = "RollbackTerrain"
	terrain.chunk_radius = 1
	add_child(terrain)
	await get_tree().physics_frame
	var pawn := _make_pawn(Vector3(5.0, terrain.height_at(5.0, 5.0) + 0.1, 5.0))
	await _ticks(20)
	var pick := RandomNumberGenerator.new()
	pick.seed = 11
	var worst := 0.0
	var worst_y := 0.0
	var replays := 0
	for round_number in 6:
		for i in 25:
			var angle := pick.randf() * TAU
			pawn.apply_player_input(Vector3(cos(angle), 0.0, sin(angle)), 0.0, 0.0, pick.randf() < 0.3, pick.randf() < 0.06)
			await _ticks(1)
		await get_tree().physics_frame # the signal comes before this frame's tick, so this lets the last tick finish
		var real_position := pawn.position
		var real_velocity := pawn.velocity
		var real_grounded := pawn.grounded
		var went_back: bool = TickDriver.rollback(TickDriver.tick - 20)
		replays += 1 if went_back else 0
		if went_back:
			worst = maxf(worst, pawn.position.distance_to(real_position))
			worst_y = maxf(worst_y, pawn.velocity.distance_to(real_velocity))
			if pawn.grounded != real_grounded:
				worst = 1000.0
	_check(replays == 6, "(rolled back and ran 20 ticks again %d times, on hills with jumps)" % replays)
	_check(worst < 0.0011, "a replay lands in the same place (worst %.4f m)" % worst)
	_check(worst_y < 0.011, "with the same velocity (worst %.4f m/s)" % worst_y)
	pawn.free()
	terrain.free()


func _test_no_movement_module() -> void:
	var floor_body := _make_floor()
	var pawn: Pawn = load(PAWN_SCENE).instantiate()
	pawn.get_node("GroundMovement").free()
	pawn.position = Vector3(0.0, 0.01, 0.0)
	add_child(pawn)
	pawn.apply_player_input(Vector3(1.0, 0.0, 0.0), 0.0, 0.0, false, false)
	await _ticks(30)
	_check(absf(pawn.position.x) < 0.001, "with no movement module, a pawn stands still")
	pawn.free()
	floor_body.free()


func _test_bad_input() -> void:
	var pawn: Pawn = load(PAWN_SCENE).instantiate()
	add_child(pawn)
	var clean := pawn.sanitize_network_input({"move_input": Vector3(1000.0, 0.0, 0.0), "wants_jump": "yes", "look_yaw": INF, "look_pitch": "up"})
	_check(is_equal_approx(clean["move_input"].length(), 1.0), "the server limits a client's direction")
	_check(clean["wants_jump"] == false and clean["wants_sprint"] == false, "and throws out wrong types")
	_check(clean["look_yaw"] == 0.0 and clean["look_pitch"] == 0.0, "and broken angles")
	var nan_move := pawn.sanitize_network_input({"move_input": Vector3(NAN, 0.0, 0.0)})
	_check(nan_move["move_input"] == Vector3.ZERO, "and broken directions")
	pawn.free()


class StandStillMovement extends MovementModule:
	var ran := 0

	func simulate(_pawn: Pawn, _dt: float) -> void:
		ran += 1


func _test_swapping_movement() -> void:
	var floor_body := _make_floor()
	var pawn := _make_pawn(Vector3(0.0, 0.1, 0.0))
	await _ticks(20)
	var other := StandStillMovement.new()
	pawn.add_child(other)
	pawn.movement = other
	await _ticks(5)
	_check(other.ran == 5, "a pawn can swap its movement module")
	pawn.free()
	floor_body.free()


func _test_source_rules() -> void:
	var pawn := _make_pawn(Vector3.ZERO)
	_check(pawn.get_node_or_null("StreamingSource") == null, "an AI pawn carries no source by default")
	pawn.ai_loads_chunks = true
	_check(pawn.get_node_or_null("StreamingSource") != null, "with its bool on, it does")
	pawn.ai_loads_chunks = false
	await get_tree().process_frame
	_check(pawn.get_node_or_null("StreamingSource") == null, "and it goes when the bool goes off")
	pawn.set_has_player(true)
	_check(pawn.get_node_or_null("StreamingSource") != null, "a pawn with a player has one")
	pawn.set_has_player(false)
	await get_tree().process_frame
	_check(pawn.get_node_or_null("StreamingSource") == null, "until the player leaves")
	pawn.free()


func _test_ai_with_no_ground() -> void:
	var terrain := TerrainGenerator.new()
	terrain.name = "EmptyTerrain"
	terrain.build_on_start = false
	add_child(terrain)
	var driver: Node = get_node("/root/TickDriver")
	var participants_before: int = driver.get_participant_count()
	var pawn := _make_pawn(Vector3(5.0, 40.0, 5.0))
	pawn.apply_player_input(Vector3(1.0, 0.0, 0.0), 0.0, 0.0, false, false)
	await _ticks(30)
	_check(not pawn.is_simulation_active(), "an AI pawn with no ground is switched off")
	_check(is_equal_approx(pawn.position.y, 40.0) and is_equal_approx(pawn.position.x, 5.0), "so it stays exactly where it is")
	# Claude 2026-11-07: the bug this guards against: its entity and TickState kept ticking, so a pawn that was off still cost a lot.
	var entity: NetworkEntity = pawn.get_node("NetworkEntity")
	var state: TickStateComponent = pawn.get_node("TickState")
	_check(not driver.is_registered(pawn) and not driver.is_registered(entity) and not driver.is_registered(state), "and nothing of it ticks")
	pawn.set_has_player(true)
	_check(pawn.is_simulation_active(), "a player taking it switches it on")
	_check(driver.is_registered(pawn) and driver.is_registered(entity) and driver.is_registered(state), "and all of it ticks again")
	pawn.set_has_player(false)
	await _ticks(2)
	_check(not pawn.is_simulation_active(), "(it's off again)")
	pawn.free()
	await get_tree().process_frame
	_check(driver.get_participant_count() == participants_before, "and a pawn freed while it's off leaves nothing behind")
	terrain.free()


func _test_no_arms_by_default() -> void:
	var pawn := _make_pawn(Vector3.ZERO)
	_check(pawn.get_camera_arm() == null, "a pawn has no camera arm by default")
	pawn.free()
	var hero: Pawn = load(PAWN_SCENE).instantiate()
	hero.always_has_camera_arm = true
	add_child(hero)
	_check(hero.get_camera_arm() != null, "a hero pawn has one from the start")
	_check(not hero.get_camera_arm().is_processing(), "and it's idle with nobody looking")
	hero.free()


func _test_visual_smoothing() -> void:
	var floor_body := _make_floor()
	var pawn := _make_pawn(Vector3(0.0, 0.1, 0.0))
	await _ticks(20)
	var visual := pawn.get_visual()
	_check(visual != pawn and visual.top_level, "Visual follows on its own")
	pawn._on_network_corrected(Vector3(2.0, 0.0, 0.0))
	await get_tree().process_frame
	await get_tree().process_frame # the signal comes before this frame's _process
	_check(visual.global_position.distance_to(pawn.global_position) > 1.0, "a correction shows as an offset at first")
	for i in 40:
		await get_tree().process_frame
	_check(visual.global_position.distance_to(pawn.global_position) < 0.2, "and fades out quickly (%.2f m left)" % visual.global_position.distance_to(pawn.global_position))
	pawn.free()
	floor_body.free()


## Not a pass or fail, just numbers.
func _measure_a_crowd() -> void:
	var floor_body := _make_floor()
	var pawns: Array[Pawn] = []
	for i in 200:
		var pawn := _make_pawn(Vector3((i % 20) * 3.0 - 30.0, 0.1, (i / 20) * 3.0 - 15.0))
		pawn.apply_player_input(Vector3(1.0, 0.0, 0.0), 0.0, 0.0, false, false)
		pawns.append(pawn)
	await _ticks(30)
	var started := Time.get_ticks_usec()
	for i in 60:
		TickDriver.step()
	print("        200 pawns walking: %.2f ms a tick" % ((Time.get_ticks_usec() - started) / 60000.0))
	for pawn in pawns:
		pawn.free()
	floor_body.free()


# --- Helpers ---


func _make_floor() -> StaticBody3D:
	var body := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(4000.0, 1.0, 4000.0)
	shape.shape = box
	shape.position.y = -0.5
	body.add_child(shape)
	add_child(body)
	return body


func _make_pawn(at: Vector3) -> Pawn:
	var pawn: Pawn = load(PAWN_SCENE).instantiate()
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
