## Written by Claude (claude-opus-5-5), 2026-11-17: headless self-test for BodyNavFeeder: a wall fed to nav bends paths around it, and
## once the wall leaves the tree the path goes straight again. Also the odd cases at the top of BodyNavFeeder.gd.
## Exits 0 on success, 1 on failure. Run from the project folder:
##   godot --headless --path . "res://assets/scripts/world/tests/body_nav_feeder_selftest.tscn"
extends SelfTest

var _nav: Object = null


func _ready() -> void:
	print("--- Body nav feeder self-test ---")
	_test_not_on_a_static_body()
	if not Engine.has_singleton(&"NavServer"):
		print("  (no C++ library: nothing else to check)")
	else:
		_nav = Engine.get_singleton(&"NavServer")
		_nav.configure({"worker_threads": 2})
		await _test_wall_bends_the_path()
	print("--- ALL PASSED ---" if _failures == 0 else "--- %d FAILED ---" % _failures)
	get_tree().quit(0 if _failures == 0 else 1)


func _test_not_on_a_static_body() -> void:
	var holder := Node3D.new()
	var feeder := BodyNavFeeder.new()
	holder.add_child(feeder)
	add_child(holder) # warns: its parent isn't a StaticBody3D
	_check(feeder._body == null and not feeder._submitted, "on something that isn't a StaticBody3D, it feeds nothing")
	holder.free()


func _test_wall_bends_the_path() -> void:
	_check(is_equal_approx(_nav.get_config().agent_radius, 0.4), "nav's default pawn radius is the default pawn's, 0.4 m (was 0.3)")
	var ground := _make_box(Vector3(0, -0.5, 0), Vector3(40, 1, 40), Vector3.ZERO)
	# A wall across the straight line from (-6, 0, 0) to (6, 0, 0), turned a quarter so the shape's transform is used too.
	var wall := _make_box(Vector3(0, 1.5, 0), Vector3(10, 3, 1), Vector3(0, PI / 2, 0))
	var interest: int = _nav.add_interest(Vector3.ZERO, 30.0, 40.0, 1)
	await _settle()
	var around := _path_length(Vector3(-6, 0, 0), Vector3(6, 0, 0))
	_check(around > 13.0, "with the wall in nav, the path goes around it (%.1f m, straight is 12)" % around)
	wall.free()
	await _settle()
	var straight := _path_length(Vector3(-6, 0, 0), Vector3(6, 0, 0))
	_check(absf(straight - 12.0) < 0.1, "with the wall gone, the path is straight again (%.1f m)" % straight)
	ground.free()
	_nav.remove_interest(interest)


# A static body with one box, and a BodyNavFeeder on it. The box's shape node is turned by shape_rotation.
func _make_box(at: Vector3, size: Vector3, shape_rotation: Vector3) -> StaticBody3D:
	var body := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size
	shape.shape = box
	shape.rotation = shape_rotation
	body.add_child(shape)
	body.add_child(BodyNavFeeder.new())
	body.position = at
	add_child(body)
	return body


# Ticks nav until its tiles are built.
func _settle() -> void:
	for i in 2000:
		_nav.tick(1.0 / 60.0)
		if i > 2 and _nav.is_idle():
			break
		OS.delay_msec(2)
	await get_tree().process_frame


func _path_length(from: Vector3, to: Vector3) -> float:
	var result: Dictionary = _nav.find_path_now_result(from, to, 0, false)
	var points: PackedVector3Array = result.get("points", PackedVector3Array())
	var length := 0.0
	for i in range(1, points.size()):
		length += points[i - 1].distance_to(points[i])
	return length
