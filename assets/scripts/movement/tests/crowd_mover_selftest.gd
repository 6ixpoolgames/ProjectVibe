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
	await _test_obstacles_from_store()
	await _test_teleport_and_move_check()
	await _test_walks_along_nav_mesh() # Claude 2026-11-17 (C++ bundle stage 3); last, since it sets NavServer up for itself
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
	_check(_mover.take_move(pawn, true, 1.0 / 60.0) == false, "(asked outside a tick, it doesn't take the move: it wouldn't run in time)")
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


# Claude 2026-11-17 (C++ bundle stage 3): with the C++ batch (CrowdBatch) and a nav mesh, a pawn walks along the nav mesh: it isn't
# handed to physics at a wall, but slides along the nav mesh's edge, a body's width from the wall, and the ground under it comes from
# the sight geometry's copy of the level. Without the library there's nothing to check here.
func _test_walks_along_nav_mesh() -> void:
	if not ClassDB.class_exists(&"CrowdBatch") or not Engine.has_singleton(&"NavServer"):
		print("  (no C++ library: the nav mesh walk isn't checked)")
		return
	var nav: Object = Engine.get_singleton(&"NavServer")
	# Tier 0 as wide as the pawns (0.4 m), so their walls can come from the nav mesh (crowd_batch.h).
	nav.configure({"agent_radius": 0.4, "worker_threads": 2})
	var layer: int = nav.add_input_layer(null, NavHooks.new(), ClassDB.class_get_integer_constant(&"NavServer", &"ADAPTER_MESH"))
	var ground := _make_box(Vector3(0, -0.5, 0), Vector3(60, 1, 60))
	var wall := _make_box(Vector3(5, 1.5, 0), Vector3(1, 3, 20)) # its face at x = 4.5, from z = -10 to 10
	nav.submit_mesh(layer, 1, _box_faces(Vector3(-30, -1, -30), Vector3(30, 0, 30)), Transform3D.IDENTITY)
	nav.submit_mesh(layer, 2, _box_faces(Vector3(4.5, 0, -10), Vector3(5.5, 3, 10)), Transform3D.IDENTITY)
	var interest: int = nav.add_interest(Vector3.ZERO, 30.0, 40.0, 1)
	for i in 2000:
		nav.tick(1.0 / 60.0)
		if i > 2 and nav.is_idle():
			break
		OS.delay_msec(2)
	_check(nav.closest_point(Vector3.ZERO, 0) != null, "(a nav mesh was built for the test: %d tiles)" % nav.get_stats().live_detour_tiles)
	var pawn := _make_pawn(Vector3(0, 0.05, 0))
	await _ticks(20)
	var fell_back := 0
	var walked := 0
	for i in 120:
		_drive(pawn, Vector3(1, 0, 0.5)) # into the wall, at an angle
		await _ticks(1)
		fell_back += _mover.fallbacks_last_tick
		walked += int(_mover._cpp_batch.get_stats().moved) if _mover._cpp_batch else 0
	var at := pawn.global_position
	_check(walked > 100 and fell_back == 0, "on the nav mesh, the C++ batch moves it every tick (%d moves, %d handed to physics)" % [walked, fell_back])
	_check(at.x < 4.5 - 0.4 + 0.05 and at.x > 3.5, "it stops a body's width from the wall (at x %.2f, the wall's face at 4.5)" % at.x)
	_check(at.z > 4.0, "and slides along it instead of stopping dead (z %.2f)" % at.z)
	_check(absf(at.y) < 0.02 and pawn.grounded, "standing on the ground, from the sight geometry's copy of it (y %.3f)" % at.y)
	pawn.free()
	wall.free()
	ground.free()
	nav.remove_interest(interest)
	nav.remove_input_layer(layer)


# The pawns the crowd keeps clear of stand where the state store's last frame has them (one call for all), except those that moved
# by physics this tick, read from their nodes. A pawn moved by code since the last commit counts at its old place until then.
func _test_obstacles_from_store() -> void:
	var ground := _make_box(Vector3(0, -0.5, 0), Vector3(400, 1, 400))
	var standing := _make_pawn(Vector3(2, 0.05, 0))
	await _ticks(20)
	var store: Object = get_node("/root/TickDriver").store
	var handle := standing.get_store_handle()
	var tick: int = store.newest_tick(handle) + 1 # as during the next tick's simulate
	var stored: Vector3 = store.get_value(handle, 0, tick - 1)
	var before: Array = _mover._obstacles([] as Array[Pawn], tick)
	_check(_mover._member_index.has(standing) and (before[0] as PackedVector3Array).has(stored),
			"a pawn joins the crowd's members as it enters, and stands where the store's last frame has it")
	standing.global_position = Vector3(6, 0.05, 0) # moved by code, between ticks
	var stale: Array = _mover._obstacles([] as Array[Pawn], tick)
	_check((stale[0] as PackedVector3Array).has(stored), "moved by code since the last commit, it counts at its old place for now")
	_mover.note_moved(standing)
	var fresh: Array = _mover._obstacles([] as Array[Pawn], tick)
	_check((fresh[0] as PackedVector3Array).has(standing.global_position), "moved by physics this tick, it's read from its node")
	_mover._moved_this_tick.clear()
	var moving: Array = _mover._obstacles([standing] as Array[Pawn], tick)
	_check(not (moving[0] as PackedVector3Array).has(stored) and not (moving[0] as PackedVector3Array).has(standing.global_position),
			"one that's moving with the crowd this tick isn't an obstacle to itself")
	standing.free()
	_check(not _mover._member_index.has(standing), "and it leaves the members as it leaves the tree")
	ground.free()


func _box_faces(lo: Vector3, hi: Vector3) -> PackedVector3Array:
	var c := [
		Vector3(lo.x, lo.y, lo.z), Vector3(hi.x, lo.y, lo.z), Vector3(hi.x, lo.y, hi.z), Vector3(lo.x, lo.y, hi.z),
		Vector3(lo.x, hi.y, lo.z), Vector3(hi.x, hi.y, lo.z), Vector3(hi.x, hi.y, hi.z), Vector3(lo.x, hi.y, hi.z),
	]
	# Each side wound to face out, as Godot draws front faces (clockwise seen from outside), so the top is walkable ground. GDScript
	# note: nav_selftest's version faces in, which is fine for carving but leaves no ground.
	var quads := [[3, 2, 1, 0], [4, 5, 6, 7], [1, 5, 4, 0], [2, 6, 5, 1], [3, 7, 6, 2], [0, 4, 7, 3]]
	var faces := PackedVector3Array()
	for q in quads:
		faces.append_array([c[q[0]], c[q[1]], c[q[2]], c[q[0]], c[q[2]], c[q[3]]])
	return faces


# Pawn.teleport tells the crowd to read the pawn from its node, and the MoveSanityCheck lets the jump through; a position set
# directly is caught.
func _test_teleport_and_move_check() -> void:
	var ground := _make_box(Vector3(0, -0.5, 0), Vector3(400, 1, 400))
	var pawn := _make_pawn(Vector3(0, 0.05, 0))
	await _ticks(20)
	var driver := get_node("/root/TickDriver")
	var check := MoveSanityCheck.new()
	pawn.global_position = Vector3(30, 0.05, 0) # set directly: a jump nothing explains
	for i in 6:
		await _ticks(1)
		check.check(driver.store, driver.tick, driver.get_tick_dt())
	_check(check.caught == 1, "a position set directly is caught by the move check (%d)" % check.caught)
	pawn.teleport(Vector3(-30, 0.05, 0))
	_check(_mover._moved_this_tick.has(pawn) and pawn.last_teleport_tick == driver.tick,
			"a teleport tells the crowd to read the pawn from its node, and notes its tick")
	for i in 6:
		await _ticks(1)
		check.check(driver.store, driver.tick, driver.get_tick_dt())
	_check(check.caught == 1 and check.checked_last_tick > 0, "and the move check lets a teleport through")
	pawn.free()
	ground.free()


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
