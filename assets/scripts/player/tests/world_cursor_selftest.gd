## Written by Claude (claude-opus-5-5), 2026-11-07: headless self-test for WorldCursor and click-to-move.
## Exits 0 on success, 1 on failure. Run from the project folder:
##   "C:\Git\Test 2\Godot_v4.7.2-stable_win64_console.exe" --headless --path . "res://assets/scripts/player/tests/world_cursor_selftest.tscn"
extends Node

const PAWN_SCENE := "res://assets/scenes/pawn/pawn.tscn"

var _failures := 0


## Something that isn't a node.
class PlainUser extends Object:
	var name := "plain"


## Claude 2026-11-07: test code, kept out of WorldCursor. It counts the times it asks, and aims at the middle of the screen, because
## a headless run has no mouse to aim with.
class TestCursor extends WorldCursor:
	var ray_count := 0

	func query_now() -> Dictionary:
		ray_count += 1
		return super()

	func _screen_point(camera: Camera3D) -> Vector2:
		return camera.get_viewport().get_visible_rect().size * 0.5


func _ready() -> void:
	print("--- World cursor self-test ---")
	Engine.max_fps = 60
	await _test_off_by_default()
	await _test_answers()
	await _test_rates()
	await _test_cleanup()
	await _test_no_camera()
	await _test_click_to_move()
	print("--- ALL PASSED ---" if _failures == 0 else "--- %d FAILED ---" % _failures)
	get_tree().quit(0 if _failures == 0 else 1)


func _test_off_by_default() -> void:
	var cursor := _make_cursor()
	var before := cursor.ray_count
	await _frames(5)
	_check(not cursor.is_watching() and not cursor.is_processing(), "the cursor is off by default")
	_check(cursor.ray_count == before, "and casts no rays")
	cursor.free()


func _test_answers() -> void:
	var cursor := _make_cursor()
	var floor_body := _make_floor()
	var camera := _make_camera()
	await _physics_frames(3)
	var hit := cursor.query_now()
	_check(not hit.is_empty(), "a one-off query works while it's off")
	_check(not hit.is_empty() and absf(hit["position"].y) < 0.01, "and finds the floor")
	_check(not hit.is_empty() and hit["collider"] == floor_body, "and says what it hit")
	_check(not hit.is_empty() and hit["normal"].is_equal_approx(Vector3.UP), "and which way it faces")
	_check(not cursor.is_processing(), "and leaves it off")

	cursor.collision_mask = 2
	_check(cursor.query_now().is_empty(), "its mask decides what it can hit")
	cursor.collision_mask = 1
	cursor.max_distance = 1.0
	_check(cursor.query_now().is_empty(), "and its distance how far")
	camera.free()
	floor_body.free()
	cursor.free()


func _test_rates() -> void:
	var cursor := _make_cursor()
	var floor_body := _make_floor()
	var camera := _make_camera()
	await _physics_frames(3)
	var slow := Node.new()
	add_child(slow)
	var heard := [0]
	var on_hit := func(_hit: Dictionary) -> void: heard[0] += 1
	cursor.hit_changed.connect(on_hit)
	cursor.acquire(slow, 10.0)
	_check(cursor.is_watching(), "something asking turns it on")
	var started := Time.get_ticks_msec()
	while Time.get_ticks_msec() - started < 1000:
		await get_tree().process_frame
	_check(heard[0] >= 8 and heard[0] <= 12, "at the rate it asked for (%d in a second, asked for 10)" % heard[0])
	_check(not cursor.last_hit.is_empty(), "and keeps the last answer")

	# The fastest rate wins.
	var fast := Node.new()
	add_child(fast)
	cursor.acquire(fast, 40.0)
	heard[0] = 0
	started = Time.get_ticks_msec()
	while Time.get_ticks_msec() - started < 500:
		await get_tree().process_frame
	_check(heard[0] >= 14 and heard[0] <= 24, "with two users, the faster rate wins (%d in half a second, asked for 20)" % heard[0])
	cursor.release(fast)
	_check(cursor.get_user_count() == 1, "and it carries on for the one that's left")
	fast.free()

	var every_frame := Node.new()
	add_child(every_frame)
	cursor.acquire(every_frame)
	heard[0] = 0
	await _frames(20)
	_check(heard[0] >= 19, "a rate of 0 means every frame (%d in 20)" % heard[0])
	cursor.release(every_frame)
	every_frame.free()
	cursor.release(slow)
	_check(not cursor.is_watching(), "when the last one lets go, it's off")
	_check(cursor.last_hit.is_empty(), "and forgets its answer")
	var rays := cursor.ray_count
	await _frames(5)
	_check(cursor.ray_count == rays, "and casts no more rays")
	slow.free()
	cursor.hit_changed.disconnect(on_hit)
	camera.free()
	floor_body.free()
	cursor.free()


func _test_cleanup() -> void:
	var cursor := _make_cursor()
	var user := Node.new()
	add_child(user)
	cursor.acquire(user, 10.0)
	user.free()
	_check(cursor.get_user_count() == 0 and not cursor.is_watching(), "a user being freed counts as letting go")

	var left := Node.new()
	add_child(left)
	cursor.acquire(left, 10.0)
	remove_child(left)
	_check(not cursor.is_watching(), "and so does one leaving the scene")
	left.free()

	var plain := PlainUser.new()
	cursor.acquire(plain, 10.0)
	_check(cursor.is_watching(), "something that isn't a node can use it")
	plain.free()
	await _frames(2)
	_check(not cursor.is_watching(), "and it notices when that's gone too")
	cursor.acquire(null)
	_check(not cursor.is_watching(), "asking for nothing does nothing")
	cursor.release(self)
	_check(true, "and neither does letting go of something that never asked")
	cursor.free()


func _test_no_camera() -> void:
	var existing := get_viewport().get_camera_3d()
	_check(existing == null, "(no camera in the scene)")
	var cursor := _make_cursor()
	_check(cursor.query_now().is_empty(), "with no camera, it answers with nothing")
	var user := Node.new()
	add_child(user)
	cursor.acquire(user)
	await _frames(3)
	_check(cursor.last_hit.is_empty(), "and watching doesn't break")
	user.free()
	cursor.free()


func _test_click_to_move() -> void:
	NavServer.configure({"worker_threads": 4})
	var terrain := Terrain.new()
	terrain.name = "ClickTerrain"
	terrain.chunk_size = 64.0
	terrain.chunk_resolution = 11
	terrain.chunk_radius = 2
	var link := WorldNavLink.new() # Claude 2026-11-07: a terrain feeds nav through this now
	link.nav_hooks = NavHooks.new()
	terrain.add_child(link)
	add_child(terrain)
	var interest := NavServer.add_interest(Vector3.ZERO, 80.0, 90.0, 1)
	_settle()
	await get_tree().physics_frame

	var controller := PlayerController.new()
	add_child(controller)
	_check(not controller.move_to(Vector3.ZERO), "with no pawn, there's nothing to move")
	var start := Vector3(5.0, terrain.height_at(5.0, 5.0) + 0.1, 5.0)
	var pawn: Pawn = load(PAWN_SCENE).instantiate()
	pawn.position = start
	add_child(pawn)
	controller.take_pawn(pawn)
	await _physics_frames(10)
	var target := Vector3(-40.0, 0.0, 30.0) # across a chunk border, into another chunk
	target.y = terrain.height_at(target.x, target.z)
	_check(controller.move_to(target), "clicking a place starts walking there")
	_check(controller.is_following_path(), "along a path")
	var ticks := 0
	while controller.is_following_path() and ticks < 900:
		NavServer.tick(1.0 / 60.0)
		await get_tree().physics_frame
		ticks += 1
	var distance := Vector2(pawn.position.x - target.x, pawn.position.z - target.z).length()
	_check(not controller.is_following_path(), "and it finishes (%d ticks)" % ticks)
	_check(distance < 2.0, "at the place clicked (%.1f m away)" % distance)
	_check(pawn.position.y > terrain.height_at(pawn.position.x, pawn.position.z) - 0.5, "on the ground")
	_check(pawn.move_input.length() < 0.01, "and stops")

	# The cursor finds the ground under a camera, and clicking uses it.
	var camera := Camera3D.new()
	add_child(camera)
	camera.make_current()
	camera.global_transform = Transform3D(Basis(Vector3.RIGHT, -PI * 0.5), Vector3(10.0, 60.0, 10.0))
	await _physics_frames(3)
	var aimed_cursor := _make_cursor()
	var hit: Dictionary = aimed_cursor.query_now()
	aimed_cursor.free()
	_check(not hit.is_empty() and Vector2(hit["position"].x - 10.0, hit["position"].z - 10.0).length() < 0.1, "the cursor finds the terrain straight below a camera looking down")
	_check(not hit.is_empty() and absf(hit["position"].y - terrain.height_at(10.0, 10.0)) < 0.05, "at the right height")
	camera.free()

	# A key takes over.
	controller.move_to(Vector3(30.0, terrain.height_at(30.0, 30.0), 30.0))
	_check(controller.is_following_path(), "(walking again)")
	var keys := KeyController.new()
	add_child(keys)
	keys.take_pawn(pawn)
	keys.move_to(Vector3(30.0, terrain.height_at(30.0, 30.0), 30.0))
	keys.pressed = Vector2(0.0, -1.0)
	await _physics_frames(3)
	_check(not keys.is_following_path(), "pressing a movement key drops the path")
	keys.take_pawn(null)
	controller.take_pawn(null)
	keys.free()
	controller.free()
	pawn.free()
	terrain.free()
	NavServer.remove_interest(interest)
	_settle()


class KeyController extends PlayerController:
	var pressed := Vector2.ZERO

	func _read_move() -> Vector2:
		return pressed


# --- Helpers ---


func _make_cursor() -> TestCursor:
	var cursor := TestCursor.new()
	add_child(cursor)
	return cursor


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


func _make_camera() -> Camera3D:
	var camera := Camera3D.new()
	add_child(camera)
	camera.make_current()
	camera.global_transform = Transform3D(Basis(Vector3.RIGHT, -PI * 0.5), Vector3(0.0, 10.0, 0.0))
	return camera


func _settle() -> void:
	for i in 4000:
		NavServer.tick(1.0 / 60.0)
		if i > 2 and NavServer.is_idle():
			return
		OS.delay_msec(2)
	_check(false, "nav became idle within the time limit")


func _frames(count: int) -> void:
	for i in count:
		await get_tree().process_frame


func _physics_frames(count: int) -> void:
	for i in count:
		await get_tree().physics_frame


func _check(passed: bool, what: String) -> void:
	print("  %s %s" % ["ok  " if passed else "FAIL", what])
	if not passed:
		_failures += 1
