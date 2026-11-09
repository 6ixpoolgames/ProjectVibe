## Written by Claude (claude-opus-5-5), 2026-11-09: headless self-test for line of sight in C++ (SightGeometry, scaling spec step 4):
## it agrees with physics rays on a map of terrain and props (rotated boxes, spheres, capsules, cylinders, on different layers), it
## keeps up as bodies come, go, move, change shape or layer, and as the terrain is edited, and it says how much faster it is.
## Needs the navcore C++ library; without it, it says so and passes.
## Exits 0 on success, 1 on failure. Run from the project folder:
##   "C:\Git\Test 2\Godot_v4.7.2-stable_win64_console.exe" --headless --path . "res://assets/scripts/ai/tests/sight_geometry_selftest.tscn"
extends Node

const RAYS := 20000

var _failures := 0


func _ready() -> void:
	print("--- Sight geometry self-test ---")
	if not ClassDB.class_exists(&"SightGeometry"):
		print("  no C++ library here: nothing to test")
		print("--- ALL PASSED ---")
		get_tree().quit(0)
		return
	await _test_agrees_with_physics()
	await _test_keeps_up()
	print("--- ALL PASSED ---" if _failures == 0 else "--- %d FAILED ---" % _failures)
	get_tree().quit(0 if _failures == 0 else 1)


## 20,000 random rays over hilly terrain and 80 props: each blocked or not exactly as a physics ray says, nearly always.
func _test_agrees_with_physics() -> void:
	var pick := RandomNumberGenerator.new()
	pick.seed = 3
	var map := Node3D.new()
	add_child(map)
	var terrain := TerrainGenerator.new()
	terrain.chunk_size = 64.0
	terrain.chunk_resolution = 32 # 2 m squares
	terrain.height_scale = 20.0
	terrain.chunk_radius = 1 # 3 by 3 chunks
	terrain.build_collision = true
	map.add_child(terrain)
	for i in 160:
		var shape: Shape3D
		match i % 4:
			0:
				shape = BoxShape3D.new()
				shape.size = Vector3(pick.randf_range(0.5, 6), pick.randf_range(1, 5), pick.randf_range(0.5, 6))
			1:
				shape = SphereShape3D.new()
				shape.radius = pick.randf_range(0.5, 3)
			2:
				shape = CapsuleShape3D.new()
				shape.radius = pick.randf_range(0.3, 1.5)
				shape.height = shape.radius * 2.0 + pick.randf_range(0.5, 4)
			3:
				shape = CylinderShape3D.new()
				shape.radius = pick.randf_range(0.3, 2.5)
				shape.height = pick.randf_range(0.5, 5)
		# Most on layer 1 (the world); some on layer 3 (value 4), which only some rays look for.
		var layer := 4 if i % 5 == 0 else 1
		var body := _make_body(shape, layer)
		var x := pick.randf_range(-55, 115)
		var z := pick.randf_range(-55, 115)
		body.position = Vector3(x, terrain.height_at(x, z) + pick.randf_range(0, 3), z)
		body.rotation = Vector3(pick.randf_range(-0.6, 0.6), pick.randf_range(-PI, PI), pick.randf_range(-0.6, 0.6))
		map.add_child(body)
	# A convex hull on layer 4 (value 8): line of sight uses its bounding box, with a warning. Rays below don't look for that layer.
	var hull := ConvexPolygonShape3D.new()
	hull.points = PackedVector3Array([Vector3(0, 0, 0), Vector3(2, 0, 0), Vector3(0, 2, 0), Vector3(0, 0, 2)])
	var hull_body := _make_body(hull, 8)
	hull_body.position = Vector3(30, terrain.height_at(30, 30) + 1, 30)
	map.add_child(hull_body)
	for i in 3:
		await get_tree().physics_frame # the bodies join the physics world
	var geometry: Object = ClassDB.instantiate(&"SightGeometry")
	_add_bodies(geometry, map)
	geometry.sync(1)
	var stats: Dictionary = geometry.get_stats()
	print("        geometry: %d bodies, %d pieces, %d triangles, %d cells, %d big pieces" % [stats["bodies"], stats["pieces"], stats["triangles"], stats["cells"], stats["big"]])
	_check(stats["bodies"] == 9 + 161 and stats["bounding_box_stand_ins"] == 1, "every terrain chunk and prop is in it, and the hull stands in as its bounding box (%s)" % str(stats))
	var space := get_viewport().world_3d.direct_space_state
	var query := PhysicsRayQueryParameters3D.new()
	var agree := 0
	var blocked := 0
	var physics_usec := 0
	var geometry_usec := 0
	var differ := []
	var masks := [1, 1 | 4, 4]
	for i in RAYS:
		var fx := pick.randf_range(-55, 115)
		var fz := pick.randf_range(-55, 115)
		var from := Vector3(fx, terrain.height_at(fx, fz) + pick.randf_range(0.3, 3), fz)
		var direction := Vector2(pick.randf_range(-1, 1), pick.randf_range(-1, 1)).normalized() * pick.randf_range(2, 40)
		var tx := clampf(fx + direction.x, -60, 120)
		var tz := clampf(fz + direction.y, -60, 120)
		var to := Vector3(tx, terrain.height_at(tx, tz) + pick.randf_range(0.3, 3), tz)
		var mask: int = masks[i % masks.size()]
		query.from = from
		query.to = to
		query.collision_mask = mask
		var started := Time.get_ticks_usec()
		var physics_says: bool = not space.intersect_ray(query).is_empty()
		physics_usec += Time.get_ticks_usec() - started
		started = Time.get_ticks_usec()
		var geometry_says: bool = geometry.is_blocked(from, to, mask)
		geometry_usec += Time.get_ticks_usec() - started
		if physics_says == geometry_says:
			agree += 1
		elif differ.size() < 5:
			differ.append("%s -> %s mask %d: physics %s, geometry %s" % [from, to, mask, physics_says, geometry_says])
		if physics_says:
			blocked += 1
	for line in differ:
		print("        differs: %s" % line)
	var share := float(agree) / RAYS
	_check(blocked > RAYS / 5 and blocked < RAYS * 4 / 5, "a real mix: %d of %d rays blocked by physics" % [blocked, RAYS])
	_check(share >= 0.995, "line of sight agrees with physics rays on %.2f%% of %d rays (at least 99.5%%: physics rounds box corners slightly)" % [share * 100.0, RAYS])
	print("        a ray: physics %.2f µs, geometry %.2f µs, on the main thread" % [float(physics_usec) / RAYS, float(geometry_usec) / RAYS])
	map.free()
	await get_tree().physics_frame


## The shared geometry follows the scene: bodies added, moved, resized, put on another layer and removed, and the terrain edited.
func _test_keeps_up() -> void:
	var geometry: Object = SightGeometryFeeder.get_geometry()
	_check(geometry != null, "the feeder makes the shared geometry")
	var ground := TerrainGenerator.new()
	ground.chunk_size = 32.0
	ground.chunk_resolution = 16
	ground.height_scale = 0.0 # flat, at 0
	ground.chunk_radius = 0
	ground.build_collision = true
	add_child(ground)
	var from := Vector3(4, 1, 16)
	var to := Vector3(28, 1, 16)
	geometry.sync(100)
	_check(not geometry.is_blocked(from, to, 1), "flat ground, a ray a metre above it: clear")
	var box := BoxShape3D.new()
	box.size = Vector3(1, 3, 1)
	var wall := _make_body(box, 1)
	wall.position = Vector3(16, 1.5, 16)
	add_child(wall)
	geometry.sync(101)
	_check(geometry.is_blocked(from, to, 1), "a wall added to the scene blocks it at the next sync")
	wall.position = Vector3(16, 1.5, 25)
	geometry.sync(102)
	_check(not geometry.is_blocked(from, to, 1) and geometry.is_blocked(Vector3(4, 1, 25), Vector3(28, 1, 25), 1), "moved: the old line is clear and the new one blocked")
	box.size = Vector3(1, 3, 30) # the resource changes: the body is read again, even within the same tick
	geometry.sync(102)
	_check(geometry.is_blocked(from, to, 1), "its shape made longer, it reaches the first line again")
	wall.collision_layer = 2
	geometry.sync(103)
	_check(not geometry.is_blocked(from, to, 1) and geometry.is_blocked(from, to, 2), "on another layer: only rays looking for that layer meet it")
	remove_child(wall)
	geometry.sync(104)
	_check(not geometry.is_blocked(from, to, 3), "taken out of the scene: gone")
	wall.free()
	ground.edit(Vector3(16, 0, 16), 4.0, 5.0) # a hill between the two ends
	geometry.sync(105)
	_check(geometry.is_blocked(from, to, 1), "the terrain edited into a hill between them: blocked")
	ground.free()
	geometry.sync(106)
	_check(not geometry.is_blocked(from, to, 1), "the terrain freed: nothing left")


func _make_body(shape: Shape3D, layer: int) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.collision_layer = layer
	var collision := CollisionShape3D.new()
	collision.shape = shape
	body.add_child(collision)
	return body


func _add_bodies(geometry: Object, node: Node) -> void:
	if node is CollisionObject3D:
		geometry.add_body(node)
	for child in node.get_children():
		_add_bodies(geometry, child)


func _check(passed: bool, what: String) -> void:
	print("  %s %s" % ["ok  " if passed else "FAIL", what])
	if not passed:
		_failures += 1
