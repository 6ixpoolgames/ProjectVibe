## Written by Claude (claude-opus-5-5), 2026-11-08: headless self-test for NavigationManager (pawn spec section 7, step 7), and
## AIController.move_to, which uses it. Checks the odd cases at the top of NavigationManager.gd.
## Exits 0 on success, 1 on failure. Run from the project folder:
##   "C:\Git\Test 2\Godot_v4.7.2-stable_win64_console.exe" --headless --path . "res://assets/scripts/navigation/tests/navigation_manager_selftest.tscn"
extends Node

const PAWN_SCENE := "res://assets/scenes/pawn/pawn.tscn"
const Course := preload("res://assets/scripts/navigation/tests/nav_links_selftest.gd") # Claude 2026-11-08: the links course

var _failures := 0


## A player controller that presses nothing, so tests can hand the pawn to "a player" without real devices.
class StillController extends PlayerController:
	func _read_move() -> Vector2:
		return Vector2.ZERO


## Test code, kept out of NavigationManager: it follows corners it's given, so corner-by-corner following can be checked on a flat
## floor, where a real nav path would be one straight line. Placed in the pawn's scene with the default part's name, so it also
## shows a designer's own part replacing the default.
class GivenCornersNavigation extends NavigationManager:
	var given := PackedVector3Array()

	func move_to(point: Vector3) -> bool:
		stop()
		if pawn == null:
			return false
		_corners = PackedVector3Array([pawn.global_position])
		_corners.append_array(given)
		_corners.append(point)
		_next_corner = 1
		return true


func _ready() -> void:
	print("--- Navigation manager self-test ---")
	Engine.max_fps = 60
	_test_not_on_a_pawn()
	# The straight-line tests run first, while NavServer has no nav at all.
	await _test_straight_line_with_no_nav()
	await _test_without_a_navigation_manager()
	await _test_corner_by_corner()
	await _test_following_a_nav_path()
	await _test_crossing_links()
	print("--- ALL PASSED ---" if _failures == 0 else "--- %d FAILED ---" % _failures)
	get_tree().quit(0 if _failures == 0 else 1)


func _test_not_on_a_pawn() -> void:
	var holder := Node.new()
	var navigation := NavigationManager.new()
	holder.add_child(navigation)
	add_child(holder) # warns: its parent isn't a Pawn
	_check(navigation.pawn == null, "on something that isn't a Pawn, it has no pawn")
	_check(not navigation.move_to(Vector3(5, 0, 0)), "so move_to says there's no way")
	_check(navigation.get_move_direction() == Vector3.ZERO and not navigation.is_following_path(), "and it never gives a direction")
	holder.free()


func _test_straight_line_with_no_nav() -> void:
	var floor_body := _make_floor()
	var pawn := _make_pawn(Vector3(0, 0.1, 0))
	await _ticks(20)
	var navigation := pawn.navigation_manager
	_check(navigation != null and navigation.pawn == pawn, "a pawn gets a NavigationManager by default, which knows its pawn")
	_check(navigation.get_move_direction() == Vector3.ZERO and not navigation.is_following_path() and not navigation.has_arrived(),
			"with no path: no direction, not following, not arrived")

	var arrivals := [0]
	navigation.arrived.connect(func(): arrivals[0] += 1)
	var ai: AIController = pawn.controller_manager.ai_controller
	var target := Vector3(6.0, 0.0, 2.0)
	_check(ai.move_to(target), "with no nav anywhere, AIController.move_to still works")
	_check(navigation.get_path_corners().size() == 1, "as a straight line: one corner ahead, the point itself")
	var ticks := await _walk_until_done(navigation, 600)
	var distance := Vector2(pawn.position.x - target.x, pawn.position.z - target.z).length()
	_check(navigation.has_arrived() and not navigation.is_following_path(), "it gets there (%d ticks)" % ticks)
	_check(distance < navigation.arrival_distance + 0.4, "close to the point (%.2f m)" % distance)
	_check(arrivals[0] == 1, "arrived is sent once (%d)" % arrivals[0])
	await _ticks(30)
	_check(pawn.velocity.length() < 0.05, "and the pawn stands still there")

	# A direction from the manager is flat and length 1.
	ai.move_to(Vector3(-4.0, 3.0, 0.0))
	var direction := navigation.get_move_direction()
	_check(is_zero_approx(direction.y) and is_equal_approx(direction.length(), 1.0), "its direction is flat and length 1")
	_check(not navigation.has_arrived(), "a new move_to clears has_arrived")

	# Telling the AI anything else drops the path.
	ai.move_in_direction(Vector3(0, 0, 1))
	_check(not navigation.is_following_path(), "AIController.move_in_direction drops the path")
	ai.move_to(Vector3(-4.0, 0.0, 0.0))
	ai.stop()
	_check(not navigation.is_following_path(), "and so does stop()")
	ai.move_to(Vector3(-4.0, 0.0, 0.0))
	ai.release_all()
	_check(not navigation.is_following_path(), "and release_all()")

	# A player taking the pawn drops the AI's path, and letting go doesn't bring it back.
	ai.move_to(Vector3(-8.0, 0.0, 0.0))
	var player := StillController.new()
	add_child(player)
	pawn.set_has_player(true)
	player.take_pawn(pawn)
	_check(not navigation.is_following_path(), "a player taking the pawn drops the AI's path")
	player.move_to(Vector3(-8.0, 0.0, 0.0))
	_check(navigation.is_following_path(), "PlayerController.move_to uses the same manager")
	player.take_pawn(null)
	pawn.set_has_player(false)
	_check(not navigation.is_following_path(), "letting go drops the player's path, so the AI doesn't walk the rest of it")
	await _ticks(20)
	_check(pawn.move_input.length() < 0.01, "and the AI stands where it was told to (still)")
	player.free()
	pawn.free()
	floor_body.free()


func _test_without_a_navigation_manager() -> void:
	var floor_body := _make_floor()
	var pawn: Pawn = load(PAWN_SCENE).instantiate()
	pawn.skip_default_parts = [&"NavigationManager"]
	pawn.position = Vector3(0, 0.1, 0)
	add_child(pawn)
	await _ticks(5)
	_check(pawn.navigation_manager == null, "skip_default_parts can leave it out")
	var ai: AIController = pawn.controller_manager.ai_controller
	_check(not ai.move_to(Vector3(5, 0, 0)), "then AIController.move_to says no, with a warning")
	await _ticks(10)
	_check(pawn.move_input.length() < 0.01, "and the pawn stays put")
	pawn.free()
	floor_body.free()


func _test_corner_by_corner() -> void:
	var floor_body := _make_floor()
	var pawn: Pawn = load(PAWN_SCENE).instantiate()
	var own := GivenCornersNavigation.new()
	own.name = "NavigationManager"
	own.given = PackedVector3Array([Vector3(4, 0, 0), Vector3(4, 0, 4)])
	pawn.add_child(own)
	pawn.position = Vector3(0, 0.1, 0)
	add_child(pawn)
	await _ticks(10)
	_check(pawn.navigation_manager == own, "a NavigationManager placed in the pawn's scene is used instead of the default")
	var ai: AIController = pawn.controller_manager.ai_controller
	var target := Vector3(0, 0, 4)
	ai.move_to(target)
	_check(own.get_path_corners().size() == 3, "a square path: three corners ahead")
	var seen: Array[int] = [3]
	var closest_to_corners: Array[float] = [INF, INF]
	var ticks := 0
	while own.is_following_path() and ticks < 900:
		await get_tree().physics_frame
		ticks += 1
		var left := own.get_path_corners().size()
		if left != seen[-1]:
			seen.append(left)
		for i in 2:
			var flat := Vector2(pawn.position.x - own.given[i].x, pawn.position.z - own.given[i].z).length()
			closest_to_corners[i] = minf(closest_to_corners[i], flat)
	_check(seen == [3, 2, 1, 0], "it passes the corners one at a time, in order (%s)" % str(seen))
	_check(closest_to_corners[0] < own.corner_reached_distance + 0.2 and closest_to_corners[1] < own.corner_reached_distance + 0.2,
			"going round each corner, not cutting across (%.2f m, %.2f m)" % closest_to_corners)
	var distance := Vector2(pawn.position.x - target.x, pawn.position.z - target.z).length()
	_check(own.has_arrived() and distance < own.arrival_distance + 0.4, "and arrives at the end (%.2f m, %d ticks)" % [distance, ticks])
	pawn.free()
	floor_body.free()


func _test_following_a_nav_path() -> void:
	NavServer.configure({"worker_threads": 4})
	var terrain := TerrainGenerator.new()
	terrain.name = "PathTerrain"
	terrain.chunk_size = 64.0
	terrain.chunk_resolution = 11
	terrain.chunk_radius = 2
	var feeder := TerrainNavFeeder.new()
	feeder.nav_hooks = NavHooks.new()
	terrain.add_child(feeder)
	add_child(terrain)
	var interest := NavServer.add_interest(Vector3.ZERO, 80.0, 90.0, 1)
	_settle()
	await get_tree().physics_frame

	var start := Vector3(5.0, terrain.height_at(5.0, 5.0) + 0.1, 5.0)
	var pawn := _make_pawn(start)
	await _ticks(10)
	var navigation := pawn.navigation_manager
	var ai: AIController = pawn.controller_manager.ai_controller
	var target := Vector3(-40.0, 0.0, 30.0) # across a chunk border, over hills
	target.y = terrain.height_at(target.x, target.z)
	_check(ai.move_to(target), "with nav, move_to finds a path")
	var corners_at_start := navigation.get_path_corners().size()
	_check(corners_at_start >= 1, "with corners ahead (%d)" % corners_at_start)
	# Rolling hills give a nearly straight path here; _test_corner_by_corner covers turning corners.
	var ticks := 0
	while navigation.is_following_path() and ticks < 900:
		NavServer.tick(1.0 / 60.0)
		await get_tree().physics_frame
		ticks += 1
	var distance := Vector2(pawn.position.x - target.x, pawn.position.z - target.z).length()
	_check(navigation.has_arrived(), "it walks the path to the end (%d ticks)" % ticks)
	_check(distance < 1.0, "and ends at the point (%.2f m away)" % distance)
	_check(pawn.position.y > terrain.height_at(pawn.position.x, pawn.position.z) - 0.5, "on the ground")

	# Somewhere nowhere near nav: no way there, and the path it had is dropped.
	ai.move_to(Vector3(0.0, terrain.height_at(0.0, 0.0), 0.0))
	_check(navigation.is_following_path(), "(walking again)")
	_check(not ai.move_to(Vector3(5000.0, 0.0, 5000.0)), "a point nowhere near nav: move_to says no")
	_check(not navigation.is_following_path(), "and the path it had is dropped, so it doesn't wander off on the old one")

	pawn.free()
	terrain.free()
	NavServer.remove_interest(interest)
	_settle()


# Claude 2026-11-08: links. The course from nav_links_selftest, with collision: A, a 2 m gap, B, a 2 m drop to C, a 0.8 m step up
# to D. A real pawn walks it, so the jumps must actually land.
func _test_crossing_links() -> void:
	NavServer.configure({"worker_threads": 4})
	var layer := Course.build_course()
	var bodies: Array[StaticBody3D] = []
	for box: Array in Course.course_boxes():
		bodies.append(_make_box(box[0], box[1]))
	var interest: int = NavServer.add_interest(Vector3(4, 0, 0), 45.0, 60.0, 1)
	_settle()
	await get_tree().physics_frame

	var pawn := _make_pawn(Vector3(-10, 0.1, 0))
	await _ticks(10)
	var navigation := pawn.navigation_manager
	var ai: AIController = pawn.controller_manager.ai_controller

	var across := await _walk_course_leg(pawn, ai, Vector3(6, 0, 0))
	_check(across.crossed_link and across.fastest_up > 3.0 and across.highest > 0.3, "A to B: it reaches the gap and jumps (up to %.2f m)" % across.highest)
	_check(navigation.has_arrived() and across.distance < 1.0 and absf(pawn.position.y) < 0.3, "and lands on B, at the goal (%.2f m, %d ticks)" % [across.distance, across.ticks])

	var down := await _walk_course_leg(pawn, ai, Vector3(16, -2, 0))
	_check(down.crossed_link and down.fastest_up < 1.0, "B to C: it walks off the ledge, with no jump")
	_check(navigation.has_arrived() and down.distance < 1.0 and absf(pawn.position.y + 2.0) < 0.3, "and gets to the goal on C (%.2f m)" % down.distance)

	var up := await _walk_course_leg(pawn, ai, Vector3(24, -1.2, 0))
	_check(up.crossed_link and up.fastest_up > 3.0, "C to D: it jumps up the step (%.1f m/s upward)" % up.fastest_up)
	_check(navigation.has_arrived() and up.distance < 1.0 and absf(pawn.position.y + 1.2) < 0.3, "and gets to the goal on D (%.2f m)" % up.distance)

	# use_links off: a pawn that can't jump never leaves D, however far its goal.
	navigation.use_links = false
	var stays := await _walk_course_leg(pawn, ai, Vector3(-10, 0, 0))
	_check(not stays.crossed_link and absf(pawn.position.y + 1.2) < 0.3, "use_links off: it goes only as far as it can walk, and stays on D")
	navigation.use_links = true

	# A link it can't cross: a placed ladder from C up to B that presses nothing. It tries, finds one new path, misses again, and
	# gives up rather than trying forever.
	await _walk_course_leg(pawn, ai, Vector3(16, -2, 0))
	var ladder: int = NavServer.add_link(Vector3(13.5, -2, 0), Vector3(10.5, 0, 0), false, &"")
	_settle()
	navigation.link_timeout = 1.0
	var stuck := await _walk_course_leg(pawn, ai, Vector3(6, 0, 0), 900)
	_check(stuck.crossed_link and not navigation.is_following_path() and not navigation.has_arrived(),
			"a link it can't cross: after one new path and a second miss, it stops, neither following nor arrived (%d ticks)" % stuck.ticks)
	_check(absf(pawn.position.y + 2.0) < 0.3, "still down on C")
	NavServer.remove_link(ladder)

	pawn.free()
	for body in bodies:
		body.free()
	NavServer.remove_interest(interest)
	NavServer.remove_input_layer(layer)
	_settle()


## Walks the pawn to the goal with AIController.move_to, ticking nav as it goes, and reports what happened.
func _walk_course_leg(pawn: Pawn, ai: AIController, goal: Vector3, limit := 600) -> Dictionary:
	var navigation := pawn.navigation_manager
	var report := {"crossed_link": false, "highest": pawn.position.y, "fastest_up": 0.0, "ticks": 0, "distance": INF}
	if not ai.move_to(goal):
		return report
	while navigation.is_following_path() and report.ticks < limit:
		NavServer.tick(1.0 / 60.0)
		await get_tree().physics_frame
		report.ticks += 1
		report.crossed_link = report.crossed_link or navigation.is_crossing_link()
		report.highest = maxf(report.highest, pawn.position.y)
		report.fastest_up = maxf(report.fastest_up, pawn.velocity.y) # a jump starts at 5 m/s upward; walking uphill is far slower
	await _ticks(20) # let it settle where it stopped
	report.distance = Vector2(pawn.position.x - goal.x, pawn.position.z - goal.z).length()
	return report


func _make_box(lo: Vector3, hi: Vector3) -> StaticBody3D:
	var body := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = hi - lo
	shape.shape = box
	body.position = (lo + hi) * 0.5
	body.add_child(shape)
	add_child(body)
	return body


# --- Helpers ---


func _walk_until_done(navigation: NavigationManager, limit: int) -> int:
	var ticks := 0
	while navigation.is_following_path() and ticks < limit:
		await get_tree().physics_frame
		ticks += 1
	return ticks


func _make_pawn(at: Vector3) -> Pawn:
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


func _settle() -> void:
	for i in 4000:
		NavServer.tick(1.0 / 60.0)
		if i > 2 and NavServer.is_idle():
			return
		OS.delay_msec(2)
	_check(false, "nav became idle within the time limit")


func _ticks(count: int) -> void:
	for i in count:
		await get_tree().physics_frame


func _check(passed: bool, what: String) -> void:
	print("  %s %s" % ["ok  " if passed else "FAIL", what])
	if not passed:
		_failures += 1
