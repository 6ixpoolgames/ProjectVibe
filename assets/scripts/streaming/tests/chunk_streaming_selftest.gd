## Written by Claude (claude-opus-5-5), 2026-11-06: headless self-test for chunk streaming: Terrain's one-chunk
## functions, ChunkStreamer, StreamingSource, and StreamingSamplePawn walking around. Nav is in nav_stitching_selftest.
## Exits 0 on success, 1 on failure. Run from the project folder:
##   "C:\Git\Test 2\Godot_v4.7.2-stable_win64_console.exe" --headless --path . "res://assets/scripts/streaming/tests/chunk_streaming_selftest.tscn"
extends Node


## An example terrain with exactly one marker per chunk, so counts are easy to check.
class OneMarkerTerrain extends Terrain:
	func _make_chunk_markers(key: Vector2i) -> Array[NavMarker]:
		var marker := NavPoint.new()
		marker.tag = &"point.cover"
		marker.position = _point_at(key.x * chunk_resolution, key.y * chunk_resolution)
		var markers: Array[NavMarker] = [marker]
		return markers


var _failures := 0


func _ready() -> void:
	print("--- Chunk streaming self-test ---")
	Engine.max_fps = 60 # so a frame is about as long as a real one, and budgets mean what they would in a game
	NavWorld.report_quiet_seconds = 1000000.0
	await _test_terrain_starts_empty()
	_test_chunk_of()
	_test_steps_match_generate()
	_test_half_built_chunks()
	await _test_collision_and_unload()
	_test_markers_load_and_unload()
	_test_edits()
	_test_outside_the_scene()
	await _test_no_meshes()
	await _test_source_rules()
	_test_network_rules()
	await _test_ground_guarantee()
	await _test_loads_what_is_near()
	await _test_moving_source()
	await _test_margin_stops_reloading()
	await _test_two_sources()
	await _test_no_active_sources()
	await _test_chunk_limit()
	await _test_missing_and_freed_terrain()
	await _test_budget()
	await _test_turning_back_mid_build()
	await _test_markers_follow_the_source()
	await _test_pawn_walks()
	await _test_ai_pawn_rules()
	NavWorld.report_quiet_seconds = 2.0
	NavWorld.reset()
	print("--- ALL PASSED ---" if _failures == 0 else "--- %d FAILED ---" % _failures)
	get_tree().quit(0 if _failures == 0 else 1)


# --- The terrain's one-chunk functions ---


func _test_terrain_starts_empty() -> void:
	var terrain := _make_terrain()
	_check(terrain.get_loaded_chunks().is_empty(), "with build_on_start off, a terrain starts with no chunks")
	_check(not terrain.has_chunk(Vector2i.ZERO), "and has_chunk agrees")
	_check(is_equal_approx(terrain.height_at(5.0, 5.0), 0.0), "and height_at gives the node's own height where nothing is built")
	await get_tree().process_frame
	_check(terrain.get_loaded_chunks().is_empty(), "and nothing builds by itself")
	terrain.free()

	var fixed := Terrain.new()
	fixed.chunk_resolution = 4
	fixed.chunk_size = 20.0
	fixed.chunk_radius = 1
	fixed.build_collision = false
	add_child(fixed)
	_check(fixed.get_loaded_chunks().size() == 9, "with it on, the default, the block builds as before (%d chunks)" % fixed.get_loaded_chunks().size())
	fixed.free()


func _test_chunk_of() -> void:
	var terrain := _make_terrain()
	_check(terrain.chunk_of(Vector3(1.0, 0.0, 1.0)) == Vector2i(0, 0), "chunk_of: a point in the first chunk")
	_check(terrain.chunk_of(Vector3(-0.5, 0.0, 33.0)) == Vector2i(-1, 1), "chunk_of: negative positions round down, not toward zero")
	terrain.position = Vector3(100.0, 0.0, 0.0)
	_check(terrain.chunk_of(Vector3(101.0, 0.0, 1.0)) == Vector2i(0, 0), "chunk_of follows the node")
	terrain.free()


func _test_steps_match_generate() -> void:
	for smooth in [false, true]:
		var block := Terrain.new()
		block.chunk_size = 64.0
		block.chunk_resolution = 16
		block.chunk_radius = 1
		block.smooth_shading = smooth
		block.build_collision = false
		add_child(block)

		var stepped := _make_terrain()
		stepped.chunk_size = 64.0
		stepped.chunk_resolution = 16
		stepped.smooth_shading = smooth
		var steps := 0
		while not stepped.build_chunk_step(Vector2i(1, -1)):
			steps += 1
		var key := Vector2i(1, -1)
		_check(steps >= 3, "smooth=%s: a chunk takes several steps (%d)" % [smooth, steps + 1])
		_check(stepped._points[key] == block._points[key], "smooth=%s: its points match a generated chunk" % smooth)
		var ours: Array = stepped._mesh_nodes[key].mesh.surface_get_arrays(0)
		var theirs: Array = block._mesh_nodes[key].mesh.surface_get_arrays(0)
		_check(ours[Mesh.ARRAY_VERTEX] == theirs[Mesh.ARRAY_VERTEX] and ours[Mesh.ARRAY_NORMAL] == theirs[Mesh.ARRAY_NORMAL] and ours[Mesh.ARRAY_TEX_UV] == theirs[Mesh.ARRAY_TEX_UV] and ours[Mesh.ARRAY_INDEX] == theirs[Mesh.ARRAY_INDEX], "smooth=%s: and so does its mesh" % smooth)
		_check(stepped.build_chunk_step(key), "smooth=%s: stepping a finished chunk does nothing and says it's finished" % smooth)

		# Chunks built in any order must meet exactly, or there'd be cracks.
		stepped.load_chunk(Vector2i(0, -1))
		var left: PackedVector3Array = stepped._points[Vector2i(0, -1)]
		var right: PackedVector3Array = stepped._points[Vector2i(1, -1)]
		var meets := true
		for row in 17:
			meets = meets and left[16 + row * 17] == right[row * 17]
		_check(meets, "smooth=%s: neighbours built separately share their border exactly" % smooth)
		block.free()
		stepped.free()


func _test_half_built_chunks() -> void:
	var terrain := _make_terrain()
	terrain.chunk_size = 256.0
	terrain.chunk_resolution = 43
	var key := Vector2i.ZERO
	terrain.build_chunk_step(key)
	_check(not terrain.has_chunk(key), "a half-built chunk isn't reported as loaded")
	_check(terrain.get_loaded_chunks().is_empty(), "and isn't in the list")
	_check(terrain._ground_at(10.0, 10.0) == Terrain.NO_GROUND, "and height_at can't read its half-finished points")
	terrain.unload_chunk(key)
	_check(not terrain._building.has(key), "unloading a half-built chunk drops it")
	terrain.load_chunk(key)
	_check(terrain.has_chunk(key), "and it can be built again from the start")
	terrain.unload_chunk(Vector2i(50, 50))
	_check(terrain.has_chunk(key), "unloading a chunk that isn't there does nothing")
	terrain.free()


func _test_collision_and_unload() -> void:
	var terrain := _make_terrain()
	terrain.build_collision = true
	var key := Vector2i(1, 2)
	terrain.load_chunk(key)
	var point := Vector3(45.0, 100.0, 75.0)
	await _physics_frames(3)
	var hit := _ray_down(terrain, point)
	_check(not hit.is_empty() and absf(hit.position.y - terrain.height_at(point.x, point.z)) < 0.01, "a loaded chunk is solid, at the same height as height_at")
	var points_before: PackedVector3Array = terrain._points[key].duplicate()

	var nodes_before := terrain.get_child_count()
	terrain.unload_chunk(key)
	_check(terrain.get_child_count() == nodes_before - 2, "unloading removes its mesh and body")
	_check(not terrain.has_chunk(key) and terrain._points.is_empty() and terrain._mesh_nodes.is_empty() and terrain._collision_nodes.is_empty(), "and everything stored for it")
	await _physics_frames(3)
	_check(_ray_down(terrain, point).is_empty(), "and it's no longer solid")

	terrain.load_chunk(key)
	_check(terrain._points[key] == points_before, "loading it again gives exactly the same ground")
	await _physics_frames(3)
	_check(not _ray_down(terrain, point).is_empty(), "and it's solid again")
	terrain.free()


func _test_markers_load_and_unload() -> void:
	NavWorld.reset()
	var terrain := OneMarkerTerrain.new()
	terrain.name = "MarkerTerrain"
	terrain.build_on_start = false
	terrain.chunk_resolution = 4
	terrain.chunk_size = 32.0
	terrain.build_collision = false
	add_child(terrain)
	terrain.load_chunk(Vector2i(0, 0))
	terrain.load_chunk(Vector2i(1, 0))
	NavWorld.flush()
	_check(NavWorld.get_marker_count() == 2, "each loaded chunk announces its markers (%d)" % NavWorld.get_marker_count())
	var id := NavWorld.chunk_marker_id(terrain._terrain_id, Vector2i(1, 0), 0)
	_check(NavWorld.get_marker(id) != null, "with the id that chunk's position gives")
	terrain.unload_chunk(Vector2i(1, 0))
	NavWorld.flush()
	_check(NavWorld.get_marker_count() == 1 and NavWorld.get_marker(id) == null, "unloading releases them")
	terrain.load_chunk(Vector2i(1, 0))
	NavWorld.flush()
	_check(NavWorld.get_marker(id) != null, "and loading again brings back the same id")
	terrain.free()
	NavWorld.flush()
	_check(NavWorld.get_marker_count() == 0, "and freeing the terrain releases them all")


func _test_edits() -> void:
	var terrain := _make_terrain()
	var key := Vector2i.ZERO
	terrain.load_chunk(key)
	var before := terrain.height_at(16.0, 16.0)
	# Radius 24 means full strength out to 12 m, which covers the corners of the triangle at this point on an 8 m grid.
	terrain.edit(Vector3(16.0, 0.0, 16.0), 24.0, 5.0)
	_check(absf(terrain.height_at(16.0, 16.0) - before - 5.0) < 0.01, "edit works on a chunk loaded by itself")
	terrain.unload_chunk(key)
	_check(terrain._warned_about_lost_edits, "unloading an edited chunk warns that the edit is lost")
	terrain.load_chunk(key)
	_check(is_equal_approx(terrain.height_at(16.0, 16.0), before), "and it comes back unedited, the known limit until edits are saved")
	terrain.free()

	# An edit landing on a half-built chunk must not be overwritten by the mesh it had already started.
	var half := _make_terrain()
	half.chunk_size = 256.0
	half.chunk_resolution = 43
	half.load_chunk(Vector2i(-1, 0))
	while half._building.is_empty() or half._building[Vector2i.ZERO].stage != Terrain.Stage.MESH_ROWS:
		half.build_chunk_step(Vector2i.ZERO)
	half.edit(Vector3(100.0, 0.0, 100.0), 40.0, 9.0)
	_check(half.has_chunk(Vector2i.ZERO), "an edit finishes half-built chunks first")
	var vertices: PackedVector3Array = half._mesh_nodes[Vector2i.ZERO].mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	var triangles := half._chunk_triangles(Vector2i.ZERO)
	var same := vertices.size() == triangles.size()
	for i in range(0, vertices.size(), 37):
		same = same and vertices[i].is_equal_approx(triangles[i])
	_check(same, "and the mesh has the edit")
	half.free()


func _test_outside_the_scene() -> void:
	var terrain := Terrain.new()
	terrain.chunk_resolution = 4
	terrain.chunk_size = 20.0
	terrain.build_on_start = false
	terrain.load_chunk(Vector2i.ZERO)
	_check(terrain.has_chunk(Vector2i.ZERO), "a chunk can load before the terrain is in a scene")
	terrain.unload_chunk(Vector2i.ZERO)
	terrain.free()

	var moving := _make_terrain()
	moving.load_chunk(Vector2i.ZERO)
	remove_child(moving)
	add_child(moving)
	_check(moving.has_chunk(Vector2i.ZERO), "a loaded chunk survives leaving the scene and coming back")
	moving.free()


# Claude 2026-11-07: for a machine nobody looks at, such as a dedicated server.
func _test_no_meshes() -> void:
	var terrain := _make_terrain()
	terrain.chunk_size = 64.0
	terrain.chunk_resolution = 16
	terrain.build_meshes = false
	terrain.build_collision = true
	var steps := 1
	while not terrain.build_chunk_step(Vector2i.ZERO):
		steps += 1
	_check(terrain.has_chunk(Vector2i.ZERO), "with build_meshes off, a chunk still loads")
	_check(terrain._mesh_nodes.is_empty(), "with no mesh")
	_check(terrain.get_loaded_chunks().size() == 1, "and it's listed as loaded")
	var point := Vector3(32.0, 100.0, 32.0)
	await _physics_frames(3)
	var hit := _ray_down(terrain, point)
	_check(not hit.is_empty() and absf(hit.position.y - terrain.height_at(point.x, point.z)) < 0.01, "and it's solid at the right height")
	terrain.edit(Vector3(32.0, 0.0, 32.0), 20.0, 3.0)
	_check(terrain._mesh_nodes.is_empty(), "an edit doesn't make a mesh either")
	terrain.generate()
	_check(terrain._mesh_nodes.is_empty(), "nor does generate")
	var with_meshes := _make_terrain()
	with_meshes.chunk_size = 64.0
	with_meshes.chunk_resolution = 16
	var steps_with_meshes := 1
	while not with_meshes.build_chunk_step(Vector2i.ZERO):
		steps_with_meshes += 1
	_check(steps < steps_with_meshes, "and it takes fewer steps (%d against %d)" % [steps, steps_with_meshes])
	terrain.free()
	with_meshes.free()


# --- The source and the streamer ---


# Claude 2026-11-07: which machines a source counts on. NetworkEntity marks its parent when it's set up, as faked here.
func _test_network_rules() -> void:
	var pawn := Node3D.new()
	add_child(pawn)
	var source := StreamingSource.new()
	pawn.add_child(source)
	_check(source.counts_on_this_machine(), "a source on something not networked counts")

	var entity := NetworkEntity.new()
	pawn.add_child(entity)
	pawn.set_meta(&"network_entity", entity)
	entity.role = NetworkEntity.Role.AUTHORITY
	entity.is_local = false
	_check(source.counts_on_this_machine(), "on the server, it counts on any player's pawn")
	entity.role = NetworkEntity.Role.LOCAL_PREDICTED
	entity.is_local = true
	_check(source.counts_on_this_machine(), "on a client, it counts on your own pawn")
	entity.role = NetworkEntity.Role.LOCAL_UNPREDICTED
	_check(source.counts_on_this_machine(), "including with prediction off")
	entity.role = NetworkEntity.Role.REMOTE_FOLLOWING
	entity.is_local = false
	_check(not source.counts_on_this_machine(), "but not on another player's pawn")
	entity.role = NetworkEntity.Role.REMOTE_PREDICTED
	_check(not source.counts_on_this_machine(), "even if that pawn is predicted")
	entity.role = NetworkEntity.Role.AUTHORITY
	source.active = false
	_check(not source.counts_on_this_machine(), "an inactive source never counts")
	pawn.free()


func _test_source_rules() -> void:
	var source := StreamingSource.new()
	_check(source.is_in_group(StreamingSource.GROUP), "a source joins the group as soon as it's made")
	add_child(source)
	await get_tree().process_frame
	_check(true, "a source with no streamer in the scene does nothing and breaks nothing")
	source.free()


func _test_loads_what_is_near() -> void:
	var terrain := _make_terrain()
	var streamer := _make_streamer(terrain)
	await _frames(3)
	_check(terrain.get_loaded_chunks().is_empty(), "with no sources, nothing loads")

	var inactive := _make_source(Vector3(16.0, 0.0, 16.0), 40.0)
	inactive.active = false
	await _frames(3)
	_check(terrain.get_loaded_chunks().is_empty(), "with an inactive source, nothing loads")

	var order: Array[Vector2i] = []
	streamer.chunk_loaded.connect(func(key: Vector2i) -> void: order.append(key))
	inactive.active = true
	await _until_done(streamer)
	_check(not order.is_empty() and order[0] == Vector2i.ZERO, "turning it on loads the chunk under it first")
	_check(_same_chunks(terrain.get_loaded_chunks(), _chunks_within(terrain, inactive.position, 40.0)), "and exactly the chunks within load_distance (%d)" % terrain.get_loaded_chunks().size())
	var stats := streamer.get_stats()
	_check(stats.queued == 0 and stats.total_loaded == terrain.get_loaded_chunks().size(), "and the numbers agree")
	var before: int = stats.total_loaded
	await _frames(5)
	_check(streamer.get_stats().total_loaded == before, "and nothing more happens while the source stays still")
	inactive.free()
	streamer.free()
	terrain.free()


func _test_moving_source() -> void:
	var terrain := _make_terrain()
	var streamer := _make_streamer(terrain)
	var source := _make_source(Vector3(16.0, 0.0, 16.0), 40.0)
	await _until_done(streamer)
	var count := terrain.get_loaded_chunks().size()
	source.position = Vector3(16.0 + 320.0, 0.0, 16.0)
	await _until_done(streamer)
	_check(terrain.has_chunk(Vector2i(10, 0)), "moving a source loads chunks around its new position")
	_check(not terrain.has_chunk(Vector2i.ZERO), "and unloads the ones far behind it")
	_check(terrain.get_loaded_chunks().size() == count, "and the count stays the same (%d)" % count)
	source.free()
	streamer.free()
	terrain.free()


func _test_margin_stops_reloading() -> void:
	var terrain := _make_terrain()
	var streamer := _make_streamer(terrain)
	streamer.unload_margin = 32.0
	var source := _make_source(Vector3(16.0, 0.0, 16.0), 16.0)
	await _until_done(streamer)
	var stats := streamer.get_stats()
	# Moving 20 m takes the far chunks past load_distance but not past the margin, so they stay.
	for i in 6:
		source.position.x = 36.0 if i % 2 == 0 else 16.0
		await _until_done(streamer)
	var after := streamer.get_stats()
	_check(after.total_unloaded == stats.total_unloaded, "going back and forth inside the margin unloads nothing (%d)" % after.total_unloaded)
	var extra_loads: int = after.total_loaded - stats.total_loaded
	_check(extra_loads <= 3, "and doesn't keep rebuilding (%d extra loads in 6 moves)" % extra_loads)
	source.free()
	streamer.free()
	terrain.free()


func _test_two_sources() -> void:
	var terrain := _make_terrain()
	var streamer := _make_streamer(terrain)
	var first := _make_source(Vector3(16.0, 0.0, 16.0), 8.0)
	var second := _make_source(Vector3(1000.0, 0.0, 1000.0), 8.0)
	await _until_done(streamer)
	_check(terrain.has_chunk(terrain.chunk_of(first.position)) and terrain.has_chunk(terrain.chunk_of(second.position)), "two sources far apart both get their chunks")
	var far_chunk := terrain.chunk_of(second.position)
	second.free()
	await _until_done(streamer)
	_check(not terrain.has_chunk(far_chunk) and terrain.has_chunk(terrain.chunk_of(first.position)), "a freed source stops counting, and the other's chunks stay")
	first.free()
	streamer.free()
	terrain.free()


func _test_no_active_sources() -> void:
	var terrain := _make_terrain()
	var streamer := _make_streamer(terrain)
	var source := _make_source(Vector3(16.0, 0.0, 16.0), 8.0)
	await _until_done(streamer)
	var count := terrain.get_loaded_chunks().size()
	source.active = false
	await _frames(4)
	_check(count > 0 and terrain.get_loaded_chunks().size() == count, "with hold_when_no_sources, chunks stay when every source goes inactive")
	streamer.hold_when_no_sources = false
	await _until_done(streamer)
	_check(terrain.get_loaded_chunks().is_empty(), "with it off, they all unload")
	source.free()
	streamer.free()
	terrain.free()


func _test_chunk_limit() -> void:
	var terrain := _make_terrain()
	var streamer := _make_streamer(terrain)
	streamer.max_chunks_per_source = 9
	var source := _make_source(Vector3(16.0, 0.0, 16.0), 200.0)
	await _until_done(streamer)
	_check(terrain.get_loaded_chunks().size() == 9, "max_chunks_per_source is respected (%d)" % terrain.get_loaded_chunks().size())
	_check(terrain.has_chunk(Vector2i.ZERO), "and the nearest chunks win")
	_check(streamer._warned_too_many, "and it warns")
	# Claude 2026-11-07: the limit grows with the number of sources, so a server can hold every player's area.
	var second := _make_source(Vector3(5000.0, 0.0, 5000.0), 200.0)
	await _until_done(streamer)
	_check(terrain.get_loaded_chunks().size() == 18, "with a second source, the limit doubles (%d)" % terrain.get_loaded_chunks().size())
	_check(terrain.has_chunk(terrain.chunk_of(second.position)) and terrain.has_chunk(Vector2i.ZERO), "and both sources have the chunk under them")
	second.free()
	source.free()

	# A huge distance on tiny chunks must not freeze the game while it counts them.
	var tiny := _make_source(Vector3.ZERO, 1000000.0)
	terrain.chunk_size = 0.5
	var started := Time.get_ticks_msec()
	streamer.refresh_now()
	_check(Time.get_ticks_msec() - started < 200, "a huge load_distance doesn't freeze the refresh (%d ms)" % (Time.get_ticks_msec() - started))
	tiny.free()
	streamer.free()
	terrain.free()


func _test_missing_and_freed_terrain() -> void:
	var streamer := ChunkStreamer.new()
	add_child(streamer)
	await _frames(2)
	_check(streamer._warned_no_terrain, "no terrain: it warns and does nothing")
	streamer.free()

	var terrain := _make_terrain()
	var child := ChunkStreamer.new()
	terrain.add_child(child)
	await get_tree().process_frame
	_check(child.terrain == terrain, "with no terrain set, it uses its parent if that's a terrain")
	child.free()

	var streamer_2 := _make_streamer(terrain)
	var source := _make_source(Vector3(16.0, 0.0, 16.0), 8.0)
	await _frames(2)
	terrain.free()
	await _frames(3)
	_check(true, "the terrain being freed mid-run breaks nothing")
	source.free()
	streamer_2.free()


# The chunk under a source is built straight away, so these watch its neighbour, which comes through the budget.
func _test_budget() -> void:
	var neighbour := Vector2i(1, 0)
	var terrain := _make_budget_terrain()
	var streamer := _make_streamer(terrain)
	streamer.max_ms_per_frame = 0.0
	var source := _make_source(Vector3(128.0, 0.0, 128.0), 140.0)
	await _physics_frames(2) # the signal fires before this frame's nodes run, so the first one is too early
	_check(terrain.has_chunk(Vector2i.ZERO) and not terrain.has_chunk(neighbour), "(the chunk under the source is there at once, and its neighbour isn't)")
	streamer.reset_worst_times()
	var frames := 0
	while not terrain.has_chunk(neighbour) and frames < 400:
		await get_tree().process_frame
		frames += 1
	_check(frames >= 8, "with no budget, one step still runs each frame, so a chunk does load (%d frames)" % frames)
	var worst: float = streamer.get_stats().worst_frame_ms
	_check(worst < 12.0, "and the worst frame is one step, not a whole chunk (%.2f ms, was about 10.7 before)" % worst)
	var at_normal_speed: float = streamer.get_stats().worst_step_ms
	source.free()
	streamer.free()
	terrain.free()

	# Now with plenty of budget: several steps a frame.
	terrain = _make_budget_terrain()
	streamer = _make_streamer(terrain)
	streamer.max_ms_per_frame = 100.0
	source = _make_source(Vector3(128.0, 0.0, 128.0), 140.0)
	await get_tree().physics_frame
	frames = 0
	while not terrain.has_chunk(neighbour) and frames < 200:
		await get_tree().process_frame
		frames += 1
	_check(frames <= 3, "with plenty of budget, a chunk loads almost at once (%d frames)" % frames)
	source.free()
	streamer.free()
	terrain.free()

	# Pretending to be a slower CPU makes the steps slower, and the chunk takes more frames with the same budget.
	terrain = _make_budget_terrain()
	streamer = _make_streamer(terrain)
	streamer.simulate_slower_cpu = 3.0
	streamer.max_ms_per_frame = 2.0
	source = _make_source(Vector3(128.0, 0.0, 128.0), 140.0)
	await get_tree().physics_frame
	streamer.reset_worst_times()
	frames = 0
	while not terrain.has_chunk(neighbour) and frames < 400:
		await get_tree().process_frame
		frames += 1
	var slowed: float = streamer.get_stats().worst_step_ms
	_check(slowed > at_normal_speed * 1.5, "simulate_slower_cpu makes steps slower (%.2f ms against %.2f ms)" % [slowed, at_normal_speed])
	_check(terrain.has_chunk(neighbour), "and the chunk still arrives (%d frames)" % frames)
	source.free()
	streamer.free()
	terrain.free()


func _test_turning_back_mid_build() -> void:
	var neighbour := Vector2i(1, 0)
	var terrain := _make_budget_terrain()
	var streamer := _make_streamer(terrain)
	streamer.max_ms_per_frame = 0.0
	var source := _make_source(Vector3(128.0, 0.0, 128.0), 140.0)
	await get_tree().physics_frame
	await _frames(3)
	_check(streamer._has_current_build, "(a chunk is partly built)")
	var building := streamer._current_build
	source.position = Vector3(128.0 + 2560.0, 0.0, 128.0)
	await _until_done(streamer)
	_check(not terrain.has_chunk(building) and not terrain._building.has(building), "when its source leaves, a half-built chunk is dropped")
	_check(terrain.has_chunk(Vector2i(10, 0)), "and the new one is built")
	_check(not terrain.has_chunk(neighbour), "(and the old neighbour is gone)")
	source.free()
	streamer.free()
	terrain.free()


func _make_budget_terrain() -> Terrain:
	var terrain := _make_terrain()
	terrain.chunk_size = 256.0
	terrain.chunk_resolution = 43
	terrain.build_collision = true
	return terrain


func _test_markers_follow_the_source() -> void:
	NavWorld.reset()
	var terrain := OneMarkerTerrain.new()
	terrain.name = "FollowTerrain"
	terrain.build_on_start = false
	terrain.chunk_resolution = 4
	terrain.chunk_size = 32.0
	terrain.build_collision = false
	add_child(terrain)
	var streamer := _make_streamer(terrain)
	var source := _make_source(Vector3(16.0, 0.0, 16.0), 8.0)
	await _until_done(streamer)
	NavWorld.flush()
	_check(NavWorld.get_marker_count() == terrain.get_loaded_chunks().size(), "one marker per streamed chunk (%d)" % NavWorld.get_marker_count())
	source.position = Vector3(500.0, 0.0, 500.0)
	await _until_done(streamer)
	NavWorld.flush()
	_check(NavWorld.get_marker_count() == terrain.get_loaded_chunks().size(), "and they follow when the source moves (%d)" % NavWorld.get_marker_count())
	source.free()
	streamer.free()
	terrain.free()
	NavWorld.flush()


# --- The ground guarantee ---


## Runs after the streamer and before anything else in a physics frame's own work: says what a pawn would find this frame.
class GroundProbe extends Node:
	var terrain: Terrain
	var spot := Vector3.ZERO
	var frames := 0
	var first_chunk_frame := -1
	var first_solid_frame := -1

	func _init() -> void:
		process_physics_priority = 1000

	func _physics_process(_delta: float) -> void:
		frames += 1
		if first_chunk_frame < 0 and terrain.has_chunk(terrain.chunk_of(spot)):
			first_chunk_frame = frames
		if first_solid_frame < 0:
			var query := PhysicsRayQueryParameters3D.create(spot + Vector3.UP * 100.0, spot + Vector3.DOWN * 100.0)
			if not terrain.get_world_3d().direct_space_state.intersect_ray(query).is_empty():
				first_solid_frame = frames


func _test_ground_guarantee() -> void:
	var terrain := _make_terrain()
	terrain.chunk_size = 128.0
	terrain.chunk_resolution = 21
	terrain.build_collision = true
	var streamer := _make_streamer(terrain)
	streamer.max_ms_per_frame = 0.0 # the budget can't be what builds it
	streamer.refresh_seconds = 1000.0 # nor the refresh
	streamer.refresh_now()
	var probe := GroundProbe.new()
	probe.terrain = terrain
	probe.spot = Vector3(5000.0, 0.0, 5000.0)
	add_child(probe)
	var source := _make_source(probe.spot, 64.0)
	probe.frames = 0
	probe.first_chunk_frame = -1
	probe.first_solid_frame = -1
	await _physics_frames(6)
	_check(probe.first_chunk_frame == 1, "a new source has its chunk in the same physics frame (frame %d), with no budget and no refresh" % probe.first_chunk_frame)
	_check(probe.first_solid_frame == 1, "and it's solid in that same frame, so a first tick finds it (frame %d)" % probe.first_solid_frame)
	_check(streamer.get_stats().urgent_builds == 1 or streamer.get_stats().urgent_builds == 4, "(built %d immediately)" % streamer.get_stats().urgent_builds)

	# A teleport, and then moving fast past chunk edges, in straight lines far faster than any pawn.
	var missing := 0
	var at := Vector3(-20000.0, 0.0, 300.0)
	source.position = at
	for i in 240:
		at += Vector3(40.0, 0.0, 13.0) # 2,500 m/s at 60 frames a second
		source.position = at
		await get_tree().physics_frame
		await get_tree().physics_frame
		if not terrain.has_chunk(terrain.chunk_of(at)):
			missing += 1
	_check(missing == 0, "moving far faster than any pawn, past chunk edges, it's never missing (%d times)" % missing)
	probe.free()
	source.free()
	streamer.free()
	terrain.free()


# --- A pawn walking around ---


func _test_pawn_walks() -> void:
	var terrain := _make_terrain()
	terrain.chunk_size = 64.0
	terrain.chunk_resolution = 11
	terrain.build_collision = true
	var streamer := _make_streamer(terrain)
	streamer.unload_margin = 32.0
	var pawn := _make_pawn(terrain, Vector3(5.0, 40.0, 5.0))
	pawn.speed = 25.0
	pawn.source.load_distance = 96.0
	pawn.set_route(PackedVector3Array([Vector3(300.0, 0.0, 120.0), Vector3(5.0, 0.0, 5.0)]))
	var height_at_start := 0.0
	var ground_was_missing := 0
	var most_chunks := 0
	var least_chunks := 100000
	var visited := {}
	var frames := 0
	var first_ground := false
	# Walking there and back is 2 x 323 m, about 26 s, so a limit of 40 s of frames is only hit if it gets stuck.
	while not pawn.finished_route and frames < 2400:
		await get_tree().physics_frame
		frames += 1
		var under := terrain.chunk_of(pawn.global_position)
		if terrain.has_chunk(under):
			if not first_ground:
				first_ground = true
				height_at_start = terrain.height_at(5.0, 5.0)
				await _until_done(streamer) # let the area around the start finish before counting
				streamer.reset_worst_times()
			visited[under] = true
		elif first_ground:
			ground_was_missing += 1
		if first_ground and streamer.get_stats().queued == 0:
			var count := terrain.get_loaded_chunks().size()
			most_chunks = maxi(most_chunks, count)
			least_chunks = mini(least_chunks, count)
	_check(pawn.finished_route, "the pawn walks its route (%.0f m in %d ticks)" % [pawn.distance_walked, frames])
	_check(pawn.distance_walked > 600.0, "and covers the whole distance")
	_check(visited.size() >= 5, "across many chunks (%d)" % visited.size())
	_check(ground_was_missing == 0, "and the ground under it was always built")
	_check(pawn.worst_below_ground < 0.5, "and it never went through the ground (worst %.2f m)" % pawn.worst_below_ground)
	_check(most_chunks <= least_chunks + 12, "and the number of chunks stays steady (%d to %d)" % [least_chunks, most_chunks])
	_check(streamer.get_stats().total_unloaded > 0, "and chunks behind it unload (%d)" % streamer.get_stats().total_unloaded)
	await _until_done(streamer)
	_check(is_equal_approx(terrain.height_at(5.0, 5.0), height_at_start), "and back at the start, the ground is the same")
	print("        worst frame %.2f ms, worst step %.2f ms, %d loads" % [streamer.get_stats().worst_frame_ms, streamer.get_stats().worst_step_ms, streamer.get_stats().total_loaded])
	pawn.free()
	streamer.free()
	terrain.free()


func _test_ai_pawn_rules() -> void:
	var terrain := _make_terrain()
	terrain.build_collision = true
	var streamer := _make_streamer(terrain)

	var player := _make_pawn(terrain, Vector3(16.0, 30.0, 16.0))
	_check(player.source.active, "a player pawn keeps the world loaded by default")
	player.is_player_controlled = false
	_check(not player.source.active, "an AI pawn doesn't by default")
	player.ai_loads_chunks = true
	_check(player.source.active, "unless its bool is on")
	player.ai_loads_chunks = false

	await _frames(5)
	await _physics_frames(10)
	_check(terrain.get_loaded_chunks().is_empty(), "an AI pawn alone with the bool off loads nothing")
	_check(not GameMode.ai_activity.is_active(player), "and it's switched off, so it doesn't fall")
	_check(player.global_position.y > 29.9, "(it's still at %.1f m)" % player.global_position.y)
	player.ai_loads_chunks = true
	await _until_done(streamer)
	await _physics_frames(30)
	_check(terrain.has_chunk(Vector2i.ZERO), "with the bool on, it loads chunks")
	_check(GameMode.ai_activity.is_active(player), "and it's back on")
	_check(player.global_position.y < 29.0, "and now it falls to the ground")

	# Taking over a pawn: the rule follows who controls it.
	player.ai_loads_chunks = false
	player.is_player_controlled = true
	_check(player.source.active, "a player taking over turns its source on")

	# An AI pawn with the bool off walks to the edge of what others have loaded, and goes off there.
	player.source.load_distance = 8.0
	streamer.unload_margin = 0.0
	await _until_done(streamer)
	var walker := _make_pawn(terrain, Vector3(16.0, terrain.height_at(16.0, 16.0) + 1.0, 16.0))
	walker.is_player_controlled = false
	walker.speed = 6.0
	walker.set_route(PackedVector3Array([Vector3(400.0, 0.0, 16.0)]))
	await _physics_frames(240)
	_check(not GameMode.ai_activity.is_active(walker), "an AI pawn with the bool off goes off at the edge of the loaded ground")
	_check(walker.ticks_without_ground == 0, "before it ever stands over nothing (%d ticks)" % walker.ticks_without_ground)
	_check(walker.worst_below_ground < 0.5, "and it hasn't dropped through")
	var stopped_at := walker.global_position

	await _physics_frames(30)
	_check(walker.global_position == stopped_at, "and it stays exactly where it is while off")

	# A player arrives, so ground comes back and the pawn carries on from where it was.
	player.global_position = stopped_at + Vector3(0.0, 3.0, 4.0) # beside it, so it doesn't land on it
	await _physics_frames(30)
	_check(GameMode.ai_activity.is_active(walker), "when a player's source brings the ground back, it comes back on")
	await _physics_frames(30)
	_check(walker.global_position.x > stopped_at.x + 1.0, "and carries on walking (%.1f m further)" % (walker.global_position.x - stopped_at.x))
	walker.free()
	player.free()
	streamer.free()
	terrain.free()


# --- Helpers ---


## A small, quick streamed terrain with no collision unless a test turns it on.
func _make_terrain() -> Terrain:
	var terrain := Terrain.new()
	terrain.name = "Terrain"
	terrain.build_on_start = false
	terrain.chunk_resolution = 4
	terrain.chunk_size = 32.0
	terrain.build_collision = false
	add_child(terrain)
	return terrain


func _make_streamer(terrain: Terrain) -> SlowChunkStreamer: # Claude 2026-11-07: the test version, which can reset its timings
	var streamer := SlowChunkStreamer.new()
	streamer.terrain = terrain
	streamer.refresh_seconds = 0.0 # every frame, so tests don't have to wait
	add_child(streamer)
	return streamer


func _make_source(at: Vector3, load_distance: float) -> StreamingSource:
	var source := StreamingSource.new()
	source.load_distance = load_distance
	source.position = at
	add_child(source)
	return source


func _make_pawn(terrain: Terrain, at: Vector3) -> StreamingSamplePawn:
	var pawn := StreamingSamplePawn.new()
	pawn.terrain = terrain
	pawn.position = at
	add_child(pawn)
	return pawn


## Every chunk within a distance of a position, worked out the slow, obvious way to compare against the streamer.
func _chunks_within(terrain: Terrain, at: Vector3, distance: float) -> Array[Vector2i]:
	var chunks: Array[Vector2i] = []
	var size := terrain.chunk_size
	for z in range(-20, 21):
		for x in range(-20, 21):
			var away := Vector2(maxf(maxf(x * size - at.x, 0.0), at.x - (x + 1) * size), maxf(maxf(z * size - at.z, 0.0), at.z - (z + 1) * size))
			if away.length() <= distance:
				chunks.append(Vector2i(x, z))
	return chunks


func _same_chunks(a: Array[Vector2i], b: Array[Vector2i]) -> bool:
	if a.size() != b.size():
		return false
	for key in a:
		if not b.has(key):
			return false
	return true


## Waits until the streamer has seen where the sources are now and has nothing left to do.
func _until_done(streamer: ChunkStreamer) -> void:
	await get_tree().process_frame
	await get_tree().process_frame
	for i in 3000:
		var stats := streamer.get_stats()
		if stats.queued == 0 and stats.unload_queued == 0:
			return
		await get_tree().process_frame
	_check(false, "the streamer finished within the time limit")


func _frames(count: int) -> void:
	for i in count:
		await get_tree().process_frame


func _physics_frames(count: int) -> void:
	for i in count:
		await get_tree().physics_frame


func _ray_down(terrain: Node3D, from: Vector3) -> Dictionary:
	var query := PhysicsRayQueryParameters3D.create(from, from + Vector3.DOWN * 300.0)
	return terrain.get_world_3d().direct_space_state.intersect_ray(query)


func _check(passed: bool, what: String) -> void:
	print("  %s %s" % ["ok  " if passed else "FAIL", what])
	if not passed:
		_failures += 1
