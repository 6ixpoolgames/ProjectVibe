## Written by Claude (claude-opus-5-5), 2026-11-08: headless self-test for nav links (nav spec sections 10 and 19, phase 3): the
## links a tile build finds by itself at ledges and gaps, placed links from NavServer.add_link, and paths that cross them.
## Exits 0 on success, 1 on failure. Run from the project folder:
##   "C:\Git\Test 2\Godot_v4.7.2-stable_win64_console.exe" --headless --path . "res://assets/scripts/navigation/tests/nav_links_selftest.tscn"
##
## The test world is boxes fed in as meshes, along X, each 6 m wide in Z (see build_course(), which the navigation manager's
## test borrows):
##   A  x -20 .. -1.5, top at 0       a 2 m gap with nothing under it, then
##   B  x 0.5 .. 12,   top at 0       a 2 m drop down to
##   C  x 12 .. 20,    top at -2      a 0.8 m step up to
##   D  x 20 .. 28,    top at -1.2
## So: jumps both ways between A and B, a drop from B to C and no way back up, a jump up from C to D and a drop back down.
extends Node

const AREA := AABB(Vector3(-30, -10, -10), Vector3(70, 20, 20))

var _failures := 0


## The course's boxes, as [lowest corner, highest corner] pairs. Shared with navigation_manager_selftest, which adds collision.
static func course_boxes() -> Array:
	return [
		[Vector3(-20, -1, -3), Vector3(-1.5, 0, 3)], # A
		[Vector3(0.5, -1, -3), Vector3(12, 0, 3)], # B
		[Vector3(12, -3, -3), Vector3(20, -2, 3)], # C
		[Vector3(20, -2.2, -3), Vector3(28, -1.2, 3)], # D
	]


## Feeds the course to nav as one mesh layer. Returns the layer.
static func build_course() -> int:
	var layer: int = NavServer.add_input_layer(null, NavHooks.new(), NavServer.ADAPTER_MESH)
	var id := 1
	for box: Array in course_boxes():
		# Godot's own BoxMesh, so the triangles face the way submit_mesh expects, as any mesh from a scene would.
		var lo: Vector3 = box[0]
		var hi: Vector3 = box[1]
		var mesh := BoxMesh.new()
		mesh.size = hi - lo
		NavServer.submit_mesh(layer, id, mesh.get_faces(), Transform3D(Basis.IDENTITY, (lo + hi) * 0.5))
		id += 1
	return layer


func _ready() -> void:
	print("--- Nav links self-test ---")
	NavServer.configure({"worker_threads": 4})
	var layer := build_course()
	var interest: int = NavServer.add_interest(Vector3(4, 0, 0), 45.0, 60.0, 1)
	_settle()
	var stats: Dictionary = NavServer.get_stats()
	_check(stats.ready > 0 and stats.failed == 0, "the course builds (%d tiles, %.2f ms a tile on average)" % [stats.ready, stats.avg_build_ms])

	_test_links_found()
	_test_paths_cross_links()
	_test_placed_links()
	_test_switching_auto_links_off()

	NavServer.remove_interest(interest)
	NavServer.remove_input_layer(layer)
	_settle()
	print("--- ALL PASSED ---" if _failures == 0 else "--- %d FAILED ---" % _failures)
	get_tree().quit(0 if _failures == 0 else 1)


func _test_links_found() -> void:
	var found := _links_by_place()
	print("  (links found: %s)" % str(found))
	_check(found.get("A>B jump", 0) > 0 and found.get("B>A jump", 0) > 0, "a level gap gets a jump each way")
	_check(found.get("B>C drop", 0) > 0, "a 2 m ledge gets a drop down")
	_check(found.get("C>B jump", 0) == 0 and found.get("C>B drop", 0) == 0, "and nothing back up, because 2 m is higher than a jump")
	_check(found.get("C>D jump", 0) > 0, "a 0.8 m step gets a jump up")
	_check(found.get("D>C drop", 0) > 0, "and a drop back down")
	var odd := 0
	for key: String in found:
		if not key in ["A>B jump", "B>A jump", "B>C drop", "C>D jump", "D>C drop"]:
			odd += found[key]
	_check(odd == 0, "and no other links, such as off the course's outer edges where there's nowhere to land")
	var config: Dictionary = NavServer.get_config()
	_check(config.auto_links and config.border_cells * config.cell_size >= config.link_jump_distance, "the tile border reaches a full jump past a tile's edge")
	var total := 0
	var auto := 0
	for tile: Dictionary in NavServer.get_tile_states():
		total += tile.links
		auto += tile.auto_links
	_check(total == auto and auto > 0, "tile states count the links (%d, all found automatically)" % auto)


func _test_paths_cross_links() -> void:
	# A to B: only by jumping the gap.
	var across: Dictionary = NavServer.find_path_now_with_links(Vector3(-10, 0, 0), Vector3(6, 0, 0))
	var points: PackedVector3Array = across.points
	var link_ids: PackedInt64Array = across.link_ids
	_check(points.size() >= 3 and link_ids.size() == points.size(), "a path from A to B (%d points)" % points.size())
	var jump_at := _first_link(link_ids)
	_check(jump_at >= 0 and NavServer.get_link_action(link_ids[jump_at]) == &"jump" and NavServer.is_auto_link(link_ids[jump_at]),
			"crosses the gap by a jump link, whose action is jump")
	if jump_at >= 0:
		_check(points[jump_at].x < -1.5 and points[jump_at + 1].x > 0.5, "starting on A and ending on B (%.1f to %.1f)" % [points[jump_at].x, points[jump_at + 1].x])
	_check(not across.partial and points[-1].distance_to(Vector3(6, 0, 0)) < 0.5, "and reaching the goal")
	var walking: PackedVector3Array = NavServer.find_path_now(Vector3(-10, 0, 0), Vector3(6, 0, 0))
	_check(walking.is_empty() or walking[-1].x < -1.0, "find_path_now still never crosses links, so older callers get the paths they always did")

	# B down to C, and C can't get back up.
	var down: Dictionary = NavServer.find_path_now_with_links(Vector3(6, 0, 0), Vector3(16, -2, 0))
	var down_at := _first_link(down.link_ids)
	_check(down_at >= 0 and NavServer.get_link_action(down.link_ids[down_at]) == &"", "B to C drops off the ledge, a link with no action: walk off")
	var up: Dictionary = NavServer.find_path_now_with_links(Vector3(16, -2, 0), Vector3(6, 0, 0))
	_check(up.points.is_empty() or up.partial, "C to B has no way up")

	# C up to D by the step.
	var step: Dictionary = NavServer.find_path_now_with_links(Vector3(16, -2, 0), Vector3(24, -1.2, 0))
	var step_at := _first_link(step.link_ids)
	_check(step_at >= 0 and NavServer.get_link_action(step.link_ids[step_at]) == &"jump", "C to D jumps up the step")


func _test_placed_links() -> void:
	# A ladder from C up to B, which nothing found by itself.
	var ladder: int = NavServer.add_link(Vector3(13.5, -2, 0), Vector3(10.5, 0, 0), false, &"climb")
	_check(ladder > 0, "add_link gives an id")
	_settle()
	var up: Dictionary = NavServer.find_path_now_with_links(Vector3(16, -2, 0), Vector3(6, 0, 0))
	var at := _first_link(up.link_ids)
	_check(not up.partial and at >= 0 and up.link_ids[at] == ladder, "once the tile rebuilds, C to B goes up the placed link")
	_check(NavServer.get_link_action(ladder) == &"climb" and not NavServer.is_auto_link(ladder), "which presses its own action, climb")
	var back: Dictionary = NavServer.find_path_now_with_links(Vector3(6, 0, 0), Vector3(16, -2, 0))
	_check(not back.link_ids.has(ladder), "a one-way link isn't used backwards")
	var debug: Dictionary = NavServer.get_debug_links(AREA)
	_check(debug.link_ids.has(ladder), "get_debug_links lists it")
	_check(NavServer.remove_link(ladder) and not NavServer.remove_link(ladder), "remove_link removes it, once")
	_settle()
	var gone: Dictionary = NavServer.find_path_now_with_links(Vector3(16, -2, 0), Vector3(6, 0, 0))
	_check(gone.points.is_empty() or gone.partial, "and the way up is gone again")
	_check(NavServer.get_link_action(ladder) == &"", "a removed link has no action")


func _test_switching_auto_links_off() -> void:
	NavServer.configure({"worker_threads": 4, "auto_links": false})
	_settle()
	_check(NavServer.get_debug_links(AREA).link_ids.is_empty(), "auto_links off: no links are found")
	var across: Dictionary = NavServer.find_path_now_with_links(Vector3(-10, 0, 0), Vector3(6, 0, 0))
	_check(across.points.is_empty() or across.partial, "and the gap can't be crossed")
	NavServer.configure({"worker_threads": 4, "auto_links": true})
	_settle()
	_check(not NavServer.get_debug_links(AREA).link_ids.is_empty(), "back on: they're found again")


# --- Helpers ---


## Counts the live links by which boxes they join and their kind, such as "A>B jump".
func _links_by_place() -> Dictionary:
	var debug: Dictionary = NavServer.get_debug_links(AREA)
	var counts := {}
	for i in debug.link_ids.size():
		var kind := "jump" if NavServer.get_link_action(debug.link_ids[i]) == &"jump" else "drop"
		var key := "%s>%s %s" % [_box_at(debug.starts[i]), _box_at(debug.ends[i]), kind]
		counts[key] = counts.get(key, 0) + 1
	return counts


func _box_at(point: Vector3) -> String:
	var names := ["A", "B", "C", "D"]
	var boxes := course_boxes()
	for i in boxes.size():
		var lo: Vector3 = boxes[i][0]
		var hi: Vector3 = boxes[i][1]
		if point.x >= lo.x - 0.01 and point.x <= hi.x + 0.01 and absf(point.y - hi.y) < 0.3:
			return names[i]
	return "?"


func _first_link(link_ids: PackedInt64Array) -> int:
	for i in link_ids.size():
		if link_ids[i] != 0:
			return i
	return -1


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
