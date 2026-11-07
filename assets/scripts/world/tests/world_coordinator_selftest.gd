## Written by Claude (claude-opus-5-5), 2026-11-07: headless self-test for WorldCoordinator and TerrainNavFeeder: terrain and nav working together
## while neither knows the other exists. Exits 0 on success, 1 on failure. Run from the project folder:
##   "C:\Git\Test 2\Godot_v4.7.2-stable_win64_console.exe" --headless --path . "res://assets/scripts/world/tests/world_coordinator_selftest.tscn"
extends Node

const CHUNK_SIZE := 64.0
const CHUNK_RESOLUTION := 11
const TIER_SMALLEST := 0

var _failures := 0


## A terrain with one marker per chunk, so counts are easy to check.
class OneMarkerTerrain extends TerrainGenerator:
	func _make_chunk_markers(key: Vector2i) -> Array[NavMarker]:
		var marker := NavPoint.new()
		marker.tag = &"point.cover"
		marker.position = _point_at(key.x * chunk_resolution, key.y * chunk_resolution)
		var markers: Array[NavMarker] = [marker]
		return markers


func _ready() -> void:
	print("--- World coordinator self-test ---")
	NavMarkerManager.report_quiet_seconds = 1000000.0 # the automatic report stays quiet in this test
	NavServer.configure({"worker_threads": 4})
	_test_terrain_stands_alone()
	_test_odd_setups()
	await _test_whole_world()
	await _test_world_with_no_nav()
	_test_link_arriving_late()
	_test_link_leaving_and_returning()
	NavMarkerManager.report_quiet_seconds = 2.0
	NavMarkerManager.reset()
	print("--- ALL PASSED ---" if _failures == 0 else "--- %d FAILED ---" % _failures)
	get_tree().quit(0 if _failures == 0 else 1)


## The point of all this. Reading the script's source catches anyone adding a call back in, whatever it's called.
func _test_terrain_stands_alone() -> void:
	var source: String = load("res://assets/scripts/terrain/TerrainGenerator.gd").source_code
	var streamer_source: String = load("res://assets/scripts/streaming/ChunkStreamer.gd").source_code
	for word: String in ["NavServer", "NavMarkerManager", "NetworkSession", "TickDriver"]:
		var calls := source.contains(word + ".") or source.contains("/root/" + word) or source.contains('"%s"' % word)
		_check(not calls, "Terrain doesn't call %s" % word)
	_check(not streamer_source.contains("NavServer") and not streamer_source.contains("tick_nav"), "ChunkStreamer knows nothing about nav")

	NavMarkerManager.reset()
	var terrain := _make_terrain("Plain")
	terrain.build_on_start = true
	terrain.chunk_radius = 0
	add_child(terrain)
	NavMarkerManager.flush()
	_check(terrain.has_chunk(Vector2i.ZERO), "a TerrainGenerator with nothing else still builds its block")
	_check(NavMarkerManager.get_marker_count() == 0, "and with no link, it announces nothing")
	terrain.free()


func _test_odd_setups() -> void:
	var empty := WorldCoordinator.new()
	add_child(empty)
	_check(empty.terrain_generator == null,"a coordinator with no terrain does nothing, and nothing breaks")
	empty.free()
	var lost := TerrainNavFeeder.new()
	add_child(lost)
	lost.refresh_now()
	_check(not lost.uses_nav(), "and so does a link with no terrain")
	lost.free()
	var quiet := TerrainNavFeeder.new()
	var terrain := _make_terrain("Quiet")
	terrain.add_child(quiet)
	add_child(terrain)
	_check(not quiet.uses_nav(), "a link with no hooks doesn't feed nav")
	terrain.free()


func _test_whole_world() -> void:
	NavMarkerManager.reset()
	var world := _make_world("WholeWorld", true)
	var terrain: TerrainGenerator = world.terrain_generator
	_check(world.terrain_generator != null and world.chunk_streamer != null and world.nav_feeder != null, "the coordinator finds its parts")
	_check(world.chunk_streamer.terrain == terrain and world.nav_feeder.terrain == terrain, "and wires them to the terrain")
	_check(not terrain.build_on_start, "and with a streamer, the terrain starts empty")
	_check(terrain.get_loaded_chunks().is_empty(), "(nothing is built yet)")

	var source := StreamingSource.new()
	source.position = Vector3(64.0, 0.0, 32.0)
	source.load_distance = 90.0
	source.nav_distance = 60.0
	add_child(source)
	await _until_settled(world)
	_check(terrain.has_chunk(Vector2i(0, 0)) and terrain.has_chunk(Vector2i(1, 0)), "a source loads the chunks around it")
	_check(world.nav_feeder.uses_nav() and world.nav_feeder._nav_interests.size() == 1, "and the link keeps nav built around it")
	# Claude 2026-11-07, from the audit of 6df1464: changing a source's distance while running resizes its nav interest.
	var source_id := source.get_instance_id()
	var first_interest: int = world.nav_feeder._nav_interests[source_id]
	source.nav_distance = 40.0
	await _until_settled(world)
	_check(world.nav_feeder._nav_interest_radius.get(source_id) == 40.0 and world.nav_feeder._nav_interests[source_id] != first_interest,
			"changing a source's nav_distance while running gives it a nav interest of the new size")
	source.nav_distance = 60.0
	await _until_settled(world)
	NavMarkerManager.flush()
	_check(NavMarkerManager.get_marker_count() == terrain.get_loaded_chunks().size(), "and each chunk's markers are announced (%d)" % NavMarkerManager.get_marker_count())

	var from := _on_ground(terrain, 44.0, 32.0)
	var to := _on_ground(terrain, 84.0, 32.0)
	var before := _length(NavServer.find_path_now(from, to, TIER_SMALLEST))
	_check(before > 35.0 and before < 70.0, "nav finds a path across a chunk border (%.1f m)" % before)

	terrain.edit(Vector3(64.0, 0.0, 32.0), 8.0, 16.0)
	await _until_settled(world)
	var around := _length(NavServer.find_path_now(from, to, TIER_SMALLEST))
	_check(around > before + 1.0, "an edit reaches nav through the link (%.1f m)" % around)

	var far_chunk := Vector2i(1, 0)
	var id := NavMarkerManager.chunk_marker_id(NavMarkerManager.scene_marker_id(str(terrain.get_path())), far_chunk, 0)
	_check(NavMarkerManager.get_marker(id) != null, "(that chunk has its marker)")
	source.position = Vector3(-2000.0, 0.0, 32.0)
	await _until_settled(world)
	NavMarkerManager.flush()
	_check(not terrain.has_chunk(far_chunk), "when the source goes away, its chunks unload")
	_check(NavMarkerManager.get_marker(id) == null, "and their markers go")
	_check(NavServer.find_path_now(from, to, TIER_SMALLEST).size() < 2, "and so does their nav")

	source.free()
	world.free()
	NavMarkerManager.flush()
	_check(NavMarkerManager.get_marker_count() == 0, "freeing the world takes everything with it")
	_settle()


func _test_world_with_no_nav() -> void:
	NavMarkerManager.reset()
	var world := _make_world("NoNav", false)
	var source := StreamingSource.new()
	source.load_distance = 40.0
	add_child(source)
	for i in 30:
		await get_tree().physics_frame
	_check(world.nav_feeder == null, "a world can leave the link out")
	_check(world.terrain_generator.has_chunk(Vector2i(0, 0)), "and its chunks still load")
	NavMarkerManager.flush()
	_check(NavMarkerManager.get_marker_count() == 0, "with nothing announced")
	source.free()
	world.free()


func _test_link_arriving_late() -> void:
	NavMarkerManager.reset()
	var terrain := _make_terrain("LateLink")
	terrain.build_on_start = true
	terrain.chunk_radius = 1
	add_child(terrain)
	var link := TerrainNavFeeder.new()
	link.terrain = terrain
	add_child(link)
	NavMarkerManager.flush()
	_check(NavMarkerManager.get_marker_count() == 9, "a link arriving after the chunks catches up on them (%d)" % NavMarkerManager.get_marker_count())
	link.free()
	NavMarkerManager.flush()
	_check(NavMarkerManager.get_marker_count() == 0, "and takes its markers when it goes, leaving the terrain")
	_check(terrain.has_chunk(Vector2i.ZERO), "(the terrain is still there)")
	terrain.free()


func _test_link_leaving_and_returning() -> void:
	NavMarkerManager.reset()
	var terrain := _make_terrain("Returning")
	terrain.build_on_start = true
	terrain.chunk_radius = 0
	var link := TerrainNavFeeder.new()
	terrain.add_child(link)
	add_child(terrain)
	NavMarkerManager.flush()
	var count := NavMarkerManager.get_marker_count()
	terrain.remove_child(link)
	NavMarkerManager.flush()
	_check(count == 1 and NavMarkerManager.get_marker_count() == 0, "a link leaving releases what it announced")
	terrain.add_child(link)
	NavMarkerManager.flush()
	_check(NavMarkerManager.get_marker_count() == 1, "and announces it again when it returns")
	terrain.free()
	NavMarkerManager.flush()


# --- Helpers ---


func _make_terrain(terrain_name: String) -> OneMarkerTerrain:
	var terrain := OneMarkerTerrain.new()
	terrain.name = terrain_name
	terrain.build_on_start = false
	terrain.build_collision = false
	terrain.chunk_size = CHUNK_SIZE
	terrain.chunk_resolution = CHUNK_RESOLUTION
	return terrain


func _make_world(world_name: String, with_nav: bool) -> WorldCoordinator:
	var world := WorldCoordinator.new()
	world.name = world_name
	world.add_child(_make_terrain("Terrain"))
	var streamer := ChunkStreamer.new()
	streamer.refresh_seconds = 0.0
	streamer.unload_margin = 0.0
	streamer.hold_when_no_sources = false
	world.add_child(streamer)
	if with_nav:
		var link := TerrainNavFeeder.new()
		link.nav_hooks = NavHooks.new()
		link.refresh_seconds = 0.0
		link.unload_margin = 10.0
		link.tick_nav = true
		world.add_child(link)
	add_child(world)
	return world


## Lets the streamer finish, then nav.
func _until_settled(world: WorldCoordinator) -> void:
	await get_tree().process_frame
	for i in 1200:
		await get_tree().physics_frame
		if i > 3 and world.chunk_streamer.get_stats().queued == 0 and world.chunk_streamer.get_stats().unload_queued == 0 and NavServer.is_idle():
			return
	_check(false, "the world settled within the time limit")


func _settle() -> void:
	for i in 4000:
		NavServer.tick(1.0 / 60.0)
		if i > 2 and NavServer.is_idle():
			return
		OS.delay_msec(2)
	_check(false, "nav became idle within the time limit")


func _on_ground(terrain: TerrainGenerator, x: float, z: float) -> Vector3:
	return Vector3(x, terrain.height_at(x, z), z)


func _length(path: PackedVector3Array) -> float:
	var total := 0.0
	for i in range(1, path.size()):
		total += path[i].distance_to(path[i - 1])
	return total


func _check(ok: bool, what: String) -> void:
	print(("  PASS  " if ok else "  FAIL  ") + what)
	if not ok:
		_failures += 1
