## Written by Claude (claude-opus-5-5), 2026-11-06: headless self-test for the NavMarkerManager core. Checks the odd cases listed at the top of NavMarkerManager.gd.
## Exits 0 on success, 1 on failure. Run from the project folder:
##   "C:\Git\Test 2\Godot_v4.7.2-stable_win64_console.exe" --headless --path . "res://assets/scripts/navigation/tests/nav_marker_manager_selftest.tscn"
## It prints a few warnings on purpose, because some checks make requests that should be refused.
## Tests only use NavMarkerManager's public functions, so the same tests can check a C++ version later.
extends Node

const TERRAIN := 1

var _failures := 0


func _ready() -> void:
	print("--- NavMarkerManager self-test ---")
	_test_ids()
	_test_requests_wait_for_the_tick()
	await _test_tick_applies_requests()
	_test_refusals()
	_test_search_basics()
	_test_nearest_ties_and_limits()
	_test_negative_positions_and_cell_edges()
	_test_enabled_and_kept_changes()
	_test_release_and_reuse()
	_test_scene_markers()
	_test_empty_and_infinite_searches()
	_test_unknown_ids()
	_test_against_brute_force()
	_measure_at_100000()
	NavMarkerManager.reset()
	print("--- ALL PASSED ---" if _failures == 0 else "--- %d FAILED ---" % _failures)
	get_tree().quit(0 if _failures == 0 else 1)


## Makes a marker. Tests use the tier 0 tags from the real declarations file.
func _marker(tag: StringName, position: Vector3, starts_enabled := true) -> NavMarker:
	var marker := NavMarker.new()
	marker.tag = tag
	marker.position = position
	marker.starts_enabled = starts_enabled
	return marker


## Registers one marker in its own chunk and applies it. Returns its id.
func _add_one(tag: StringName, position: Vector3, chunk: Vector2i) -> int:
	var markers: Array[NavMarker] = [_marker(tag, position)]
	NavMarkerManager.request_markers(TERRAIN, chunk, markers)
	NavMarkerManager.flush()
	return NavMarkerManager.chunk_marker_id(TERRAIN, chunk, 0)


func _test_ids() -> void:
	# The published FNV-1a results for these inputs, written as signed 64-bit numbers. Worked out separately in Python.
	_check(NavMarkerManager.fnv_hash("".to_utf8_buffer()) == -3750763034362895579, "id hash: empty input gives the standard starting value")
	_check(NavMarkerManager.fnv_hash("a".to_utf8_buffer()) == -5808556873153909620, "id hash: 'a' matches the published FNV-1a value")
	_check(NavMarkerManager.fnv_hash("foobar".to_utf8_buffer()) == -8821353812377114648, "id hash: 'foobar' matches the published FNV-1a value")
	var id := NavMarkerManager.chunk_marker_id(1, Vector2i(3, -4), 5)
	_check(id == NavMarkerManager.chunk_marker_id(1, Vector2i(3, -4), 5), "ids: the same inputs give the same id")
	_check(id != 0, "ids: never 0, which means no marker")
	_check(id != NavMarkerManager.chunk_marker_id(2, Vector2i(3, -4), 5), "ids: a different terrain gives a different id")
	_check(id != NavMarkerManager.chunk_marker_id(1, Vector2i(-4, 3), 5), "ids: swapping a chunk's x and z gives a different id")
	_check(id != NavMarkerManager.chunk_marker_id(1, Vector2i(3, -4), 6), "ids: a different index gives a different id")
	_check(NavMarkerManager.scene_marker_id("/root/Level/Door") != NavMarkerManager.scene_marker_id("/root/Level/Door2"), "ids: a different scene path gives a different id")
	# A fixed number, worked out separately in Python. It catches anyone changing the hash by accident, which
	# would change every id in every saved game. It must also match on every system and in any C++ version.
	_check(id == -4128162523920791911, "ids: a known marker gets the id worked out separately in Python")
	print("        fingerprint to compare between systems: %d" % id)
	var seen := {}
	for chunk_x in range(-50, 50):
		for index in 100:
			seen[NavMarkerManager.chunk_marker_id(TERRAIN, Vector2i(chunk_x, 7), index)] = true
	_check(seen.size() == 10000, "ids: 10,000 neighbouring markers all get different ids")


func _test_requests_wait_for_the_tick() -> void:
	NavMarkerManager.reset()
	var markers: Array[NavMarker] = [_marker(&"point.cover", Vector3(1, 0, 1))]
	_check(NavMarkerManager.request_markers(TERRAIN, Vector2i.ZERO, markers) == 1, "requests: returns how many were accepted")
	var id := NavMarkerManager.chunk_marker_id(TERRAIN, Vector2i.ZERO, 0)
	_check(NavMarkerManager.get_marker(id) == markers[0], "requests: the id and full data are available at once")
	_check(NavMarkerManager.get_pending_count() == 1, "requests: it waits in the queue")
	_check(NavMarkerManager.find_nearest(&"point.cover", Vector3.ZERO, 100.0) == 0, "requests: it isn't searchable yet")
	NavMarkerManager.flush()
	_check(NavMarkerManager.find_nearest(&"point.cover", Vector3.ZERO, 100.0) == id, "requests: searchable once applied")
	_check(NavMarkerManager.get_pending_count() == 0, "requests: the queue is empty afterwards")
	NavMarkerManager.release_markers(TERRAIN, Vector2i.ZERO)
	_check(NavMarkerManager.find_nearest(&"point.cover", Vector3.ZERO, 100.0) == id, "requests: a released marker stays searchable until the tick")
	NavMarkerManager.flush()
	_check(NavMarkerManager.find_nearest(&"point.cover", Vector3.ZERO, 100.0) == 0, "requests: and is gone afterwards")


func _test_tick_applies_requests() -> void:
	NavMarkerManager.reset()
	var markers: Array[NavMarker] = [_marker(&"point.cover", Vector3(1, 0, 1))]
	NavMarkerManager.request_markers(TERRAIN, Vector2i.ZERO, markers)
	var tick_before: int = TickDriver.tick
	# GDScript note: await pauses this function until the signal fires, and the game keeps running meanwhile.
	await get_tree().physics_frame
	await get_tree().physics_frame
	await get_tree().physics_frame
	_check(TickDriver.tick > tick_before, "tick: the driver really is ticking in this test")
	_check(NavMarkerManager.get_pending_count() == 0, "tick: the driver's tick applies waiting requests by itself")
	_check(NavMarkerManager.find_nearest(&"point.cover", Vector3.ZERO, 100.0) != 0, "tick: and the marker can be found")


func _test_refusals() -> void:
	NavMarkerManager.reset()
	var markers: Array[NavMarker] = [
		_marker(&"point.cover", Vector3.ZERO),
		_marker(&"not.declared.anywhere", Vector3.ZERO),
		null,
		_marker(&"", Vector3.ZERO),
		_marker(&"point.patrol", Vector3.ZERO),
	]
	_check(NavMarkerManager.request_markers(TERRAIN, Vector2i.ZERO, markers) == 2, "refusals: a bad tag, null and an empty tag are refused, and the rest accepted")
	_check(not NavTags.has_tag(&"not.declared.anywhere"), "refusals: being refused doesn't add the tag")
	_check(NavMarkerManager.get_marker_count() == 2, "refusals: only the accepted ones count")
	# Ids come from the place in the list, so the good ones keep theirs even with bad ones between them.
	_check(NavMarkerManager.get_marker(NavMarkerManager.chunk_marker_id(TERRAIN, Vector2i.ZERO, 4)) == markers[4], "refusals: a marker's id still comes from its place in the list")
	var again: Array[NavMarker] = [_marker(&"point.cover", Vector3.ZERO)]
	_check(NavMarkerManager.request_markers(TERRAIN, Vector2i.ZERO, again) == 0, "refusals: a duplicate id is refused")
	var nothing: Array[NavMarker] = []
	_check(NavMarkerManager.request_markers(TERRAIN, Vector2i(9, 9), nothing) == 0, "refusals: an empty list is fine")


func _test_search_basics() -> void:
	NavMarkerManager.reset()
	var cover := _add_one(&"point.cover", Vector3(10, 0, 0), Vector2i(0, 0))
	var patrol := _add_one(&"point.patrol", Vector3(5, 0, 0), Vector2i(0, 1))
	var jump := _add_one(&"link.jump", Vector3(1, 0, 0), Vector2i(0, 2))
	_check(NavMarkerManager.find_nearest(&"point.cover", Vector3.ZERO, 100.0) == cover, "search: finds by exact tag")
	_check(NavMarkerManager.find_nearest(&"point", Vector3.ZERO, 100.0) == patrol, "search: a parent tag finds what's inside it, nearest first")
	_check(NavMarkerManager.find_nearest(&"link", Vector3.ZERO, 100.0) == jump, "search: other parents work too")
	_check(NavMarkerManager.find_nearest(&"area", Vector3.ZERO, 100.0) == 0, "search: a tag with no markers finds nothing")
	_check(NavMarkerManager.find_nearest(&"never.declared", Vector3.ZERO, 100.0) == 0, "search: an undeclared tag finds nothing")
	_check(not NavTags.has_tag(&"never.declared"), "search: and doesn't add it")
	_check(NavMarkerManager.find_nearest(&"", Vector3.ZERO, 100.0) == 0, "search: an empty tag finds nothing")
	var found := NavMarkerManager.find_in_radius(&"point", Vector3.ZERO, 100.0)
	_check(found.size() == 2 and found.has(cover) and found.has(patrol), "search: find_in_radius finds every match")
	_check(found[0] < found[1], "search: results are sorted by id, so machines agree on the order")
	_check(NavMarkerManager.find_in_radius(&"point", Vector3.ZERO, 6.0) == PackedInt64Array([patrol]), "search: find_in_radius respects the radius")
	_check(NavMarkerManager.get_marker_position(cover) == Vector3(10, 0, 0), "search: get_marker_position gives where it is")
	_check(NavMarkerManager.get_marker(cover).tag == &"point.cover", "search: get_marker gives the full data")
	# Height counts as distance, even though cells ignore it.
	NavMarkerManager.reset()
	var above := _add_one(&"point.cover", Vector3(0, 50, 0), Vector2i(0, 0))
	var beside := _add_one(&"point.cover", Vector3(40, 0, 0), Vector2i(0, 1))
	_check(NavMarkerManager.find_nearest(&"point.cover", Vector3.ZERO, 100.0) == beside, "search: height counts, so a marker high above isn't the nearest")
	_check(NavMarkerManager.find_nearest(&"point.cover", Vector3(0, 50, 0), 100.0) == above, "search: and searching from up there finds it")


func _test_nearest_ties_and_limits() -> void:
	NavMarkerManager.reset()
	var first := _add_one(&"point.cover", Vector3(10, 0, 0), Vector2i(0, 0))
	var second := _add_one(&"point.cover", Vector3(-10, 0, 0), Vector2i(0, 1))
	_check(NavMarkerManager.find_nearest(&"point.cover", Vector3.ZERO, 100.0) == mini(first, second), "nearest: equal distances go to the lower id")
	_check(NavMarkerManager.find_nearest(&"point.cover", Vector3.ZERO, 5.0) == 0, "nearest: nothing within the limit finds nothing")
	_check(NavMarkerManager.find_nearest(&"point.cover", Vector3.ZERO, 10.0) != 0, "nearest: exactly at the limit counts")
	_check(NavMarkerManager.find_nearest(&"point.cover", Vector3.ZERO, -1.0) == 0, "nearest: a negative limit finds nothing")
	_check(NavMarkerManager.find_in_radius(&"point.cover", Vector3.ZERO, 10.0).size() == 2, "radius: exactly at the edge counts")
	_check(NavMarkerManager.find_in_radius(&"point.cover", Vector3.ZERO, -1.0).is_empty(), "radius: a negative radius finds nothing")
	# A marker just across a cell edge can be nearer than one in the search's own cell.
	NavMarkerManager.reset()
	var same_cell := _add_one(&"point.cover", Vector3(1, 0, 1), Vector2i(0, 0))
	var next_cell := _add_one(&"point.cover", Vector3(32.5, 0, 1), Vector2i(0, 1))
	_check(NavMarkerManager.find_nearest(&"point.cover", Vector3(31.5, 0, 1), 100.0) == next_cell, "nearest: looks past its own cell for something closer")
	_check(NavMarkerManager.find_nearest(&"point.cover", Vector3(2, 0, 1), 100.0) == same_cell, "nearest: and still finds the one beside it")


func _test_negative_positions_and_cell_edges() -> void:
	NavMarkerManager.reset()
	var negative := _add_one(&"point.cover", Vector3(-0.5, 0, -0.5), Vector2i(0, 0))
	var on_edge := _add_one(&"point.patrol", Vector3(-32, 0, 32), Vector2i(0, 1))
	_check(NavMarkerManager.find_nearest(&"point.cover", Vector3(0.5, 0, 0.5), 5.0) == negative, "cells: a search crosses from positive into negative")
	_check(NavMarkerManager.find_in_radius(&"point.patrol", Vector3(-32, 0, 32), 0.0) == PackedInt64Array([on_edge]), "cells: a marker exactly on a cell edge can be found")
	var far_away := _add_one(&"point.ambush", Vector3(-8000, 0, 8000), Vector2i(0, 2))
	_check(NavMarkerManager.find_nearest(&"point.ambush", Vector3(8000, 0, -8000), 100000.0) == far_away, "cells: finds a marker the whole world away")


func _test_enabled_and_kept_changes() -> void:
	NavMarkerManager.reset()
	var door := Vector2i(5, 5)
	var markers: Array[NavMarker] = [_marker(&"link.door", Vector3.ZERO), _marker(&"point.cover", Vector3(1, 0, 0), false)]
	NavMarkerManager.request_markers(TERRAIN, door, markers)
	NavMarkerManager.flush()
	var door_id := NavMarkerManager.chunk_marker_id(TERRAIN, door, 0)
	var off_id := NavMarkerManager.chunk_marker_id(TERRAIN, door, 1)
	_check(NavMarkerManager.is_marker_enabled(door_id), "enabled: on by default")
	_check(not NavMarkerManager.is_marker_enabled(off_id), "enabled: starts_enabled = false starts off")
	_check(NavMarkerManager.find_nearest(&"point.cover", Vector3.ZERO, 100.0) == 0, "enabled: searches skip disabled markers")
	NavMarkerManager.set_enabled(door_id, false)
	_check(NavMarkerManager.is_marker_enabled(door_id), "enabled: a change waits for the tick, like everything else")
	NavMarkerManager.flush()
	_check(not NavMarkerManager.is_marker_enabled(door_id), "enabled: then applies")
	_check(NavMarkerManager.find_nearest(&"link.door", Vector3.ZERO, 100.0) == 0, "enabled: and searches skip it")
	_check(NavMarkerManager.get_kept_change_count() == 1, "kept changes: only the changed marker is remembered")
	# Now the chunk unloads and comes back.
	NavMarkerManager.release_markers(TERRAIN, door)
	NavMarkerManager.flush()
	_check(NavMarkerManager.get_marker(door_id) == null, "kept changes: the chunk's markers leave with it")
	var fresh: Array[NavMarker] = [_marker(&"link.door", Vector3.ZERO), _marker(&"point.cover", Vector3(1, 0, 0), false)]
	NavMarkerManager.request_markers(TERRAIN, door, fresh)
	NavMarkerManager.flush()
	_check(not NavMarkerManager.is_marker_enabled(door_id), "kept changes: the door is still disabled when its chunk comes back")
	NavMarkerManager.set_enabled(door_id, true)
	NavMarkerManager.flush()
	_check(NavMarkerManager.get_kept_change_count() == 0, "kept changes: back to how it started, so nothing needs remembering")
	# A request right after a release, in the same tick, keeps the order they were made in.
	NavMarkerManager.release_markers(TERRAIN, door)
	var fresh_again: Array[NavMarker] = [_marker(&"link.door", Vector3(7, 0, 0))]
	_check(NavMarkerManager.request_markers(TERRAIN, door, fresh_again) == 1, "same tick: a chunk can come back right after leaving")
	NavMarkerManager.flush()
	_check(NavMarkerManager.get_marker_position(door_id) == Vector3(7, 0, 0), "same tick: and the new version is what's there")
	_check(NavMarkerManager.find_in_radius(&"link.door", Vector3.ZERO, 100.0).size() == 1, "same tick: with just one copy")


func _test_release_and_reuse() -> void:
	NavMarkerManager.reset()
	var markers: Array[NavMarker] = []
	for index in 100:
		markers.append(_marker(&"point.cover", Vector3(index, 0, 0)))
	NavMarkerManager.request_markers(TERRAIN, Vector2i(1, 1), markers)
	var keep := _add_one(&"point.patrol", Vector3(50, 0, 0), Vector2i(2, 2))
	NavMarkerManager.flush()
	_check(NavMarkerManager.get_marker_count() == 101, "release: everything registered")
	NavMarkerManager.release_markers(TERRAIN, Vector2i(1, 1))
	NavMarkerManager.flush()
	_check(NavMarkerManager.get_marker_count() == 1, "release: the whole chunk leaves at once")
	_check(NavMarkerManager.find_in_radius(&"point.cover", Vector3.ZERO, 1000.0).is_empty(), "release: none of them can be found")
	_check(NavMarkerManager.find_nearest(&"point.patrol", Vector3.ZERO, 1000.0) == keep, "release: another chunk's marker in the same cell is untouched")
	NavMarkerManager.release_markers(TERRAIN, Vector2i(99, 99)) # never registered
	NavMarkerManager.release_markers(TERRAIN, Vector2i(1, 1)) # already gone
	NavMarkerManager.flush()
	_check(NavMarkerManager.get_marker_count() == 1, "release: releasing an unknown chunk does nothing")
	# Rows get reused, so old data must not leak into a new marker.
	var reused: Array[NavMarker] = [_marker(&"link.jump", Vector3(-5, 0, -5), false)]
	NavMarkerManager.request_markers(TERRAIN, Vector2i(3, 3), reused)
	NavMarkerManager.flush()
	var reused_id := NavMarkerManager.chunk_marker_id(TERRAIN, Vector2i(3, 3), 0)
	_check(NavMarkerManager.get_marker_position(reused_id) == Vector3(-5, 0, -5) and not NavMarkerManager.is_marker_enabled(reused_id), "release: a reused row holds only the new marker's data")


func _test_scene_markers() -> void:
	NavMarkerManager.reset()
	var marker := _marker(&"use.seat", Vector3(2, 0, 2))
	var id := NavMarkerManager.request_scene_marker("/root/Level/Bench", marker)
	_check(id == NavMarkerManager.scene_marker_id("/root/Level/Bench"), "scene markers: returns its id")
	NavMarkerManager.flush()
	_check(NavMarkerManager.find_nearest(&"use.seat", Vector3.ZERO, 100.0) == id, "scene markers: can be found")
	_check(NavMarkerManager.request_scene_marker("/root/Level/Bench", marker) == 0, "scene markers: a second one at the same path is refused")
	NavMarkerManager.set_enabled(id, false)
	_check(NavMarkerManager.get_kept_change_count() == 0, "scene markers: changes aren't kept, because the scene owns them")
	NavMarkerManager.remove_scene_marker(id)
	NavMarkerManager.flush()
	_check(NavMarkerManager.get_marker(id) == null, "scene markers: can be removed")
	_check(NavMarkerManager.request_scene_marker("/root/Level/Bench", marker) == id, "scene markers: and registered again")
	var chunk_id := _add_one(&"point.cover", Vector3.ZERO, Vector2i(4, 4))
	NavMarkerManager.remove_scene_marker(chunk_id)
	NavMarkerManager.flush()
	_check(NavMarkerManager.get_marker(chunk_id) != null, "scene markers: a chunk's marker can't be removed this way")


func _test_empty_and_infinite_searches() -> void:
	NavMarkerManager.reset()
	_check(NavMarkerManager.find_nearest(&"point.cover", Vector3.ZERO, INF) == 0, "empty world: an infinite search finishes and finds nothing")
	_check(NavMarkerManager.find_in_radius(&"point.cover", Vector3.ZERO, INF).is_empty(), "empty world: an infinite radius too")
	var far := _add_one(&"point.cover", Vector3(5000, 0, 5000), Vector2i(0, 0))
	_add_one(&"point.patrol", Vector3(0, 0, 0), Vector2i(0, 1))
	_check(NavMarkerManager.find_nearest(&"point.cover", Vector3.ZERO, INF) == far, "infinite: finds the one far marker")
	_check(NavMarkerManager.find_in_radius(&"point.cover", Vector3.ZERO, INF) == PackedInt64Array([far]), "infinite: radius finds it too")
	_check(NavMarkerManager.find_nearest(&"area", Vector3.ZERO, INF) == 0, "infinite: a declared tag with no markers finishes and finds nothing")


func _test_unknown_ids() -> void:
	NavMarkerManager.reset()
	_check(NavMarkerManager.get_marker(12345) == null, "unknown id: get_marker gives null")
	_check(NavMarkerManager.get_marker_position(12345) == Vector3.ZERO, "unknown id: get_marker_position gives zero")
	_check(not NavMarkerManager.is_marker_enabled(12345), "unknown id: not enabled")
	NavMarkerManager.set_enabled(12345, true) # warns, and does nothing
	NavMarkerManager.remove_scene_marker(12345)
	NavMarkerManager.flush()
	_check(NavMarkerManager.get_marker_count() == 0, "unknown id: nothing changed")


## Compares the grid with simply checking every marker, across many random searches and after removals.
## This is what catches mistakes in the ring and cell logic that hand-picked cases miss.
func _test_against_brute_force() -> void:
	NavMarkerManager.reset()
	var random := RandomNumberGenerator.new()
	random.seed = 4242 # a fixed seed, so a failure repeats exactly
	var tags: Array[StringName] = [&"point.cover", &"point.patrol", &"use.seat", &"link.jump"]
	var all: Dictionary = {} # id -> marker
	for chunk_number in 40:
		var chunk := Vector2i(chunk_number, -chunk_number)
		var markers: Array[NavMarker] = []
		for index in 50:
			var position := Vector3(random.randf_range(-600, 600), random.randf_range(-20, 20), random.randf_range(-600, 600))
			markers.append(_marker(tags[random.randi() % tags.size()], position))
		NavMarkerManager.request_markers(TERRAIN, chunk, markers)
		for index in markers.size():
			all[NavMarkerManager.chunk_marker_id(TERRAIN, chunk, index)] = markers[index]
	NavMarkerManager.flush()
	# Take some chunks away and disable some markers, so the data isn't just freshly added.
	for chunk_number in range(0, 40, 4):
		var chunk := Vector2i(chunk_number, -chunk_number)
		NavMarkerManager.release_markers(TERRAIN, chunk)
		for index in 50:
			all.erase(NavMarkerManager.chunk_marker_id(TERRAIN, chunk, index))
	var disabled: Dictionary = {}
	var ids: Array = all.keys()
	for number in range(0, ids.size(), 7):
		NavMarkerManager.set_enabled(ids[number], false)
		disabled[ids[number]] = true
	NavMarkerManager.flush()

	var nearest_wrong := 0
	var radius_wrong := 0
	var search_tags: Array[StringName] = [&"point", &"point.cover", &"use", &"link.jump", &"area"]
	for search in 500:
		var from := Vector3(random.randf_range(-700, 700), random.randf_range(-20, 20), random.randf_range(-700, 700))
		var tag := search_tags[random.randi() % search_tags.size()]
		var distance := random.randf_range(0, 400)
		var bit := NavTags.own_bit(tag)
		var best_id := 0
		var best := distance * distance
		var in_radius := PackedInt64Array()
		for id: int in all:
			if disabled.has(id) or NavTags.mask_of(all[id].tag) & bit == 0:
				continue
			var squared := from.distance_squared_to(all[id].position)
			if squared <= distance * distance:
				in_radius.append(id)
			if squared < best or (squared == best and (best_id == 0 or id < best_id)):
				best = squared
				best_id = id
		in_radius.sort()
		if NavMarkerManager.find_nearest(tag, from, distance) != best_id:
			nearest_wrong += 1
		if NavMarkerManager.find_in_radius(tag, from, distance) != in_radius:
			radius_wrong += 1
	_check(nearest_wrong == 0, "brute force: find_nearest agrees across 500 random searches (%d wrong)" % nearest_wrong)
	_check(radius_wrong == 0, "brute force: find_in_radius agrees across 500 random searches (%d wrong)" % radius_wrong)


## The numbers that decide whether this needs to move to C++ (nav spec section 21.5). Times are printed, not
## checked, because they depend on the machine.
func _measure_at_100000() -> void:
	NavMarkerManager.reset()
	const COUNT := 100000
	var random := RandomNumberGenerator.new()
	random.seed = 777
	var memory_start := OS.get_static_memory_usage()
	var start := Time.get_ticks_usec()
	var tags: Array[StringName] = [&"point.cover", &"point.patrol", &"use.seat", &"link.jump"]
	var chunks: Array[Array] = []
	const CHUNK_COUNT := 400 # 250 markers per chunk, so the batches are a believable size
	for chunk_number in CHUNK_COUNT:
		var markers: Array[NavMarker] = []
		for index in COUNT / CHUNK_COUNT:
			var position := Vector3(random.randf_range(-8000, 8000), random.randf_range(-50, 50), random.randf_range(-8000, 8000))
			markers.append(_marker(tags[index % tags.size()], position))
		chunks.append(markers)
	var make_ms := (Time.get_ticks_usec() - start) / 1000.0
	var memory_made := OS.get_static_memory_usage()

	start = Time.get_ticks_usec()
	for chunk_number in CHUNK_COUNT:
		var markers: Array[NavMarker] = []
		markers.assign(chunks[chunk_number])
		NavMarkerManager.request_markers(TERRAIN, Vector2i(chunk_number, 0), markers)
	var request_ms := (Time.get_ticks_usec() - start) / 1000.0
	start = Time.get_ticks_usec()
	NavMarkerManager.flush()
	var flush_ms := (Time.get_ticks_usec() - start) / 1000.0
	var memory_registered := OS.get_static_memory_usage()
	_check(NavMarkerManager.get_marker_count() == COUNT, "100,000: all registered")

	var targets := PackedVector3Array()
	for number in 1000:
		targets.append(Vector3(random.randf_range(-8000, 8000), 0, random.randf_range(-8000, 8000)))

	start = Time.get_ticks_usec()
	var found_nearest := 0
	for target in targets:
		if NavMarkerManager.find_nearest(&"point.cover", target, 500.0) != 0:
			found_nearest += 1
	var nearest_us := (Time.get_ticks_usec() - start) / 1000.0

	start = Time.get_ticks_usec()
	var found_radius := 0
	for target in targets:
		found_radius += NavMarkerManager.find_in_radius(&"point", target, 50.0).size()
	var radius_us := (Time.get_ticks_usec() - start) / 1000.0

	# The worst case: a tag nothing has, with a long reach, so the search can't stop early.
	start = Time.get_ticks_usec()
	for number in 10:
		NavMarkerManager.find_nearest(&"area.road", targets[number], 20000.0)
	var worst_ms := (Time.get_ticks_usec() - start) / 10000.0

	start = Time.get_ticks_usec()
	for chunk_number in CHUNK_COUNT:
		NavMarkerManager.release_markers(TERRAIN, Vector2i(chunk_number, 0))
	NavMarkerManager.flush()
	var release_ms := (Time.get_ticks_usec() - start) / 1000.0
	_check(NavMarkerManager.get_marker_count() == 0, "100,000: all released")

	print("        100,000 markers in %d chunks:" % CHUNK_COUNT)
	print("          making the marker objects (the generator's cost): %.1f ms, %.1f MB, %.0f bytes each" % [make_ms, (memory_made - memory_start) / 1048576.0, float(memory_made - memory_start) / COUNT])
	print("          requesting: %.1f ms total, applying: %.1f ms, NavMarkerManager's own memory: %.1f MB" % [request_ms, flush_ms, (memory_registered - memory_made) / 1048576.0])
	print("          find_nearest, 500 m reach: %.1f us each (%d of 1000 found one)" % [nearest_us, found_nearest])
	print("          find_in_radius, 50 m: %.1f us each (%.2f found per search)" % [radius_us, found_radius / 1000.0])
	print("          find_nearest worst case, 20 km reach and nothing to find: %.2f ms each" % worst_ms)
	print("          releasing them all: %.1f ms" % release_ms)


func _check(ok: bool, what: String) -> void:
	print(("  PASS  " if ok else "  FAIL  ") + what)
	if not ok:
		_failures += 1
