## Written by Claude (claude-opus-5-5), 2026-11-05: headless test for Terrain. It checks the merged features, and
## that each bug found in procgen_tile.gd stays fixed. Exits 0 on success, 1 on failure. Run from the project folder:
##   Godot_v4.4.1-stable_win64.exe --headless --path . "res://assets/scripts/terrain/tests/terrain_selftest.tscn"
extends Node

# GDScript note: preload reads a file when this script compiles, and const keeps it under a name. COURSE.new() then
# makes one. This script has no class_name, so this is how to reach it.
const COURSE := preload("res://assets/scripts/terrain/tests/terrain_test_course.gd")

var _failures := 0


# GDScript note: a function that uses "await" pauses there and carries on later, while the game keeps running. Calling
# such a function with await waits for it to finish. Physics needs that, since it only updates between frames.
func _ready() -> void:
	print("--- Terrain self-test ---")
	_test_same_heights_as_nav_test_terrain()
	_test_noise_type_is_what_it_says()
	_test_fractal_settings_do_something()
	_test_noise_scale()
	_test_size_settings()
	_test_far_edge()
	_test_chunks_join_up()
	_test_center_chunk()
	_test_uvs()
	_test_jitter()
	_test_flat_shading()
	_test_smooth_shading()
	_test_edit()
	_test_regenerate()
	_test_bad_settings()
	await _test_collision()
	await _test_moved_node()
	_test_nav()
	_measure_nav_inputs()
	print("--- %s (%d failed) ---" % ["PASS" if _failures == 0 else "FAIL", _failures])
	get_tree().quit(1 if _failures > 0 else 0)


func _test_same_heights_as_nav_test_terrain() -> void:
	# With no jitter and the same settings and course, they should give the same ground everywhere.
	var merged: Terrain = COURSE.new()
	_use_plain_grid(merged)
	merged.chunk_radius = 2
	merged.fractal_octaves = 4
	merged.height_scale = 10.0
	add_child(merged)
	var original := NavTestTerrain.new()
	add_child(original)
	var worst := 0.0
	for z in range(-75, 75, 3):
		for x in range(-75, 75, 3):
			# The extra fractions land these inside squares, not only on the corners.
			worst = maxf(worst, absf(merged.height_at(x + 0.3, z + 0.6) - original.height_at(x + 0.3, z + 0.6)))
	_check(worst < 0.00001, "with no jitter, same heights as nav_test_terrain.gd, inside squares too (worst %.6f m)" % worst)
	merged.free()
	original.free()


func _test_noise_type_is_what_it_says() -> void:
	# The bug in procgen_tile.gd: its menu's "Simplex" gave Cellular. Compare against noise made directly from Godot.
	for type: FastNoiseLite.NoiseType in [FastNoiseLite.TYPE_SIMPLEX, FastNoiseLite.TYPE_SIMPLEX_SMOOTH, FastNoiseLite.TYPE_CELLULAR, FastNoiseLite.TYPE_PERLIN, FastNoiseLite.TYPE_VALUE_CUBIC, FastNoiseLite.TYPE_VALUE]:
		var terrain := _make_terrain(0)
		terrain.noise_type = type
		terrain.generate()
		var expected := FastNoiseLite.new()
		expected.seed = terrain.noise_seed
		expected.noise_type = type
		expected.frequency = terrain.frequency
		expected.fractal_octaves = terrain.fractal_octaves
		var wanted := expected.get_noise_2d(5.0, 7.0) * terrain.height_scale
		_check(is_equal_approx(terrain.height_at(5.0, 7.0), wanted), "noise type %d is really that type" % type)
		terrain.free()


func _test_fractal_settings_do_something() -> void:
	var one_layer := _make_terrain(0)
	one_layer.fractal_octaves = 1
	one_layer.generate()
	var eight_layers := _make_terrain(0)
	eight_layers.fractal_octaves = 8
	eight_layers.generate()
	_check(not _same_ground(one_layer, eight_layers), "octaves change the ground by default")

	# Turning the fractal off is still a choice you can make, and then octaves do nothing.
	one_layer.fractal_type = FastNoiseLite.FRACTAL_NONE
	one_layer.generate()
	eight_layers.fractal_type = FastNoiseLite.FRACTAL_NONE
	eight_layers.generate()
	_check(_same_ground(one_layer, eight_layers), "with fractal off, octaves do nothing")
	one_layer.free()
	eight_layers.free()


func _test_noise_scale() -> void:
	var plain := _make_terrain(0)
	var stretched := _make_terrain(0)
	stretched.noise_scale = Vector2(2.0, 1.0)
	stretched.generate()
	_check(is_equal_approx(stretched.height_at(5.0, 7.0), plain.height_at(10.0, 7.0)), "noise_scale stretches the noise along x")
	var points_before: PackedVector3Array = plain._points[Vector2i.ZERO]
	var points_after: PackedVector3Array = stretched._points[Vector2i.ZERO]
	_check(is_equal_approx(points_before[5].x, points_after[5].x), "and doesn't move the grid points")
	plain.free()
	stretched.free()


func _test_size_settings() -> void:
	# The bug in procgen_tile.gd: the size set in a scene was ignored at runtime. Settings here are made before the
	# node enters the scene, which is the same order a scene file uses.
	var terrain := Terrain.new()
	terrain.chunk_radius = 0
	terrain.chunk_resolution = 50
	terrain.chunk_size = 150.0
	terrain.grid_jitter = 0.0
	terrain.build_collision = false
	add_child(terrain)
	var points: PackedVector3Array = terrain._points[Vector2i.ZERO]
	_check(points.size() == 51 * 51, "chunk_resolution is used (%d points)" % points.size())
	_check(terrain.raycast(Vector3(149.0, 50.0, 1.0), Vector3.DOWN) != null and terrain.raycast(Vector3(151.0, 50.0, 1.0), Vector3.DOWN) == null, "chunk_size is the chunk's width in metres")

	# Grid size and tile size are separate: a finer grid doesn't make the terrain bigger.
	terrain.chunk_resolution = 10
	terrain.generate()
	_check(terrain.raycast(Vector3(149.0, 50.0, 1.0), Vector3.DOWN) != null and terrain.raycast(Vector3(151.0, 50.0, 1.0), Vector3.DOWN) == null, "changing chunk_resolution leaves the size alone")
	terrain.free()


func _test_far_edge() -> void:
	# A bug in the first version and nav_test_terrain.gd: the exact far edge returned 0.
	var terrain := _make_terrain(0)
	var edge: float = terrain._points[Vector2i.ZERO][32 + 10 * 33].y
	_check(is_equal_approx(terrain.height_at(32.0, 10.0), edge), "the terrain's exact far edge has the right height (%.3f m)" % edge)
	terrain.free()


func _test_chunks_join_up() -> void:
	for jitter: float in [0.0, 1.0]:
		var terrain := _make_terrain(1)
		terrain.grid_jitter = jitter
		terrain.generate()
		_check(_borders_match(terrain), "with jitter %.0f, neighbouring chunks share their border points exactly" % jitter)
		terrain.edit(Vector3(32.0, 0.0, 10.0), 8.0, 4.0)
		_check(_borders_match(terrain), "and still do after an edit across the border")
		terrain.free()


func _test_center_chunk() -> void:
	# The bug in procgen_tile.gd: chunk_x and chunk_z were unused, so every tile had the same hills.
	var world := _make_terrain(3)
	var tile := _make_terrain(0)
	tile.center_chunk = Vector2i(2, -1)
	tile.generate()
	_check(tile._points.size() == 1 and tile._points.has(Vector2i(2, -1)), "radius 0 builds just the chosen chunk")
	var at := Vector2(2 * 32.0 + 11.2, -1 * 32.0 + 5.7)
	_check(is_equal_approx(tile.height_at(at.x, at.y), world.height_at(at.x, at.y)), "that chunk matches the same place in a larger world")
	var other := _make_terrain(0)
	_check(not is_equal_approx(other.height_at(11.2, 5.7), tile.height_at(at.x, at.y)), "different chunks have different hills")
	world.free()
	tile.free()
	other.free()


func _test_uvs() -> void:
	var terrain := _make_terrain(0)
	terrain.uv_scale = 4.0
	terrain.generate()
	# Claude 2026-11-06: reads the arrays directly, now that the terrain no longer uses SurfaceTool.
	var uvs: PackedVector2Array = terrain._make_mesh_arrays(Vector2i.ZERO)[Mesh.ARRAY_TEX_UV]
	var biggest := Vector2.ZERO
	for uv in uvs:
		biggest = biggest.max(uv)
	_check(biggest.is_equal_approx(Vector2(4.0, 4.0)), "uv_scale sets how far UVs reach")
	terrain.free()


func _test_jitter() -> void:
	var regular := _make_terrain(0)
	var shifted := _make_terrain(0)
	shifted.grid_jitter = 1.0
	shifted.generate()
	var regular_points: PackedVector3Array = regular._points[Vector2i.ZERO]
	var shifted_points: PackedVector3Array = shifted._points[Vector2i.ZERO]
	var moved := 0
	var furthest := 0.0
	for i in regular_points.size():
		var distance := Vector2(regular_points[i].x, regular_points[i].z).distance_to(Vector2(shifted_points[i].x, shifted_points[i].z))
		furthest = maxf(furthest, distance)
		if distance > 0.0:
			moved += 1
	_check(moved == regular_points.size(), "jitter moves the grid points (%d of %d)" % [moved, regular_points.size()])
	_check(furthest <= Terrain.MAX_JITTER_REACH + 0.000001 and furthest > 0.2, "no further than the limit (%.3f of a square)" % furthest)

	# Worst case: full jitter on a coarse grid. Seen from above, every triangle has to keep facing up, or the ground
	# would fold over itself.
	var flipped := 0
	var triangles := shifted._chunk_triangles(Vector2i.ZERO)
	for i in range(0, triangles.size(), 3):
		if (triangles[i + 2] - triangles[i]).cross(triangles[i + 1] - triangles[i]).y <= 0.0:
			flipped += 1
	_check(flipped == 0, "at full jitter, no triangle flips over")

	# Every machine has to build the same ground.
	var again := _make_terrain(0)
	again.grid_jitter = 1.0
	again.generate()
	_check(again._points[Vector2i.ZERO] == shifted_points, "the same settings give exactly the same points")
	again.noise_seed = 99
	again.generate()
	_check(again._points[Vector2i.ZERO][5].x != shifted_points[5].x, "a new seed shifts them differently")
	print("        fingerprint to compare between systems: %d" % _fingerprint(shifted))

	# The height has to come from the shifted triangles, right up to each corner.
	var matches := true
	for i in range(0, shifted_points.size(), 7):
		matches = matches and absf(shifted.height_at(shifted_points[i].x, shifted_points[i].z) - shifted_points[i].y) < 0.0001
	_check(matches, "height_at follows the shifted corners")
	regular.free()
	shifted.free()
	again.free()


func _test_flat_shading() -> void:
	var terrain := _make_terrain(0)
	terrain.height_scale = 30.0
	terrain.frequency = 0.1
	terrain.grid_jitter = 0.8
	terrain.generate()
	_check(not terrain.smooth_shading, "flat shading is the default")
	var arrays: Array = terrain._make_mesh_arrays(Vector2i.ZERO)
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
	_check(vertices.size() == 32 * 32 * 6, "each triangle has its own vertices")
	var flat := true
	var facing_up := true
	for i in range(0, vertices.size(), 3):
		flat = flat and normals[i].is_equal_approx(normals[i + 1]) and normals[i].is_equal_approx(normals[i + 2])
		facing_up = facing_up and normals[i].y > 0.0
	_check(flat, "each triangle faces one way all over")
	_check(facing_up, "every triangle faces up")
	terrain.free()


func _test_smooth_shading() -> void:
	# The bug in procgen_tile.gd: its smoothing setting had no effect. On or off must make a real difference.
	var terrain := _make_terrain(1)
	terrain.smooth_shading = true
	terrain.grid_jitter = 0.8
	terrain.generate()
	var n: int = terrain._points_per_edge()
	var arrays: Array = terrain._make_mesh_arrays(Vector2i.ZERO)
	_check(arrays[Mesh.ARRAY_VERTEX].size() == n * n, "smooth shading shares vertices")
	_check(_border_normals_match(terrain, n), "lighting matches across chunk borders, even with jitter")
	terrain.free()

	# This patch only reaches points in the right-hand chunk, one step past the border.
	terrain = _make_terrain(1)
	terrain.smooth_shading = true
	terrain.generate()
	var left_before: PackedVector3Array = terrain._points[Vector2i(0, 0)].duplicate()
	var normal_before: Vector3 = terrain._smooth_normal(32, 10)
	terrain.edit(Vector3(34.0, 0.0, 10.0), 1.5, 6.0)
	_check(terrain._points[Vector2i(0, 0)] == left_before, "(this edit changes no points in the left chunk)")
	_check(not terrain._smooth_normal(32, 10).is_equal_approx(normal_before), "(but it changes the lighting at the border)")
	_check(_border_normals_match(terrain, n), "so the neighbour is rebuilt too, and the lighting still matches")
	terrain.free()

	# The outer edge of a lone tile is lit as part of a larger world.
	var world := _make_terrain(1)
	world.smooth_shading = true
	world.generate()
	var tile := _make_terrain(0)
	tile.smooth_shading = true
	tile.generate()
	var world_normals: PackedVector3Array = _built_mesh_arrays(world, Vector2i.ZERO)[Mesh.ARRAY_NORMAL]
	var tile_normals: PackedVector3Array = _built_mesh_arrays(tile, Vector2i.ZERO)[Mesh.ARRAY_NORMAL]
	var same_lighting := world_normals.size() == tile_normals.size()
	for i in world_normals.size():
		same_lighting = same_lighting and world_normals[i].is_equal_approx(tile_normals[i])
	_check(same_lighting, "a lone tile is lit the same as that chunk in a larger world")
	world.free()
	tile.free()

	# A wrong sign in the sums would still point up, so check a normal against the true slope of a tiny patch.
	var tiny := _make_terrain(0)
	tiny.chunk_size = 0.04
	tiny.chunk_resolution = 4
	tiny.height_scale = 30.0
	tiny.frequency = 0.1
	tiny.generate()
	var slope_x: float = (tiny.height_at(0.03, 0.02) - tiny.height_at(0.01, 0.02)) / 0.02
	var slope_z: float = (tiny.height_at(0.02, 0.03) - tiny.height_at(0.02, 0.01)) / 0.02
	var true_normal := Vector3(-slope_x, 1.0, -slope_z).normalized()
	var how_close: float = tiny._smooth_normal(2, 2).dot(true_normal)
	_check(how_close > 0.999, "smooth normals lean the way the ground slopes (%.4f)" % how_close)
	tiny.free()


func _test_edit() -> void:
	var terrain := _make_terrain(1)
	var before_middle := terrain.height_at(3.0, 3.0)
	var before_far := terrain.height_at(20.0, 20.0)
	terrain.edit(Vector3(3.0, 0.0, 3.0), 6.0, 5.0)
	_check(is_equal_approx(terrain.height_at(3.0, 3.0), before_middle + 5.0), "edit raises the middle by the full amount")
	_check(terrain.height_at(20.0, 20.0) == before_far, "edit leaves ground outside the radius alone")
	terrain.edit(Vector3(3.0, 0.0, 3.0), 6.0, -5.0)
	_check(is_equal_approx(terrain.height_at(3.0, 3.0), before_middle), "digging by the same amount puts it back")
	var unchanged := terrain.height_at(3.0, 3.0)
	terrain.edit(Vector3(3.0, 0.0, 3.0), 0.0, 5.0)
	_check(terrain.height_at(3.0, 3.0) == unchanged, "an edit with no radius does nothing")

	var hit: Variant = terrain.raycast(Vector3(3.3, 50.0, 3.4), Vector3.DOWN)
	_check(hit != null and absf(hit.y - terrain.height_at(3.3, 3.4)) < 0.001, "raycast finds the ground")
	_check(terrain.raycast(Vector3(3.3, 50.0, 3.4), Vector3.UP) == null, "raycast pointing away finds nothing")
	_check(terrain.raycast(Vector3(500.0, 50.0, 3.4), Vector3.DOWN) == null, "raycast past the terrain's edge finds nothing")
	terrain.free()


func _test_regenerate() -> void:
	var terrain := _make_terrain(1)
	terrain.build_collision = true
	terrain.generate()
	var children_once := terrain.get_child_count()
	var height_once := terrain.height_at(5.0, 5.0)
	terrain.edit(Vector3(5.0, 0.0, 5.0), 4.0, 3.0)
	terrain.generate()
	_check(terrain.get_child_count() == children_once, "generating again replaces the old nodes (%d)" % children_once)
	_check(terrain.height_at(5.0, 5.0) == height_once, "generating again drops edits, as documented")
	terrain.noise_seed = 99
	terrain.generate()
	_check(terrain.height_at(5.0, 5.0) != height_once, "a new seed makes new ground")
	terrain.free()


func _test_bad_settings() -> void:
	var terrain := Terrain.new()
	terrain.chunk_resolution = 0
	terrain.chunk_size = 0.0
	terrain.chunk_radius = -1
	terrain.grid_jitter = 5.0
	terrain.build_collision = false
	add_child(terrain) # warnings are expected in the log here
	_check(terrain._points.size() == 1 and terrain.chunk_resolution == 1 and terrain.chunk_size == 1.0 and terrain.grid_jitter == 1.0, "bad settings fall back to working ones")
	_check(is_finite(terrain.height_at(0.5, 0.5)), "and heights still work")
	terrain.free()


func _test_collision() -> void:
	var terrain := _make_terrain(1)
	terrain.grid_jitter = 0.8
	var built := []
	# GDScript note: func(...) with no name is a small function written in place, here run when the signal fires.
	terrain.collision_built.connect(func(chunk: Vector2i, node: CollisionShape3D) -> void: built.append([chunk, node]))
	terrain.build_collision = true
	terrain.generate()
	_check(built.size() == 9, "collision_built fires once per chunk (%d)" % built.size())
	_check(built[0][1] is CollisionShape3D and built[0][1].shape is ConcavePolygonShape3D, "and hands over the collision node")

	await _physics_frames(3)
	_check(_collision_matches_heights(terrain), "with jitter, bodies land where height_at says the ground is")
	var before: float = _ray_down(terrain, Vector3(3.2, 100.0, 3.7)).position.y
	terrain.edit(Vector3(3.0, 0.0, 3.0), 6.0, 5.0)
	await _physics_frames(3)
	var after: float = _ray_down(terrain, Vector3(3.2, 100.0, 3.7)).position.y
	_check(after > before + 4.0, "editing moves the collision too (%.2f to %.2f m)" % [before, after])
	_check(_collision_matches_heights(terrain), "and it still matches height_at")
	terrain.free()

	var no_collision := _make_terrain(1)
	await _physics_frames(2)
	_check(_ray_down(no_collision, Vector3(3.2, 100.0, 3.7)).is_empty(), "build_collision off makes no collision")
	no_collision.free()


func _test_moved_node() -> void:
	# procgen_tile.gd could be placed anywhere by moving its parent, so this one can be moved too.
	var at_origin := _make_terrain(0)
	var height := at_origin.height_at(4.2, 6.6)
	at_origin.free()
	var moved := Terrain.new()
	_use_plain_grid(moved)
	moved.build_collision = true
	moved.position = Vector3(100.0, 5.0, -50.0)
	add_child(moved)
	_check(is_equal_approx(moved.height_at(104.2, -43.4), height + 5.0), "height_at follows a moved node")
	await _physics_frames(3)
	var hit := _ray_down(moved, Vector3(104.2, 100.0, -43.4))
	_check(not hit.is_empty() and absf(hit.position.y - (height + 5.0)) < 0.01, "and so does collision")
	moved.edit(Vector3(104.2, 0.0, -43.4), 4.0, 2.0)
	_check(is_equal_approx(moved.height_at(104.2, -43.4), height + 7.0), "and so does edit")
	moved.free()


func _test_nav() -> void:
	var quiet := _make_terrain(0)
	_check(quiet._nav_layer == -1, "no nav_hooks means no nav layer")
	quiet.free()

	NavServer.configure({"worker_threads": 4})
	var interest := NavServer.add_interest(Vector3.ZERO, 70.0, 90.0, 1)
	var terrain: Terrain = COURSE.new()
	_use_plain_grid(terrain)
	terrain.chunk_radius = 2
	terrain.nav_hooks = NavHooks.new()
	add_child(terrain)
	_tick_nav_until_idle()

	# Straight through the gap in the wall.
	var from := Vector3(0.0, 0.0, 4.0)
	var to := Vector3(0.0, 0.0, 14.0)
	var through := _path_length(NavServer.find_path_now(from, to, 0))
	_check(through > 9.0 and through < 14.0, "nav sees the terrain and goes through the gap (%.1f m)" % through)

	terrain.edit(Vector3(0.0, 0.0, 9.0), 4.0, 6.0)
	_tick_nav_until_idle()
	var blocked := _path_length(NavServer.find_path_now(from, to, 0))
	_check(blocked > through + 10.0, "edit reaches nav: with the gap blocked, the path gets longer (%.1f m)" % blocked)

	terrain.generate()
	_tick_nav_until_idle()
	var again := _path_length(NavServer.find_path_now(from, to, 0))
	_check(absf(again - through) < 0.5, "generating again replaces what nav had (%.1f m)" % again)

	remove_child(terrain)
	_tick_nav_until_idle()
	_check(NavServer.find_path_now(from, to, 0).size() < 2, "leaving the scene removes the terrain from nav")
	add_child(terrain)
	_tick_nav_until_idle()
	var returned := _path_length(NavServer.find_path_now(from, to, 0))
	_check(absf(returned - through) < 0.5, "coming back puts it back in nav (%.1f m)" % returned)
	terrain.free()
	_tick_nav_until_idle()

	# Default look: coarse grid, jitter, gentle hills. Nav has to walk the same triangles as everything else.
	var jittered := Terrain.new()
	jittered.build_collision = false
	jittered.nav_hooks = NavHooks.new()
	add_child(jittered)
	_tick_nav_until_idle()
	# This ground isn't flat, so start and end on it. Nav only looks a little above and below for the nearest ground.
	# The end also has to be inside the 70 m around the interest point, because nav doesn't build tiles past that.
	var start := Vector3(5.0, jittered.height_at(5.0, 5.0), 5.0)
	var end := Vector3(40.0, jittered.height_at(40.0, 40.0), 40.0)
	var path := NavServer.find_path_now(start, end, 0)
	_check(_path_length(path) > 45.0, "nav finds a path across the default jittered terrain (%.1f m)" % _path_length(path))
	var worst := 0.0
	for point in path:
		worst = maxf(worst, absf(point.y - jittered.height_at(point.x, point.z)))
	_check(worst < 0.6, "and the path follows the ground (worst %.2f m)" % worst)
	jittered.free()
	_tick_nav_until_idle()

	# Nav follows a moved node, which its heightmap input couldn't.
	var moved: Terrain = COURSE.new()
	_use_plain_grid(moved)
	moved.chunk_radius = 2
	moved.nav_hooks = NavHooks.new()
	moved.position = Vector3(20.0, 0.0, 10.0)
	add_child(moved)
	_tick_nav_until_idle()
	var moved_through := _path_length(NavServer.find_path_now(from + moved.position, to + moved.position, 0))
	_check(moved_through > 9.0 and moved_through < 14.0, "nav follows a moved node to the gap (%.1f m)" % moved_through)
	moved.free()
	_tick_nav_until_idle()
	NavServer.remove_interest(interest)
	_tick_nav_until_idle()


## Not a pass or fail, just numbers: the same ground through nav's mesh input and its heightmap input.
func _measure_nav_inputs() -> void:
	var interest := NavServer.add_interest(Vector3.ZERO, 70.0, 90.0, 1)
	for run in 2:
		var mesh_terrain: Terrain = COURSE.new()
		_use_plain_grid(mesh_terrain)
		mesh_terrain.chunk_radius = 2
		mesh_terrain.fractal_octaves = 4
		mesh_terrain.height_scale = 10.0
		mesh_terrain.nav_hooks = NavHooks.new()
		var started := Time.get_ticks_msec()
		add_child(mesh_terrain)
		var ready_mesh := Time.get_ticks_msec()
		_tick_nav_until_idle()
		var built_mesh := Time.get_ticks_msec()
		mesh_terrain.edit(Vector3(20.0, 0.0, 20.0), 5.0, 2.0)
		var edit_mesh_start := Time.get_ticks_msec()
		_tick_nav_until_idle()
		var edited_mesh := Time.get_ticks_msec()
		var mesh_length := _path_length(NavServer.find_path_now(Vector3(-20, 0, -20), Vector3(30, 0, 30), 0))
		mesh_terrain.free()
		_tick_nav_until_idle()

		var height_terrain := NavTestTerrain.new()
		height_terrain.nav_hooks = NavHooks.new()
		var started_height := Time.get_ticks_msec()
		add_child(height_terrain)
		var ready_height := Time.get_ticks_msec()
		_tick_nav_until_idle()
		var built_height := Time.get_ticks_msec()
		height_terrain.edit(Vector3(20.0, 0.0, 20.0), 5.0, 2.0)
		var edit_height_start := Time.get_ticks_msec()
		_tick_nav_until_idle()
		var edited_height := Time.get_ticks_msec()
		var height_length := _path_length(NavServer.find_path_now(Vector3(-20, 0, -20), Vector3(30, 0, 30), 0))
		height_terrain.free()
		_tick_nav_until_idle()

		print("        run %d, mesh input:      generate %d ms, nav build %d ms, nav after edit %d ms, path %.1f m" % [run + 1, ready_mesh - started, built_mesh - ready_mesh, edited_mesh - edit_mesh_start, mesh_length])
		print("        run %d, heightmap input: generate %d ms, nav build %d ms, nav after edit %d ms, path %.1f m" % [run + 1, ready_height - started_height, built_height - ready_height, edited_height - edit_height_start, height_length])
	NavServer.remove_interest(interest)
	_tick_nav_until_idle()


# --- Helpers ---


## One-metre squares with no jitter, which makes positions in these tests easy to work out.
func _use_plain_grid(terrain: Terrain) -> void:
	terrain.chunk_radius = 0
	terrain.chunk_size = 32.0
	terrain.chunk_resolution = 32
	terrain.grid_jitter = 0.0
	terrain.build_collision = false


## A terrain on the plain grid, already in the scene and generated.
func _make_terrain(radius: int) -> Terrain:
	var terrain := Terrain.new()
	_use_plain_grid(terrain)
	terrain.chunk_radius = radius
	add_child(terrain)
	return terrain


func _same_ground(a: Terrain, b: Terrain) -> bool:
	for z in range(1, 32, 3):
		for x in range(1, 32, 3):
			if not is_equal_approx(a.height_at(x, z), b.height_at(x, z)):
				return false
	return true


func _borders_match(terrain: Terrain) -> bool:
	var n: int = terrain._points_per_edge()
	var left: PackedVector3Array = terrain._points[Vector2i(0, 0)]
	var right: PackedVector3Array = terrain._points[Vector2i(1, 0)]
	var below: PackedVector3Array = terrain._points[Vector2i(0, 1)]
	for i in n:
		if left[n - 1 + i * n] != right[i * n] or left[i + (n - 1) * n] != below[i]:
			return false
	return true


## What was really built for this chunk, from its mesh and not from a fresh calculation.
func _built_mesh_arrays(terrain: Terrain, key: Vector2i) -> Array:
	var mesh_node: MeshInstance3D = terrain._mesh_nodes[key]
	return mesh_node.mesh.surface_get_arrays(0)


func _border_normals_match(terrain: Terrain, n: int) -> bool:
	var left: PackedVector3Array = _built_mesh_arrays(terrain, Vector2i(0, 0))[Mesh.ARRAY_NORMAL]
	var right: PackedVector3Array = _built_mesh_arrays(terrain, Vector2i(1, 0))[Mesh.ARRAY_NORMAL]
	var below: PackedVector3Array = _built_mesh_arrays(terrain, Vector2i(0, 1))[Mesh.ARRAY_NORMAL]
	if left.size() != n * n:
		return false
	for i in n:
		if not left[n - 1 + i * n].is_equal_approx(right[i * n]):
			return false
		if not left[i + (n - 1) * n].is_equal_approx(below[i]):
			return false
	return true


func _collision_matches_heights(terrain: Terrain) -> bool:
	for z in range(-30, 60, 7):
		for x in range(-30, 60, 7):
			var hit := _ray_down(terrain, Vector3(x + 0.31, 100.0, z + 0.47))
			if hit.is_empty() or absf(hit.position.y - terrain.height_at(x + 0.31, z + 0.47)) > 0.01:
				return false
	return true


## One number that changes if any point's position changes at all, for comparing two systems by eye.
func _fingerprint(terrain: Terrain) -> int:
	return hash(terrain._points[Vector2i.ZERO])


func _ray_down(terrain: Node3D, from: Vector3) -> Dictionary:
	var query := PhysicsRayQueryParameters3D.create(from, from + Vector3.DOWN * 300.0)
	return terrain.get_world_3d().direct_space_state.intersect_ray(query)


func _physics_frames(count: int) -> void:
	for i in count:
		await get_tree().physics_frame


func _tick_nav_until_idle() -> void:
	for i in 2000:
		NavServer.tick(1.0 / 60.0)
		if i > 2 and NavServer.is_idle():
			return
		OS.delay_msec(2)
	_check(false, "nav became idle within the time limit")


func _path_length(points: PackedVector3Array) -> float:
	var total := 0.0
	for i in range(1, points.size()):
		total += points[i - 1].distance_to(points[i])
	return total


func _check(passed: bool, what: String) -> void:
	print("  %s %s" % ["ok  " if passed else "FAIL", what])
	if not passed:
		_failures += 1
