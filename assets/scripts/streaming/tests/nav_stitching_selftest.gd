## Written by Claude (claude-opus-5-5), 2026-11-06: headless self-test for nav across chunk borders, which the owner
## asked for in particular. "Stitching" here means two things working together:
##   1. Each nav tile reads a little of its neighbour's ground while building, so the edges agree. A tile that was built
##      before its neighbour's chunk loaded has to be rebuilt when that chunk arrives.
##   2. Detour joins neighbouring tiles when they're added, so a path can pass from one to the next.
## Nav tiles are 12.8 m and have nothing to do with chunks. So this tests chunk borders that line up with tile borders
## (64, 128 and 256 m are whole numbers of tiles) and ones that don't (the same terrain moved off the tile grid).
##
## What it checks:
##   - Hops: short paths across every chunk border, compared with the same hops in the middle of chunks.
##   - Long paths across several chunks, including through the point where four chunks meet, for the smallest and
##     largest pawn sizes. The path has to be nearly straight, stay on the ground, and reach its end.
##   - Load order: chunks loaded one at a time, in any order, give the same nav as all loaded together.
##   - Unloading: the path across a border goes when a side unloads, and returns the same when it reloads.
##   - An edit on a border reaches nav on both sides.
##   - A pawn following nav paths across several chunks while the streamer loads them.
##
## Exits 0 on success, 1 on failure. Run from the project folder:
##   "C:\Git\Test 2\Godot_v4.7.2-stable_win64_console.exe" --headless --path . "res://assets/scripts/streaming/tests/nav_stitching_selftest.tscn"
extends Node

const TIER_SMALLEST := 0
const TIER_LARGEST := 3
# How far past a chunk border a hop starts and ends, in metres.
const HOP := 3.0
# The area each hop sweep covers: this far either side of where four chunks meet.
const SWEEP := 48.0
const SWEEP_STEP := 2.0

var _failures := 0


func _ready() -> void:
	print("--- Nav stitching self-test ---")
	NavWorld.report_quiet_seconds = 1000000.0
	Engine.max_fps = 60
	NavServer.configure({"worker_threads": 4})
	print("        nav tiles are %.1f m" % (float(NavServer.get_config().tile_size_cells) * NavServer.get_config().cell_size))

	# GDScript note: each inner list here is one set of values that the loop below tests.
	for setup in [
		[64.0, 11, Vector3.ZERO],
		[128.0, 21, Vector3.ZERO],
		[256.0, 43, Vector3.ZERO],
		[64.0, 11, Vector3(37.3, 0.0, 11.9)],
		[128.0, 21, Vector3(5.1, 0.0, 91.7)],
		[100.0, 17, Vector3.ZERO],
	]:
		_test_borders(setup[0], setup[1], setup[2])
	_test_load_order()
	_test_unloading()
	_test_edit_on_a_border()
	await _test_pawn_follows_nav()

	NavWorld.report_quiet_seconds = 2.0
	NavWorld.reset()
	print("--- ALL PASSED ---" if _failures == 0 else "--- %d FAILED ---" % _failures)
	get_tree().quit(0 if _failures == 0 else 1)


# --- Hops and long paths ---


func _test_borders(chunk_size: float, chunk_resolution: int, offset: Vector3) -> void:
	var label := "%d m chunks%s" % [int(chunk_size), "" if offset == Vector3.ZERO else " off the tile grid"]
	var terrain := _make_terrain(chunk_size, chunk_resolution, offset)
	# Four chunks meet at this terrain's own origin.
	for z in range(-1, 1):
		for x in range(-1, 1):
			terrain.load_chunk(Vector2i(x, z))
	var interest := NavServer.add_interest(offset, 80.0, 90.0, 1)
	_settle()
	_check(NavServer.get_stats().failed == 0, "%s: no tile failed" % label)

	# Hops across both borders, and the same hops well inside the chunks to compare. If the ground itself stopped a
	# path, the comparison hops would fail too. If only the border hops fail, stitching is the problem.
	var inner := minf(chunk_size * 0.5, 40.0)
	var crossing := 0
	var failed := 0
	var compared := 0
	var compared_failed := 0
	var at := -SWEEP
	var worst_hop := ""
	while at <= SWEEP:
		# Skip the squares right at the middle, because the "inside the chunk" position would be on the border.
		for hop in [
			[Vector2(-HOP, at), Vector2(HOP, at)],
			[Vector2(at, -HOP), Vector2(at, HOP)],
		]:
			crossing += 1
			if not _hop_works(terrain, offset, hop[0], hop[1]):
				failed += 1
				worst_hop = str(hop)
		for hop in [
			[Vector2(inner - HOP, at), Vector2(inner + HOP, at)],
			[Vector2(at, inner - HOP), Vector2(at, inner + HOP)],
		]:
			compared += 1
			if not _hop_works(terrain, offset, hop[0], hop[1]):
				compared_failed += 1
		at += SWEEP_STEP
	_check(failed == 0, "%s: %d hops across chunk borders, %d failed%s (inside chunks: %d of %d failed)" % [label, crossing, failed, "" if worst_hop == "" else ", such as %s" % worst_hop, compared_failed, compared])

	# Long paths: along each axis across a border, and diagonally through the point where four chunks meet.
	for tier in [TIER_SMALLEST, TIER_LARGEST]:
		for path_ends in [
			[Vector2(-60.0, 12.0), Vector2(60.0, 19.0)],
			[Vector2(21.0, -60.0), Vector2(9.0, 60.0)],
			[Vector2(-45.0, -45.0), Vector2(45.0, 45.0)],
		]:
			_check_long_path(terrain, offset, path_ends[0], path_ends[1], tier, label)

	NavServer.remove_interest(interest)
	terrain.free()
	_settle()
	_check(NavServer.get_stats().live_detour_tiles == 0, "%s: nothing left behind in nav" % label)


## A short path across a line: does it exist, reach its end, and stay short?
func _hop_works(terrain: Terrain, offset: Vector3, from: Vector2, to: Vector2) -> bool:
	var start := _on_ground(terrain, offset, from)
	var end := _on_ground(terrain, offset, to)
	var path := NavServer.find_path_now(start, end, TIER_SMALLEST)
	if path.size() < 2 or _flat_distance(path[path.size() - 1], end) > 0.5:
		return false
	return _path_length(path) < start.distance_to(end) * 1.5 + 1.0


func _check_long_path(terrain: Terrain, offset: Vector3, from: Vector2, to: Vector2, tier: int, label: String) -> void:
	var start := _on_ground(terrain, offset, from)
	var end := _on_ground(terrain, offset, to)
	var path := NavServer.find_path_now(start, end, tier)
	var what := "%s, tier %d, %s to %s" % [label, tier, from, to]
	if path.size() < 2:
		_check(false, "%s: no path" % what)
		return
	var length := _path_length(path)
	var straight := start.distance_to(end)
	# A target can land on a triangle too steep to walk, so nav stops at the nearest walkable point. That's right. What
	# would be wrong is stopping anywhere else, such as at a border.
	var nearest: Vector3 = NavServer.closest_point(end, tier)
	var end_error := _flat_distance(path[path.size() - 1], nearest)
	# A larger pawn has to stay further from a steep spot, by its own radius, which is 1.5 m for tier 3.
	var allowed_stop := 2.5 if tier == TIER_SMALLEST else 4.0
	_check(end_error < 0.01 and _flat_distance(nearest, end) < allowed_stop and length < straight * 1.3, "%s: reaches its end nearly straight (%.1f m for %.1f m, stopping %.1f m from the target)" % [what, length, straight, _flat_distance(nearest, end)])
	var worst := _worst_off_nav(terrain, path, tier)
	_check(worst.x < 0.6 and worst.y < 1.5, "%s: runs on nav the whole way (worst %.2f m sideways, %.2f m up or down)" % [what, worst.x, worst.y])


# --- Chunks arriving and leaving ---


func _test_load_order() -> void:
	var size := 64.0
	var chunks: Array[Vector2i] = [Vector2i(-1, -1), Vector2i(0, -1), Vector2i(-1, 0), Vector2i(0, 0)]
	var area := AABB(Vector3(-40.0, -200.0, -40.0), Vector3(80.0, 400.0, 80.0))
	var interest := NavServer.add_interest(Vector3.ZERO, 70.0, 80.0, 1)

	# The reference: all four loaded before nav builds anything.
	var together := _make_terrain(size, 11, Vector3.ZERO)
	for key in chunks:
		together.load_chunk(key)
	_settle()
	var start := _on_ground(together, Vector3.ZERO, Vector2(-30.0, -28.0))
	var end := _on_ground(together, Vector3.ZERO, Vector2(30.0, 28.0))
	var reference_length := _path_length(NavServer.find_path_now(start, end, TIER_SMALLEST))
	var reference_triangles: PackedVector3Array = NavServer.get_debug_triangles(area).vertices
	_check(reference_length > 80.0, "(with all four chunks together, the path is %.1f m)" % reference_length)
	together.free()
	_settle()

	# Each order lets nav finish between chunks, which is the hard case: every tile on a border gets built while its
	# neighbour's ground is missing, and has to be rebuilt once it's there.
	var orders := [[0, 1, 2, 3], [3, 2, 1, 0], [0, 3, 1, 2], [2, 0, 3, 1]]
	for order in orders:
		var terrain := _make_terrain(size, 11, Vector3.ZERO)
		for number: int in order:
			terrain.load_chunk(chunks[number])
			_settle()
		var triangles: PackedVector3Array = NavServer.get_debug_triangles(area).vertices
		var length := _path_length(NavServer.find_path_now(start, end, TIER_SMALLEST))
		_check(absf(length - reference_length) < 0.01, "load order %s: same path as all together (%.1f m)" % [order, length])
		_check(_same_triangles(triangles, reference_triangles), "load order %s: and exactly the same nav triangles (%d corners)" % [order, triangles.size()])
		terrain.free()
		_settle()
	NavServer.remove_interest(interest)
	_settle()


func _test_unloading() -> void:
	var terrain := _make_terrain(64.0, 11, Vector3.ZERO)
	var interest := NavServer.add_interest(Vector3.ZERO, 70.0, 80.0, 1)
	var left := Vector2i(-1, 0)
	var right := Vector2i(0, 0)
	terrain.load_chunk(left)
	_settle()
	var start := _on_ground(terrain, Vector3.ZERO, Vector2(-20.0, 30.0))
	var inside := _on_ground(terrain, Vector3.ZERO, Vector2(-40.0, 40.0))
	# A chunk that isn't built has no height, so ask its height from a second terrain with the same ground.
	var twin := _make_terrain(64.0, 11, Vector3.ZERO)
	twin.nav_hooks = null
	twin.load_chunk(right)
	var across := _on_ground(twin, Vector3.ZERO, Vector2(20.0, 30.0))
	twin.free()

	var alone := NavServer.find_path_now(start, across, TIER_SMALLEST)
	_check(alone.size() < 2 or _flat_distance(alone[alone.size() - 1], across) > 5.0, "with one side not loaded, no path reaches the other side")
	_check(_path_reaches(start, inside), "but paths inside the loaded chunk work")

	terrain.load_chunk(right)
	_settle()
	_check(_path_reaches(start, across), "when the other side loads, the path crosses the border")
	var length := _path_length(NavServer.find_path_now(start, across, TIER_SMALLEST))

	terrain.unload_chunk(right)
	_settle()
	var gone := NavServer.find_path_now(start, across, TIER_SMALLEST)
	_check(gone.size() < 2 or _flat_distance(gone[gone.size() - 1], across) > 5.0, "when it unloads, the path across stops working")
	_check(_path_reaches(start, inside), "and paths on the side that stayed still work")

	terrain.load_chunk(right)
	_settle()
	var again := _path_length(NavServer.find_path_now(start, across, TIER_SMALLEST))
	_check(absf(again - length) < 0.01, "when it loads again, the path is the same (%.1f m)" % again)
	NavServer.remove_interest(interest)
	terrain.free()
	_settle()


func _test_edit_on_a_border() -> void:
	var terrain := _make_terrain(64.0, 11, Vector3.ZERO)
	for key in [Vector2i(-1, 0), Vector2i(0, 0)]:
		terrain.load_chunk(key)
	var interest := NavServer.add_interest(Vector3.ZERO, 70.0, 80.0, 1)
	_settle()
	var start := _on_ground(terrain, Vector3.ZERO, Vector2(-14.0, 30.0))
	var end := _on_ground(terrain, Vector3.ZERO, Vector2(14.0, 30.0))
	var before := _path_length(NavServer.find_path_now(start, end, TIER_SMALLEST))

	# A tall, steep lump right on the border, too steep to walk, between the path's two ends.
	terrain.edit(Vector3(0.0, 0.0, 30.0), 12.0, 16.0)
	_settle()
	var left_height: float = terrain._point_at(0, 5).y
	_check(_borders_match(terrain), "an edit on a border moves both chunks' shared points together (one is at %.1f m)" % left_height)
	var after := NavServer.find_path_now(start, end, TIER_SMALLEST)
	_check(_path_length(after) > before + 2.0, "and nav goes around it (%.1f m against %.1f m)" % [_path_length(after), before])
	var worst := _worst_off_nav(terrain, after, TIER_SMALLEST)
	_check(worst.x < 0.6 and worst.y < 1.5, "and the new path runs on nav, on both sides (worst %.2f m sideways, %.2f m up or down)" % [worst.x, worst.y])
	NavServer.remove_interest(interest)
	terrain.free()
	_settle()


# --- A pawn following nav across chunks ---


func _test_pawn_follows_nav() -> void:
	var terrain := _make_terrain(64.0, 11, Vector3.ZERO)
	terrain.build_collision = true
	var streamer := ChunkStreamer.new()
	streamer.terrain = terrain
	streamer.tick_nav = true
	add_child(streamer)
	var pawn := StreamingSamplePawn.new()
	pawn.terrain = terrain
	pawn.speed = 10.0
	pawn.position = Vector3(5.0, 40.0, 5.0)
	pawn.source.load_distance = 128.0
	pawn.source.nav_distance = 72.0
	add_child(pawn)

	var goal := Vector3(330.0, 0.0, 70.0)
	var visited := {}
	var path_failures := 0
	var paths := 0
	var ticks := 0
	var longest_wait := 0
	var waiting := 0
	while ticks < 3600 and Vector2(pawn.global_position.x - goal.x, pawn.global_position.z - goal.z).length() > 6.0:
		await get_tree().physics_frame
		ticks += 1
		var chunk := terrain.chunk_of(pawn.global_position)
		if terrain.has_chunk(chunk):
			visited[chunk] = true
		if not pawn.is_on_floor():
			continue
		# When the last path is done, plan the next 40 m. That target is inside the nav distance, so it should exist.
		if pawn.finished_route or pawn.route.is_empty():
			var flat_position := Vector2(pawn.global_position.x, pawn.global_position.z)
			var flat_goal := Vector2(goal.x, goal.z)
			var target_flat := flat_position + (flat_goal - flat_position).limit_length(40.0)
			if not terrain.has_chunk(terrain.chunk_of(Vector3(target_flat.x, 0.0, target_flat.y))):
				waiting += 1
				longest_wait = maxi(longest_wait, waiting)
				continue
			var target := Vector3(target_flat.x, terrain.height_at(target_flat.x, target_flat.y), target_flat.y)
			var path := NavServer.find_path_now(pawn.global_position, target, TIER_SMALLEST)
			if path.size() >= 2 and _flat_distance(path[path.size() - 1], target) < 1.0:
				paths += 1
				waiting = 0
				pawn.set_route(path)
			else:
				# The nav there may still be building. That's allowed for a moment, and counted.
				path_failures += 1
				waiting += 1
				longest_wait = maxi(longest_wait, waiting)
	var reached := Vector2(pawn.global_position.x - goal.x, pawn.global_position.z - goal.z).length() <= 6.0
	_check(reached, "the pawn reaches a goal 330 m away by following nav paths (%d ticks, %d paths)" % [ticks, paths])
	_check(visited.size() >= 6, "across several chunks (%d)" % visited.size())
	_check(pawn.worst_below_ground < 0.5, "and it stays on the ground (worst %.2f m below)" % pawn.worst_below_ground)
	# The first ticks wait for nav around the start. After that, walking 40 m takes 240 ticks, plenty for it to catch up.
	_check(longest_wait < 300, "and doesn't wait long for nav (longest %d ticks, %d tries failed)" % [longest_wait, path_failures])
	var stats := NavServer.get_stats()
	_check(stats.failed == 0, "and no tile failed")
	# 72 m around the pawn plus the margin is about 300 tiles, so this would be far higher if tiles behind it stayed.
	_check(stats.live_detour_tiles < 700, "and nav behind it unloads (%d tiles live)" % stats.live_detour_tiles)
	print("        nav: average tile build %.2f ms, worst %.2f ms, worst tick %.2f ms, %d tiles built" % [stats.avg_build_ms, stats.max_build_ms, stats.max_tick_ms, stats.builds_committed])
	pawn.free()
	streamer.free()
	terrain.free()
	_settle()


# --- Helpers ---


func _make_terrain(chunk_size: float, chunk_resolution: int, offset: Vector3) -> Terrain:
	var terrain := Terrain.new()
	terrain.name = "Terrain"
	terrain.build_on_start = false
	terrain.chunk_size = chunk_size
	terrain.chunk_resolution = chunk_resolution
	terrain.build_collision = false
	terrain.nav_hooks = NavHooks.new()
	terrain.position = offset
	add_child(terrain)
	return terrain


## A position on the ground, measured from where four chunks meet.
func _on_ground(terrain: Terrain, offset: Vector3, flat: Vector2) -> Vector3:
	var x := offset.x + flat.x
	var z := offset.z + flat.y
	return Vector3(x, terrain.height_at(x, z), z)


func _path_reaches(from: Vector3, to: Vector3) -> bool:
	var path := NavServer.find_path_now(from, to, TIER_SMALLEST)
	return path.size() >= 2 and _flat_distance(path[path.size() - 1], to) < 0.5


func _flat_distance(a: Vector3, b: Vector3) -> float:
	return Vector2(a.x - b.x, a.z - b.z).length()


func _path_length(points: PackedVector3Array) -> float:
	var total := 0.0
	for i in range(1, points.size()):
		total += points[i - 1].distance_to(points[i])
	return total


## Checks about every metre along a path that there's nav under it. Returns the worst distance sideways as x and up or
## down as y. Up or down can't be read from the path itself: Detour only gives corners where a path turns, so the
## straight line between two corners can pass through a hill, even though it's right when seen from above. Whatever
## follows a path has to walk on the ground and take only the direction from it, as StreamingSamplePawn does.
func _worst_off_nav(terrain: Terrain, path: PackedVector3Array, tier: int) -> Vector2:
	var worst := Vector2.ZERO
	for i in range(1, path.size()):
		var samples := maxi(1, int(_flat_distance(path[i - 1], path[i])))
		for s in samples + 1:
			var along := path[i - 1].lerp(path[i], float(s) / samples)
			var on_ground := Vector3(along.x, terrain.height_at(along.x, along.z), along.z)
			var nearest: Variant = NavServer.closest_point(on_ground, tier)
			if nearest == null:
				return Vector2(INF, INF)
			worst.x = maxf(worst.x, _flat_distance(nearest, on_ground))
			worst.y = maxf(worst.y, absf(nearest.y - on_ground.y))
	return worst


func _same_triangles(a: PackedVector3Array, b: PackedVector3Array) -> bool:
	if a.size() != b.size() or a.is_empty():
		return false
	# Tiles may be listed in a different order depending on when each was built, so compare them sorted.
	var sorted_a := _sorted_triangles(a)
	var sorted_b := _sorted_triangles(b)
	return sorted_a == sorted_b


func _sorted_triangles(corners: PackedVector3Array) -> PackedStringArray:
	var triangles := PackedStringArray()
	for i in range(0, corners.size(), 3):
		triangles.append("%.3f,%.3f,%.3f|%.3f,%.3f,%.3f|%.3f,%.3f,%.3f" % [corners[i].x, corners[i].y, corners[i].z, corners[i + 1].x, corners[i + 1].y, corners[i + 1].z, corners[i + 2].x, corners[i + 2].y, corners[i + 2].z])
	triangles.sort()
	return triangles


func _borders_match(terrain: Terrain) -> bool:
	var left: PackedVector3Array = terrain._points[Vector2i(-1, 0)]
	var right: PackedVector3Array = terrain._points[Vector2i(0, 0)]
	var n: int = terrain._points_per_edge()
	for row in n:
		if left[n - 1 + row * n] != right[row * n]:
			return false
	return true


func _settle() -> void:
	for i in 4000:
		NavServer.tick(1.0 / 60.0)
		if i > 2 and NavServer.is_idle():
			return
		OS.delay_msec(2)
	_check(false, "nav became idle within the time limit")


func _check(passed: bool, what: String) -> void:
	print("  %s %s" % ["ok  " if passed else "FAIL", what])
	if not passed:
		_failures += 1
