## Written by Claude (claude-opus-5-5), 2026-11-07: headless self-test for TerrainEditLog, and for bodies staying above raised ground.
## Exits 0 on success, 1 on failure. Run from the project folder:
##   "C:\Git\Test 2\Godot_v4.7.2-stable_win64_console.exe" --headless --path . "res://assets/scripts/terrain/tests/terrain_edit_selftest.tscn"
extends Node

const KEY_A := Vector2i(0, 0)
const KEY_B := Vector2i(1, 0)
# A patch right on the border between chunks A and B, which are 32 m wide.
const ON_BORDER := Vector3(32.0, 0.0, 16.0)

var _failures := 0


func _ready() -> void:
	print("--- TerrainGenerator edit log self-test ---")
	_test_surviving_an_unload()
	_test_border_with_an_unbuilt_chunk()
	_test_same_result_in_any_order()
	_test_smooth_lighting()
	await _test_no_module()
	await _test_deleted_module()
	await _test_collision_after_reload()
	_test_bytes()
	await _test_from_bytes_rebuilds()
	_test_generate_clears_it()
	await _test_with_streaming()
	await _test_bodies_stay_above()
	_test_long_edit_lists()
	_measure()
	print("--- ALL PASSED ---" if _failures == 0 else "--- %d FAILED ---" % _failures)
	get_tree().quit(0 if _failures == 0 else 1)


func _test_surviving_an_unload() -> void:
	var terrain := _make_terrain()
	var edit_log := _add_log(terrain)
	terrain.load_chunk(KEY_A)
	terrain.edit(Vector3(16.0, 0.0, 16.0), 24.0, 5.0)
	var edited: PackedVector3Array = terrain._points[KEY_A].duplicate()
	_check(edit_log.get_edit_count() == 1, "an edit is recorded")
	terrain.unload_chunk(KEY_A)
	_check(not terrain._warned_about_lost_edits, "unloading doesn't warn, because the edit is safe")
	terrain.load_chunk(KEY_A)
	_check(terrain._points[KEY_A] == edited, "and loading the chunk again gives the edited ground exactly")
	var plain := _make_terrain()
	plain.load_chunk(KEY_A)
	_check(terrain._points[KEY_A] != plain._points[KEY_A], "(which isn't the default ground)")

	# Built in steps, the way ChunkStreamer does it.
	terrain.unload_chunk(KEY_A)
	while not terrain.build_chunk_step(KEY_A):
		pass
	_check(terrain._points[KEY_A] == edited, "and building it in steps gives the same")
	var mesh_vertices: PackedVector3Array = terrain._mesh_nodes[KEY_A].mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	_check(mesh_vertices == terrain._chunk_triangles(KEY_A), "and its mesh has the edit")
	plain.free()
	terrain.free()


func _test_border_with_an_unbuilt_chunk() -> void:
	var terrain := _make_terrain()
	_add_log(terrain)
	terrain.load_chunk(KEY_A)
	terrain.edit(ON_BORDER, 16.0, 6.0)
	terrain.load_chunk(KEY_B)
	_check(_shared_border_matches(terrain), "a neighbour built after an edit on the border matches it exactly, with no step")
	terrain.unload_chunk(KEY_A)
	terrain.load_chunk(KEY_A)
	_check(_shared_border_matches(terrain), "and so does one rebuilt later")

	# A chunk nobody had built yet when the edit landed.
	var far := Vector3(320.0, 0.0, 320.0)
	var far_key := terrain.chunk_of(far)
	terrain.edit(far, 8.0, 5.0)
	terrain.load_chunk(far_key)
	var fresh := _make_terrain()
	fresh.load_chunk(far_key)
	_check(terrain._points[far_key] != fresh._points[far_key], "an edit on a chunk that isn't built is there when it's built")
	fresh.free()
	terrain.free()


func _test_same_result_in_any_order() -> void:
	var edits := [[ON_BORDER, 16.0, 6.0], [Vector3(30.0, 0.0, 20.0), 9.0, -3.0], [Vector3(5.0, 0.0, 5.0), 12.0, 2.0], [Vector3(40.0, 0.0, 30.0), 20.0, 1.5]]
	var everything := _make_terrain()
	_add_log(everything)
	everything.load_chunk(KEY_A)
	everything.load_chunk(KEY_B)
	for one: Array in edits:
		everything.edit(one[0], one[1], one[2])

	var later := _make_terrain()
	_add_log(later)
	for one: Array in edits:
		later.edit(one[0], one[1], one[2])
	later.load_chunk(KEY_B)
	later.load_chunk(KEY_A)
	_check(later._points[KEY_A] == everything._points[KEY_A] and later._points[KEY_B] == everything._points[KEY_B], "chunks built after all the edits exactly match ones that were there for them")

	var between := _make_terrain()
	_add_log(between)
	between.load_chunk(KEY_B)
	between.edit(edits[0][0], edits[0][1], edits[0][2])
	between.edit(edits[1][0], edits[1][1], edits[1][2])
	between.unload_chunk(KEY_B)
	between.load_chunk(KEY_A)
	between.edit(edits[2][0], edits[2][1], edits[2][2])
	between.load_chunk(KEY_B)
	between.edit(edits[3][0], edits[3][1], edits[3][2])
	_check(between._points[KEY_A] == everything._points[KEY_A] and between._points[KEY_B] == everything._points[KEY_B], "and so do chunks coming and going in between")
	everything.free()
	later.free()
	between.free()


func _test_smooth_lighting() -> void:
	var terrain := _make_terrain()
	terrain.smooth_shading = true
	_add_log(terrain)
	terrain.load_chunk(KEY_A)
	terrain.edit(Vector3(33.0, 0.0, 16.0), 6.0, 6.0)
	terrain._rebuild_mesh(KEY_A)
	var alone: Vector3 = terrain._smooth_normal(terrain.chunk_resolution, 2)
	terrain.load_chunk(KEY_B)
	var together: Vector3 = terrain._smooth_normal(terrain.chunk_resolution, 2)
	_check(alone.is_equal_approx(together), "smooth lighting at a border allows for edits on a neighbour that isn't built")
	terrain.free()


func _test_no_module() -> void:
	var terrain := _make_terrain()
	terrain.load_chunk(KEY_A)
	var default_points: PackedVector3Array = terrain._points[KEY_A].duplicate()
	terrain.edit(Vector3(16.0, 0.0, 16.0), 24.0, 5.0)
	_check(terrain._points[KEY_A] != default_points, "with no module, an edit still works")
	terrain.unload_chunk(KEY_A)
	_check(terrain._warned_about_lost_edits, "and unloading warns that it's lost")
	terrain.load_chunk(KEY_A)
	_check(terrain._points[KEY_A] == default_points, "and the ground goes back to default")
	terrain.free()
	await get_tree().process_frame


func _test_deleted_module() -> void:
	var terrain := _make_terrain()
	var edit_log := _add_log(terrain)
	terrain.load_chunk(KEY_A)
	terrain.load_chunk(KEY_B)
	terrain.load_chunk(Vector2i(5, 5))
	var default_a: PackedVector3Array = terrain._points[KEY_A].duplicate()
	var default_b: PackedVector3Array = terrain._points[KEY_B].duplicate()
	var untouched: PackedVector3Array = terrain._points[Vector2i(5, 5)]
	terrain.edit(ON_BORDER, 16.0, 6.0)
	_check(terrain._points[KEY_A] != default_a, "(the ground is edited)")
	edit_log.free()
	await get_tree().process_frame
	terrain.finish_rebuilds()
	_check(terrain._points[KEY_A] == default_a and terrain._points[KEY_B] == default_b, "deleting the module brings back the default ground")
	_check(terrain._points[Vector2i(5, 5)] == untouched, "and leaves other chunks alone")
	var vertices: PackedVector3Array = terrain._mesh_nodes[KEY_A].mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	_check(vertices == terrain._chunk_triangles(KEY_A), "including their meshes")
	terrain.edit(ON_BORDER, 16.0, 6.0)
	_check(terrain._points[KEY_A] != default_a, "and edits still work with no module")
	terrain.free()

	# The terrain leaving the scene isn't the same thing: its edits are still wanted when it comes back.
	var moving := _make_terrain()
	_add_log(moving)
	moving.load_chunk(KEY_A)
	moving.edit(Vector3(16.0, 0.0, 16.0), 24.0, 5.0)
	var edited: PackedVector3Array = moving._points[KEY_A].duplicate()
	remove_child(moving)
	add_child(moving)
	await get_tree().process_frame
	moving.finish_rebuilds()
	_check(moving._points[KEY_A] == edited, "a terrain leaving the scene and coming back keeps its edits")
	moving.free()


func _test_collision_after_reload() -> void:
	var terrain := _make_terrain()
	terrain.build_collision = true
	_add_log(terrain)
	terrain.load_chunk(KEY_A)
	terrain.edit(Vector3(16.0, 0.0, 16.0), 24.0, 8.0)
	terrain.unload_chunk(KEY_A)
	terrain.load_chunk(KEY_A)
	await _physics_frames(3)
	var from := Vector3(16.0, 100.0, 16.0)
	var query := PhysicsRayQueryParameters3D.create(from, from + Vector3.DOWN * 300.0)
	var hit := terrain.get_world_3d().direct_space_state.intersect_ray(query)
	_check(not hit.is_empty() and absf(hit.position.y - terrain.height_at(16.0, 16.0)) < 0.01, "a reloaded chunk's collision has the edit")
	terrain.free()


func _test_bytes() -> void:
	var terrain := _make_terrain()
	var edit_log := _add_log(terrain)
	terrain.edit(ON_BORDER, 16.0, 6.0)
	terrain.edit(Vector3(5.0, 0.0, 5.0), 3.0, -1.0)
	var bytes := edit_log.to_bytes()
	_check(bytes.size() == 9 + 2 * TerrainEditLog.BYTES_PER_EDIT, "an edit takes %d bytes" % TerrainEditLog.BYTES_PER_EDIT)

	var other := _make_terrain()
	var other_log := _add_log(other)
	_check(other_log.from_bytes(bytes), "a log loads from bytes")
	_check(other_log.get_edit_count() == 2, "with its edits")
	terrain.load_chunk(KEY_A)
	other.load_chunk(KEY_A)
	_check(terrain._points[KEY_A] == other._points[KEY_A], "and gives exactly the same ground")

	# One edit by itself, the way the network sends them.
	var third := _make_terrain()
	var third_log := _add_log(third)
	_check(third_log.record_from_bytes(edit_log.edit_as_bytes(0)) == 0 and third_log.record_from_bytes(edit_log.edit_as_bytes(1)) == 1, "edits can arrive one at a time")
	third.load_chunk(KEY_A)
	_check(third._points[KEY_A] == terrain._points[KEY_A], "with the same result")
	_check(third_log.record_from_bytes(PackedByteArray([1, 2, 3])) == -1, "a broken single edit is refused")

	for broken: PackedByteArray in [PackedByteArray(), PackedByteArray([1, 2, 3]), bytes.slice(0, bytes.size() - 1), _with_nonsense_in_it(bytes)]:
		_check(not other_log.from_bytes(broken), "broken data is refused (%d bytes)" % broken.size())
	var wrong_version := bytes.duplicate()
	wrong_version[0] = 200
	_check(not other_log.from_bytes(wrong_version), "so is a different format version")
	_check(other_log.get_edit_count() == 2 or other_log.get_edit_count() == 0, "(the log isn't left half loaded)")

	var different := _make_terrain()
	different.noise_seed = 999
	var different_log := _add_log(different)
	_check(not different_log.from_bytes(bytes), "and so are edits made for different ground")
	_check(different_log.get_edit_count() == 0, "(so the world stays at its default)")
	terrain.free()
	other.free()
	third.free()
	different.free()


func _with_nonsense_in_it(bytes: PackedByteArray) -> PackedByteArray:
	var copy := bytes.duplicate()
	# The first edit's radius, as a negative number.
	copy.encode_float(9 + 8, -5.0)
	return copy


func _test_from_bytes_rebuilds() -> void:
	var source := _make_terrain()
	var source_log := _add_log(source)
	source.edit(ON_BORDER, 16.0, 6.0)
	var late := _make_terrain()
	var late_log := _add_log(late)
	late.load_chunk(KEY_A)
	var before: PackedVector3Array = late._points[KEY_A].duplicate()
	late_log.from_bytes(source_log.to_bytes())
	await get_tree().process_frame
	late.finish_rebuilds()
	_check(late._points[KEY_A] != before, "loading a log changes chunks that are already built, as a late joiner needs")
	source.load_chunk(KEY_A)
	_check(late._points[KEY_A] == source._points[KEY_A], "to exactly the right ground")
	source.free()
	late.free()


func _test_generate_clears_it() -> void:
	var terrain := _make_terrain()
	var edit_log := _add_log(terrain)
	terrain.edit(ON_BORDER, 16.0, 6.0)
	terrain.generate()
	_check(edit_log.get_edit_count() == 0, "generate() starts again from nothing, as it says")
	terrain.free()


func _test_with_streaming() -> void:
	var terrain := _make_terrain()
	_add_log(terrain)
	var streamer := ChunkStreamer.new()
	streamer.terrain = terrain
	streamer.refresh_seconds = 0.0
	streamer.unload_margin = 0.0
	add_child(streamer)
	var source := StreamingSource.new()
	source.load_distance = 8.0
	source.position = Vector3(16.0, 0.0, 16.0)
	add_child(source)
	await _until_done(streamer)
	terrain.edit(Vector3(16.0, 0.0, 16.0), 24.0, 5.0)
	var edited := terrain.height_at(16.0, 16.0)
	source.position = Vector3(500.0, 0.0, 500.0)
	await _until_done(streamer)
	_check(not terrain.has_chunk(KEY_A), "(the source walks away, and the edited chunk unloads)")
	source.position = Vector3(16.0, 0.0, 16.0)
	await _until_done(streamer)
	_check(is_equal_approx(terrain.height_at(16.0, 16.0), edited), "and coming back, the edit is still there")
	source.free()
	streamer.free()
	terrain.free()


func _test_bodies_stay_above() -> void:
	var terrain := _make_terrain()
	terrain.chunk_resolution = 16
	terrain.build_collision = true
	terrain.load_chunk(KEY_A)
	await _physics_frames(3)
	var spot := Vector2(16.0, 16.0)
	var ground := terrain.height_at(spot.x, spot.y)
	var body := Node3D.new()
	body.position = Vector3(spot.x, ground, spot.y)
	body.add_to_group(TerrainBodyLifter.GROUP)
	add_child(body)
	var stranger := Node3D.new()
	stranger.position = Vector3(spot.x, ground, spot.y)
	add_child(stranger)
	var above := Node3D.new()
	above.position = Vector3(spot.x, ground + 50.0, spot.y)
	above.add_to_group(TerrainBodyLifter.GROUP)
	add_child(above)
	var far := Node3D.new()
	far.position = Vector3(spot.x + 8.0, -20.0, spot.y)
	far.add_to_group(TerrainBodyLifter.GROUP)
	add_child(far)

	# Claude 2026-11-07: an optional module now. Without it, the terrain moves nothing.
	terrain.edit(Vector3(spot.x, 0.0, spot.y), 2.0, 0.5)
	_check(is_equal_approx(body.position.y, ground), "with no lifter, nothing is moved")
	ground = terrain.height_at(spot.x, spot.y)
	body.position.y = ground
	stranger.position.y = ground
	above.position.y = ground + 50.0
	var lifter := TerrainBodyLifter.new()
	terrain.add_child(lifter)

	terrain.edit(Vector3(spot.x, 0.0, spot.y), 2.0, 6.0)
	var raised := terrain.height_at(spot.x, spot.y)
	_check(raised > ground + 1.0, "(the ground rose %.1f m)" % (raised - ground))
	_check(is_equal_approx(body.position.y, raised), "a body under raised ground is moved onto it")
	_check(is_equal_approx(stranger.position.y, ground), "one that isn't in the group is left alone")
	_check(is_equal_approx(above.position.y, ground + 50.0), "one well above it is left alone")
	_check(is_equal_approx(far.position.y, -20.0), "and so is one outside the patch")

	var before := body.position.y
	terrain.edit(Vector3(spot.x, 0.0, spot.y), 8.0, -3.0)
	_check(is_equal_approx(body.position.y, before), "digging doesn't move anything, so a body just falls into the hole")
	body.free()
	stranger.free()
	above.free()
	far.free()
	terrain.free()


func _test_long_edit_lists() -> void:
	var terrain := _make_terrain()
	var edit_log := _add_log(terrain)
	for i in 100:
		terrain.edit(Vector3(16.0, 0.0, 16.0), 8.0, 0.1)
	var steps := 1
	while not terrain.build_chunk_step(KEY_A):
		steps += 1
	_check(steps >= 100 / TerrainGenerator.EDITS_PER_STEP, "a chunk with 100 edits spreads them across steps (%d steps)" % steps)
	var direct := _make_terrain()
	var direct_log := _add_log(direct)
	direct_log.from_bytes(edit_log.to_bytes())
	direct.load_chunk(KEY_A)
	_check(terrain._points[KEY_A] == direct._points[KEY_A], "with the same result")
	terrain.free()
	direct.free()


## Not a pass or fail, just numbers.
func _measure() -> void:
	var terrain := TerrainGenerator.new()
	terrain.build_on_start = false
	terrain.build_collision = false
	add_child(terrain)
	var edit_log := _add_log(terrain)
	for edits_on_chunk: int in [0, 10, 100, 1000]:
		edit_log.clear()
		var pick := RandomNumberGenerator.new()
		pick.seed = 7
		for i in edits_on_chunk:
			edit_log.record(pick.randf_range(0.0, 128.0), pick.randf_range(0.0, 128.0), 6.0, 0.1)
		terrain.unload_chunk(KEY_A)
		var started := Time.get_ticks_usec()
		terrain.load_chunk(KEY_A)
		print("        building a 128 m chunk with %d edits on it: %.2f ms, log %d KB" % [edits_on_chunk, (Time.get_ticks_usec() - started) / 1000.0, edit_log.to_bytes().size() / 1024])
	terrain.free()


# --- Helpers ---


func _make_terrain() -> TerrainGenerator:
	var terrain := TerrainGenerator.new()
	terrain.name = "Terrain"
	terrain.build_on_start = false
	terrain.chunk_size = 32.0
	terrain.chunk_resolution = 8
	terrain.build_collision = false
	add_child(terrain)
	return terrain


func _add_log(terrain: TerrainGenerator) -> TerrainEditLog:
	var edit_log := TerrainEditLog.new()
	terrain.add_child(edit_log)
	return edit_log


## The last row of points across chunk A, against the first row of chunk B.
func _shared_border_matches(terrain: TerrainGenerator) -> bool:
	var a: PackedVector3Array = terrain._points[KEY_A]
	var b: PackedVector3Array = terrain._points[KEY_B]
	var n: int = terrain._points_per_edge()
	for row in n:
		if a[n - 1 + row * n] != b[row * n]:
			return false
	return true


func _until_done(streamer: ChunkStreamer) -> void:
	await get_tree().process_frame
	await get_tree().process_frame
	for i in 3000:
		var stats := streamer.get_stats()
		if stats.queued == 0 and stats.unload_queued == 0:
			return
		await get_tree().process_frame
	_check(false, "the streamer finished within the time limit")


func _physics_frames(count: int) -> void:
	for i in count:
		await get_tree().physics_frame


func _check(passed: bool, what: String) -> void:
	print("  %s %s" % ["ok  " if passed else "FAIL", what])
	if not passed:
		_failures += 1
