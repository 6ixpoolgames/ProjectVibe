## Written by Claude (claude-opus-5-5), 2026-11-16: checks the CrowdMover (pawn spec 8.22): AI pawns walking on the ground are moved as a
## crowd instead of by move_and_slide, cover the same ground, stay on it, keep apart, are stopped by walls and drops (by falling back
## to physics), and anything that needs physics still gets it. Run headless; exit code 0 means everything passed.
extends SelfTest # Claude 2026-11-16 (wider audit): _check and _failures come from tests/SelfTest.gd now

const PAWN_SCENE := "res://assets/scenes/pawn/pawn.tscn"

var _mover: CrowdMover = null


func _ready() -> void:
	print("--- Crowd mover self-test ---")
	_mover = CrowdMover.current
	_check(_mover != null and GameMode.crowd_mover == _mover, "the CrowdMover is a GameMode module by default (GameMode.crowd_mover)")
	if _mover == null:
		_finish()
		return
	await _test_same_distance()
	await _test_slope()
	await _test_separation()
	await _test_wall_and_edge()
	await _test_physics_cases()
	await _test_sleeping() # Claude 2026-11-16: the owner asked whether still pawns sleep with the mover
	await _test_switched_off()
	_finish()


# Walking on flat ground: moved by the crowd mover, as far as by physics, and standing on the ground.
func _test_same_distance() -> void:
	var ground := _make_box(Vector3(0, -0.5, 0), Vector3(400, 1, 400))
	var crowd := _make_pawn(Vector3(0, 0.05, 0))
	var physics := _make_pawn(Vector3(0, 0.05, 30))
	physics.crowd_movement = false
	await _ticks(20)
	for i in 60:
		_drive(crowd, Vector3(1, 0, 0))
		_drive(physics, Vector3(1, 0, 0))
		await _ticks(1)
	_check(_mover.moved_last_tick >= 1, "an AI pawn walking on the ground is moved by the crowd mover (%d last tick)" % _mover.moved_last_tick)
	var crowd_went := crowd.global_position.x
	var physics_went := physics.global_position.x
	_check(physics_went > 1.0 and absf(crowd_went - physics_went) < physics_went * 0.05,
		"and walks as far as one moving by physics (%.2f m against %.2f m)" % [crowd_went, physics_went])
	_check(absf(crowd.global_position.y) < 0.01 and crowd.grounded, "standing on the ground (%.3f m up)" % crowd.global_position.y)
	_check(crowd.velocity.length() > 1.0 and absf(crowd.velocity.y) < 0.001, "its velocity is what it really moved, flat (%s)" % crowd.velocity)
	crowd.free()
	physics.free()
	ground.free()


# Up a slope: it follows the ground.
func _test_slope() -> void:
	var ground := _make_box(Vector3(0, -0.5, 0), Vector3(400, 1, 400))
	var ramp := _make_box(Vector3(10, 0, 0), Vector3(20, 1, 6), deg_to_rad(15.0))
	var pawn := _make_pawn(Vector3(6, 0.05, 0))
	await _ticks(20)
	var highest := 0.0
	var by_crowd := 0
	for i in 150:
		_drive(pawn, Vector3(1, 0, 0))
		await _ticks(1)
		highest = maxf(highest, pawn.global_position.y)
		by_crowd += _mover.moved_last_tick - _mover.fallbacks_last_tick
	_check(highest > 1.5 and by_crowd > 60, "up a 15 degree ramp it follows the ground, mostly by the crowd mover (%.2f m up, %d crowd moves)" % [highest, by_crowd])
	pawn.free()
	ramp.free()
	ground.free()


# Two pawns walking into each other end up apart, not inside each other.
func _test_separation() -> void:
	var ground := _make_box(Vector3(0, -0.5, 0), Vector3(400, 1, 400))
	var left := _make_pawn(Vector3(-3, 0.05, 0))
	var right := _make_pawn(Vector3(3, 0.05, 0.05))
	await _ticks(20)
	var closest := INF
	for i in 120:
		_drive(left, Vector3(1, 0, 0))
		_drive(right, Vector3(-1, 0, 0))
		await _ticks(1)
		closest = minf(closest, Vector2(left.global_position.x - right.global_position.x, left.global_position.z - right.global_position.z).length())
	var touching := left.get_body_radius() + right.get_body_radius()
	_check(closest > touching * 0.85, "two pawns walking straight at each other never get inside each other (closest %.2f m, %.2f touching)" % [closest, touching])
	left.free()
	right.free()
	ground.free()


# A wall stops it, and walking off an edge drops it: both by falling back to physics.
func _test_wall_and_edge() -> void:
	var ground := _make_box(Vector3(0, -0.5, 0), Vector3(400, 1, 400))
	var wall := _make_box(Vector3(5, 1.5, 0), Vector3(1, 3, 10))
	var pawn := _make_pawn(Vector3(0, 0.05, 0))
	await _ticks(20)
	var fell_back := 0
	for i in 90:
		_drive(pawn, Vector3(1, 0, 0))
		await _ticks(1)
		fell_back += _mover.fallbacks_last_tick
	_check(pawn.global_position.x < 4.5 - pawn.get_body_radius() + 0.05 and fell_back > 0,
		"a wall stops it (at %.2f m, the wall's face at 4.5), by physics (%d fallbacks)" % [pawn.global_position.x, fell_back])
	pawn.free()
	wall.free()
	# Claude 2026-11-16: a thin post just off its line (0.3 m to the side, 0.1 m wide), which a single ray down the middle walked
	# straight past; the swept capsule finds it.
	var post := _make_box(Vector3(5, 1.0, 0.3), Vector3(0.1, 2, 0.1))
	var passer := _make_pawn(Vector3(0, 0.05, 0))
	await _ticks(20)
	var closest := INF # from the pawn's middle to the post's sides, flat; under its radius would mean its body went into the post
	for i in 90:
		_drive(passer, Vector3(1, 0, 0))
		await _ticks(1)
		var at := passer.global_position
		var dx := maxf(maxf(4.95 - at.x, at.x - 5.05), 0.0)
		var dz := maxf(maxf(0.25 - at.z, at.z - 0.35), 0.0)
		closest = minf(closest, Vector2(dx, dz).length())
	_check(closest > passer.get_body_radius() - 0.02,
		"a thin post just off its line: it slides round it rather than through it (closest %.2f m, its radius %.2f; ended at %s)" % [closest, passer.get_body_radius(), passer.global_position])
	passer.free()
	post.free()
	ground.free()
	var shelf := _make_box(Vector3(0, -0.5, 0), Vector3(10, 1, 10)) # ends at x = 5
	var below := _make_box(Vector3(0, -5.5, 0), Vector3(400, 1, 400))
	var walker := _make_pawn(Vector3(0, 0.05, 0))
	await _ticks(20)
	var lowest := 0.0
	for i in 200:
		_drive(walker, Vector3(1, 0, 0))
		await _ticks(1)
		lowest = minf(lowest, walker.global_position.y)
	_check(lowest < -4.8 and walker.grounded, "walking off an edge it falls to the ground below, and stands there (%.2f m)" % lowest)
	walker.free()
	shelf.free()
	below.free()


# A player's pawn, a jump and a dash move by physics.
func _test_physics_cases() -> void:
	var ground := _make_box(Vector3(0, -0.5, 0), Vector3(400, 1, 400))
	var pawn := _make_pawn(Vector3(0, 0.05, 0))
	await _ticks(20)
	_check(_mover.try_take_move(pawn, true, 1.0 / 60.0) == false, "(asked outside a tick, it doesn't take the move: it wouldn't run in time)")
	var jumped := false
	var crowd_while_up := false
	_ai(pawn).press(&"jump")
	for i in 30:
		await _ticks(1)
		if pawn.global_position.y > 0.2:
			jumped = true
			if _mover.moved_last_tick > 0:
				crowd_while_up = true
	_check(jumped and not crowd_while_up, "a jump goes up by physics, and stays with physics while in the air")
	await _ticks(30)
	_ai(pawn).press(&"dash")
	await _ticks(2)
	_check(pawn.ability_manager.needs_full_movement() and _mover.moved_last_tick == 0, "a dash needs full movement, so it dashes by physics")
	await _ticks(60)
	var coordinator: PossessionCoordinator = GameMode.possession_coordinator
	if coordinator and coordinator.possess(pawn):
		await _ticks(5)
		var moved_as_crowd := 0
		for i in 20:
			pawn.controller_manager.apply_input(InputCommand.make(Vector3(1, 0, 0), []))
			await _ticks(1)
			moved_as_crowd += _mover.moved_last_tick
		_check(moved_as_crowd == 0, "a pawn a player has always moves by physics (%d crowd moves)" % moved_as_crowd)
		coordinator.release()
	else:
		_check(false, "(couldn't possess the pawn to check the player case)")
	pawn.free()
	ground.free()


# Still pawns sleep (pawn spec 15.3) with the mover as they did with physics: alone, and packed in so their capsules started out
# overlapping, where separation pushes them apart and then has to stop for them to sleep. A pawn sleeps on all but its check ticks,
# one every sleep_check_ticks (15), so about 28 of 30 ticks.
func _test_sleeping() -> void:
	var ground := _make_box(Vector3(0, -0.5, 0), Vector3(400, 1, 400))
	var alone := _make_pawn(Vector3(-20, 0.05, 0))
	var packed: Array[Pawn] = []
	for i in 5:
		packed.append(_make_pawn(Vector3(i * 0.5, 0.05, 0.0))) # 0.5 m apart, 0.8 m wide: overlapping
	await _ticks(150)
	var asleep_alone := 0
	var asleep_packed := 0
	for i in 30:
		await _ticks(1)
		if alone.is_sleeping:
			asleep_alone += 1
		for pawn in packed:
			if pawn.is_sleeping:
				asleep_packed += 1
	_check(asleep_alone >= 26, "a still AI pawn sleeps with the crowd mover on (%d of 30 ticks)" % asleep_alone)
	var spread_out := true
	for i in range(1, packed.size()):
		var apart := Vector2(packed[i].global_position.x - packed[i - 1].global_position.x, packed[i].global_position.z - packed[i - 1].global_position.z).length()
		if apart < packed[i].get_body_radius() * 2.0 - 0.05:
			spread_out = false
	_check(spread_out and asleep_packed >= 26 * packed.size(), "pawns placed overlapping are pushed apart, settle, and sleep (%d of %d pawn-ticks)" % [asleep_packed, 30 * packed.size()])
	alone.free()
	for pawn in packed:
		pawn.free()
	ground.free()


# Switched off, every pawn moves by physics.
func _test_switched_off() -> void:
	var ground := _make_box(Vector3(0, -0.5, 0), Vector3(400, 1, 400))
	var pawn := _make_pawn(Vector3(0, 0.05, 0))
	await _ticks(20)
	_mover.enabled = false
	var crowd_moves := 0
	for i in 30:
		_drive(pawn, Vector3(1, 0, 0))
		await _ticks(1)
		crowd_moves += _mover.moved_last_tick
	_check(crowd_moves == 0 and pawn.global_position.x > 1.0, "with the mover off, it walks by physics (%d crowd moves, %.2f m)" % [crowd_moves, pawn.global_position.x])
	_mover.enabled = true
	pawn.free()
	ground.free()


# --- Helpers ---


func _make_box(at: Vector3, size: Vector3, tilt_z := 0.0) -> StaticBody3D:
	var body := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size
	shape.shape = box
	body.add_child(shape)
	body.position = at
	body.rotation.z = tilt_z
	add_child(body)
	return body


func _make_pawn(at: Vector3) -> Pawn:
	var pawn: Pawn = load(PAWN_SCENE).instantiate()
	pawn.position = at
	add_child(pawn)
	return pawn


func _ai(pawn: Pawn) -> AIController:
	return pawn.controller_manager.ai_controller as AIController


# One tick's input through the pawn's AI controller, which is in charge of a pawn nobody plays.
func _drive(pawn: Pawn, move: Vector3) -> void:
	_ai(pawn).move_in_direction(move)


func _ticks(count: int) -> void:
	for i in count:
		await get_tree().physics_frame


func _finish() -> void:
	print("--- ALL PASSED ---" if _failures == 0 else "--- %d FAILED ---" % _failures)
	get_tree().quit(0 if _failures == 0 else 1)
