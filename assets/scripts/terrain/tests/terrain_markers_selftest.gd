## Written by Claude (claude-opus-5-5), 2026-11-06: headless self-test for a terrain's chunks announcing their markers to NavWorld.
## Also times generating and editing at the 128 m defaults, which the nav spec's section 21.6 asks for.
## Exits 0 on success, 1 on failure. Run from the project folder:
##   "C:\Git\Test 2\Godot_v4.7.2-stable_win64_console.exe" --headless --path . "res://assets/scripts/terrain/tests/terrain_markers_selftest.tscn"
extends Node


## A small example terrain with exactly one marker per chunk, so counts are easy to check.
class OneMarkerTerrain extends Terrain:
	func _make_chunk_markers(key: Vector2i) -> Array[NavMarker]:
		var marker := NavPoint.new()
		marker.tag = &"point.cover"
		marker.position = _point_at(key.x * chunk_resolution, key.y * chunk_resolution)
		var markers: Array[NavMarker] = [marker]
		return markers


## Records what a module is told, to check that re-announcing reaches modules.
class RecordingModule extends NavMarkerModule:
	var added := 0
	var removed := 0

	func handled_types() -> Array[Script]:
		return [NavPoint]

	func _markers_added(ids: PackedInt64Array) -> void:
		added += ids.size()

	func _markers_removed(ids: PackedInt64Array) -> void:
		removed += ids.size()


var _failures := 0


func _ready() -> void:
	print("--- Terrain markers self-test ---")
	NavWorld.report_quiet_seconds = 1000000.0 # the automatic report stays quiet in this test
	_test_defaults()
	_test_settings_are_registered()
	_test_plain_terrain_announces_nothing()
	_test_chunks_announce()
	_test_positions_follow_the_node()
	_test_same_list_every_time()
	_test_regenerate()
	_test_edit()
	_test_kept_changes()
	_test_leaving_and_returning()
	_test_terrain_ids()
	_test_example_terrain()
	_test_sample_scene()
	_measure_at_defaults()
	NavWorld.report_quiet_seconds = 2.0
	NavWorld.reset()
	print("--- ALL PASSED ---" if _failures == 0 else "--- %d FAILED ---" % _failures)
	get_tree().quit(0 if _failures == 0 else 1)


## Makes a small, quick terrain with one marker per chunk, in the tree, with its requests applied.
func _add_terrain(terrain_name := "Terrain") -> OneMarkerTerrain:
	var terrain := OneMarkerTerrain.new()
	terrain.name = terrain_name
	terrain.chunk_resolution = 4
	terrain.chunk_size = 20.0
	terrain.chunk_radius = 1
	terrain.build_collision = false
	terrain.add_child(WorldNavLink.new()) # Claude 2026-11-07: this announces a terrain's markers now
	add_child(terrain)
	NavWorld.flush()
	return terrain


# Claude 2026-11-06: the owner lowered the default chunk from 256 m to 128 m after the stress test.
func _test_defaults() -> void:
	var terrain := Terrain.new()
	_check(terrain.chunk_size == 128.0 and terrain.chunk_resolution == 21, "defaults: a chunk is 128 m across, with 21 squares")
	_check(absf(terrain.chunk_size / terrain.chunk_resolution - 6.0) < 0.15, "defaults: which keeps squares at about 6 m")
	terrain.free()


func _test_settings_are_registered() -> void:
	NavWorld.reset()
	var terrain := Terrain.new()
	terrain.name = "Terrain"
	terrain.chunk_resolution = 4
	terrain.chunk_size = 20.0
	terrain.position = Vector3(100, 5, -40)
	terrain.build_collision = false
	terrain.add_child(WorldNavLink.new())
	add_child(terrain)
	var id := NavWorld.scene_marker_id(str(terrain.get_path()))
	var settings := NavWorld.get_terrain_settings(id)
	_check(settings != null, "settings: a terrain registers itself with NavWorld")
	_check(settings.chunk_size == 20.0 and settings.origin == Vector3(100, 5, -40), "settings: NavWorld holds its size and position")
	_check(NavWorld.chunk_of(id, Vector3(100, 0, -40)) == Vector2i.ZERO, "chunks: a terrain's corner is chunk 0,0")
	_check(NavWorld.chunk_of(id, Vector3(125, 0, -41)) == Vector2i(1, -1), "chunks: positions work out to the right chunk, negatives included")
	_check(NavWorld.chunk_of(id, Vector3(100000, 0, 0)) == Vector2i(4995, 2), "chunks: a chunk doesn't have to be loaded")
	_check(NavWorld.chunk_of(12345, Vector3(100, 0, 100)) == Vector2i.ZERO, "chunks: an unknown terrain gives zero, with no error")
	terrain.chunk_size = 30.0
	_check(NavWorld.get_terrain_settings(id).chunk_size == 20.0, "settings: it's a copy, so changing the terrain changes nothing until it registers again")
	terrain.generate()
	_check(NavWorld.get_terrain_settings(id).chunk_size == 30.0, "settings: generating registers the new settings")
	terrain.free()
	_check(NavWorld.get_terrain_settings(id) == null, "settings: a terrain leaving the scene takes them away")


func _test_plain_terrain_announces_nothing() -> void:
	NavWorld.reset()
	var terrain := Terrain.new()
	terrain.name = "Plain"
	terrain.chunk_resolution = 4
	terrain.chunk_size = 20.0
	terrain.add_child(WorldNavLink.new())
	add_child(terrain)
	NavWorld.flush()
	_check(NavWorld.get_marker_count() == 0, "plain terrain: announces no markers")
	_check(NavWorld.get_pending_count() == 0, "plain terrain: and asks NavWorld for nothing")
	terrain.free()
	NavWorld.flush()


func _test_chunks_announce() -> void:
	NavWorld.reset()
	var module := RecordingModule.new()
	add_child(module)
	NavWorld.flush()
	var terrain := _add_terrain()
	_check(NavWorld.get_marker_count() == 9, "announcing: a 3 by 3 terrain's chunks each announce theirs")
	_check(module.added == 9, "announcing: and modules hear about them")
	_check(NavWorld.find_in_radius(&"point.cover", Vector3.ZERO, 1000.0).size() == 9, "announcing: and they can be found")
	terrain.free()
	NavWorld.flush()
	_check(NavWorld.get_marker_count() == 0, "releasing: a terrain leaving takes its markers")
	_check(module.removed == 9, "releasing: and modules hear about that too")
	module.free()


func _test_positions_follow_the_node() -> void:
	NavWorld.reset()
	var terrain := OneMarkerTerrain.new()
	terrain.name = "Moved"
	terrain.chunk_resolution = 4
	terrain.chunk_size = 20.0
	terrain.chunk_radius = 0
	terrain.build_collision = false
	terrain.grid_jitter = 0.0
	terrain.position = Vector3(500, 10, 300)
	terrain.add_child(WorldNavLink.new())
	add_child(terrain)
	NavWorld.flush()
	var id := NavWorld.chunk_marker_id(NavWorld.scene_marker_id(str(terrain.get_path())), Vector2i.ZERO, 0)
	var position := NavWorld.get_marker_position(id)
	_check(position.x == 500.0 and position.z == 300.0, "positions: markers are placed in the world, not measured from the terrain")
	_check(is_equal_approx(position.y, terrain.height_at(500.0, 300.0)), "positions: and sit on the ground")
	terrain.free()
	NavWorld.flush()


func _test_same_list_every_time() -> void:
	NavWorld.reset()
	var first := TerrainMarkerExample.new()
	first.name = "Example"
	first.chunk_resolution = 24
	first.chunk_size = 48.0
	first.chunk_radius = 0
	first.build_collision = false
	add_child(first)
	var list_a := first._make_chunk_markers(Vector2i(2, 3))
	var list_b := first._make_chunk_markers(Vector2i(2, 3))
	var all_match := list_a.size() == list_b.size() and list_a.size() > 1
	for index in mini(list_a.size(), list_b.size()):
		if list_a[index].tag != list_b[index].tag or list_a[index].position != list_b[index].position:
			all_match = false
	_check(all_match, "the same list: a chunk makes the same markers, in the same order, each time")
	var different := first._make_chunk_markers(Vector2i(4, 3))
	_check(different.size() > 1, "the same list: other chunks have markers too")
	first.free()
	NavWorld.flush()


func _test_regenerate() -> void:
	NavWorld.reset()
	var terrain := _add_terrain()
	var ids := NavWorld.find_in_radius(&"point.cover", Vector3.ZERO, 1000.0)
	terrain.generate()
	NavWorld.flush()
	_check(NavWorld.get_marker_count() == 9, "regenerating: no duplicates and no refusals")
	_check(NavWorld.find_in_radius(&"point.cover", Vector3.ZERO, 1000.0) == ids, "regenerating: the same markers keep the same ids")
	terrain.chunk_radius = 0
	terrain.generate()
	NavWorld.flush()
	_check(NavWorld.get_marker_count() == 1, "regenerating: a smaller terrain leaves no markers behind")
	terrain.free()
	NavWorld.flush()


func _test_edit() -> void:
	NavWorld.reset()
	var module := RecordingModule.new()
	add_child(module)
	NavWorld.flush()
	var terrain := _add_terrain()
	var id := NavWorld.chunk_marker_id(NavWorld.scene_marker_id(str(terrain.get_path())), Vector2i.ZERO, 0)
	var height_before := NavWorld.get_marker_position(id).y
	var added_before := module.added
	# The terrain's origin is chunk 0,0's first point, which holds the marker. A small patch touches the four chunks
	# that meet there, and no others.
	terrain.edit(terrain.global_position, 3.0, 10.0)
	NavWorld.flush()
	_check(NavWorld.get_marker_count() == 9, "editing: the count doesn't change")
	_check(NavWorld.get_marker_position(id).y > height_before + 1.0, "editing: a marker on raised ground moves up with it")
	_check(module.added > added_before and module.added - added_before < 9, "editing: only the chunks it touched announce again")
	terrain.free()
	module.free()
	NavWorld.flush()


func _test_kept_changes() -> void:
	NavWorld.reset()
	var terrain := _add_terrain()
	var id := NavWorld.chunk_marker_id(NavWorld.scene_marker_id(str(terrain.get_path())), Vector2i.ZERO, 0)
	NavWorld.set_enabled(id, false)
	NavWorld.flush()
	terrain.edit(Vector3.ZERO, 3.0, 5.0)
	NavWorld.flush()
	_check(not NavWorld.is_marker_enabled(id), "kept changes: a disabled marker stays disabled through an edit")
	terrain.generate()
	NavWorld.flush()
	_check(not NavWorld.is_marker_enabled(id), "kept changes: and through regenerating")
	terrain.free()
	NavWorld.flush()
	_check(NavWorld.get_kept_change_count() == 1, "kept changes: and NavWorld still remembers it after the terrain leaves")
	var back := _add_terrain()
	_check(not NavWorld.is_marker_enabled(id), "kept changes: so it's still disabled when the terrain returns")
	back.free()
	NavWorld.flush()


func _test_leaving_and_returning() -> void:
	NavWorld.reset()
	var terrain := _add_terrain()
	var ids := NavWorld.find_in_radius(&"point.cover", Vector3.ZERO, 1000.0)
	remove_child(terrain)
	NavWorld.flush()
	_check(NavWorld.get_marker_count() == 0, "leaving: taken out of the scene, its markers go")
	add_child(terrain)
	NavWorld.flush()
	_check(NavWorld.find_in_radius(&"point.cover", Vector3.ZERO, 1000.0) == ids, "returning: put back, the same markers return with the same ids")
	terrain.free()
	NavWorld.flush()


func _test_terrain_ids() -> void:
	NavWorld.reset()
	var first := _add_terrain("First")
	var second := _add_terrain("Second")
	_check(NavWorld.get_marker_count() == 18, "two terrains: markers in the same chunk numbers don't clash")
	var first_id := NavWorld.scene_marker_id(str(first.get_path()))
	second.free()
	NavWorld.flush()
	_check(NavWorld.get_marker_count() == 9, "two terrains: one leaving doesn't affect the other")
	_check(NavWorld.get_terrain_settings(first_id) != null, "two terrains: and the other stays registered")
	first.free()
	NavWorld.flush()
	# The id comes from the path, which a fixed value can check. This is what every machine must agree on.
	_check(NavWorld.scene_marker_id("/root/Level/Terrain") == NavWorld.fnv_hash("/root/Level/Terrain".to_utf8_buffer()), "terrain ids: come from the scene path's hash")


func _test_example_terrain() -> void:
	NavWorld.reset()
	var example := TerrainMarkerExample.new()
	example.name = "Example"
	example.chunk_radius = 0
	example.build_collision = false
	example.add_child(WorldNavLink.new())
	add_child(example)
	NavWorld.flush()
	var seats := NavWorld.find_in_radius(&"use.seat", Vector3.ZERO, 100000.0)
	var cover := NavWorld.find_in_radius(&"point.cover", Vector3.ZERO, 100000.0)
	_check(seats.size() == 1, "example: one seat in the chunk")
	_check(cover.size() > 0, "example: and some cover (%d)" % cover.size())
	var seat_position := NavWorld.get_marker_position(seats[0])
	_check(absf(seat_position.y - example.height_at(seat_position.x, seat_position.z)) < 0.01, "example: the seat sits on the ground")
	var fingerprint := 0
	for id in cover:
		fingerprint ^= id
	print("        marker fingerprint to compare between systems: %d" % fingerprint)
	example.free()
	NavWorld.flush()


func _test_sample_scene() -> void:
	NavWorld.reset()
	# Claude 2026-11-06: the sample scenes moved to assets/scenes/samples.
	var sample: Node = load("res://assets/scenes/samples/terrain_marker_sample.tscn").instantiate()
	add_child(sample)
	NavWorld.flush()
	_check(NavWorld.get_marker_count() > 9, "sample scene: its chunks announce markers (%d)" % NavWorld.get_marker_count())
	var debug: NavMarkerDebugModule = sample.get_node("NavMarkerDebugModule")
	debug.rebuild_now()
	_check(debug.get_drawn_count() == NavWorld.get_marker_count(), "sample scene: the debug module draws them")
	sample.free()
	NavWorld.flush()
	_check(NavWorld.get_marker_count() == 0, "sample scene: freeing it removes them")


## The real cost at the defaults. Printed, not checked, because it depends on the machine. The chunk times are what
## the nav spec's "about 1.5 ms" estimate gets replaced with.
func _measure_at_defaults() -> void:
	NavWorld.reset()
	var terrain := Terrain.new()
	terrain.name = "Measured"
	var start := Time.get_ticks_usec()
	add_child(terrain) # generates 3 by 3 chunks, with collision and no nav
	var generate_ms := (Time.get_ticks_usec() - start) / 1000.0
	var edit_times := PackedFloat64Array()
	for number in 5:
		start = Time.get_ticks_usec()
		# Claude 2026-11-06: the middle of a 128 m chunk.
		terrain.edit(Vector3(64 + number * 2, 0, 64), 8.0, 0.5) # in the middle of a chunk, so one rebuild
		edit_times.append((Time.get_ticks_usec() - start) / 1000.0)
	edit_times.sort()
	print("        at the defaults (128 m chunks of 21 squares, about %d triangles each, collision on, no nav):" % (21 * 21 * 2))
	print("          generating 9 chunks: %.1f ms, or %.1f ms a chunk" % [generate_ms, generate_ms / 9.0])
	print("          one edit rebuilding one chunk: %.1f ms typical, %.1f ms slowest of 5" % [edit_times[2], edit_times[4]])
	terrain.free()
	NavWorld.flush()


func _check(ok: bool, what: String) -> void:
	print(("  PASS  " if ok else "  FAIL  ") + what)
	if not ok:
		_failures += 1
