## Written by Claude (claude-opus-5-5), 2026-11-06: headless self-test for NavMarkerNode, NavMarkerDebugModule and the sample scene.
## The rules it checks are listed at the top of those two scripts.
## Exits 0 on success, 1 on failure. Run from the project folder:
##   "C:\Git\Test 2\Godot_v4.7.2-stable_win64_console.exe" --headless --path . "res://assets/scripts/navigation/tests/nav_marker_node_selftest.tscn"
## It prints a few warnings on purpose, because some checks use bad setups.
extends Node

var _failures := 0


func _ready() -> void:
	print("--- Nav marker node self-test ---")
	NavWorld.report_quiet_seconds = 1000000.0 # the automatic report stays quiet in this test
	_test_registers_and_leaves()
	_test_placement()
	_test_copies_dont_share()
	_test_enabling()
	_test_bad_setups()
	_test_reentering()
	_test_debug_module_draws()
	_test_debug_module_limit()
	_test_debug_module_and_report()
	await _test_debug_module_rebuilds_by_itself()
	_test_sample_scene()
	NavWorld.report_quiet_seconds = 2.0
	NavWorld.reset()
	print("--- ALL PASSED ---" if _failures == 0 else "--- %d FAILED ---" % _failures)
	get_tree().quit(0 if _failures == 0 else 1)


## Makes a node holding a marker with this tag, without adding it to the tree.
func _make_node(node_name: String, tag: StringName, position := Vector3.ZERO) -> NavMarkerNode:
	var node := NavMarkerNode.new()
	if node_name != "": # with no name set, Godot gives the node an automatic one when it's added
		node.name = node_name
	node.position = position
	var marker := NavPoint.new()
	marker.tag = tag
	node.marker = marker
	return node


func _test_registers_and_leaves() -> void:
	NavWorld.reset()
	var node := _make_node("Spot", &"point.cover", Vector3(3, 0, 4))
	_check(node.get_marker_id() == 0, "registering: no id before it's in the scene")
	add_child(node)
	var id := node.get_marker_id()
	_check(id != 0, "registering: gets an id on entering the scene")
	_check(id == NavWorld.scene_marker_id(str(node.get_path())), "registering: the id comes from its scene path")
	NavWorld.flush()
	_check(NavWorld.find_nearest(&"point.cover", Vector3.ZERO, 10.0) == id, "registering: can be found after the tick")
	remove_child(node)
	_check(node.get_marker_id() == 0, "leaving: it has no id afterwards")
	NavWorld.flush()
	_check(NavWorld.get_marker(id) == null and NavWorld.get_marker_count() == 0, "leaving: the marker is removed")
	node.free()


func _test_placement() -> void:
	NavWorld.reset()
	var parent := Node3D.new()
	parent.position = Vector3(10, 0, 0)
	add_child(parent)
	var node := _make_node("Child", &"point.cover", Vector3(0, 2, 5))
	parent.add_child(node)
	NavWorld.flush()
	var id := node.get_marker_id()
	_check(NavWorld.get_marker_position(id) == Vector3(10, 2, 5), "placing: uses the node's world position, parents included")
	node.position = Vector3(99, 99, 99)
	NavWorld.flush()
	_check(NavWorld.get_marker_position(id) == Vector3(10, 2, 5), "placing: moving the node afterwards doesn't move the marker")
	var original_marker: NavMarker = node.marker
	_check(original_marker.position == Vector3.ZERO, "placing: the node's own marker is left as it was, and the copy is what's placed")
	parent.free()

	# Turning a placed link a quarter turn should turn where it ends and which way it faces.
	NavWorld.reset()
	var link_node := NavMarkerNode.new()
	link_node.name = "Link"
	var link := NavLink.new()
	link.tag = &"link.jump"
	link.end_offset = Vector3(0, 0, -5)
	link_node.marker = link
	link_node.position = Vector3(1, 0, 1)
	link_node.rotation_degrees = Vector3(0, 90, 0) # a quarter turn to the left, seen from above
	add_child(link_node)
	var placed: NavLink = NavWorld.get_marker(link_node.get_marker_id())
	_check(placed.end_offset.is_equal_approx(Vector3(-5, 0, 0)), "placing: turning a link turns its end")
	_check(placed.get_end_position().is_equal_approx(Vector3(-4, 0, 1)), "placing: and its end position follows")
	_check(placed.facing.is_equal_approx(Vector3(-1, 0, 0)), "placing: and which way it faces")
	_check(link.end_offset == Vector3(0, 0, -5), "placing: the node's own marker isn't turned, so re-entering won't turn it twice")
	link_node.free()


## The case the copy exists for: one marker resource shared by every instance of a scene.
func _test_copies_dont_share() -> void:
	NavWorld.reset()
	var shared := NavPoint.new()
	shared.tag = &"use.seat"
	var first := NavMarkerNode.new()
	first.name = "First"
	first.marker = shared
	first.position = Vector3(1, 0, 0)
	var second := NavMarkerNode.new()
	second.name = "Second"
	second.marker = shared
	second.position = Vector3(2, 0, 0)
	add_child(first)
	add_child(second)
	NavWorld.flush()
	_check(NavWorld.get_marker(first.get_marker_id()) != NavWorld.get_marker(second.get_marker_id()), "copies: two nodes sharing a marker each register their own copy")
	_check(NavWorld.get_marker_position(first.get_marker_id()) == Vector3(1, 0, 0) and NavWorld.get_marker_position(second.get_marker_id()) == Vector3(2, 0, 0), "copies: each keeps its own position")
	first.set_marker_enabled(false)
	NavWorld.flush()
	_check(not NavWorld.is_marker_enabled(first.get_marker_id()) and NavWorld.is_marker_enabled(second.get_marker_id()), "copies: disabling one leaves the other alone, so one door doesn't open them all")
	first.free()
	second.free()


func _test_enabling() -> void:
	NavWorld.reset()
	var node := _make_node("Door", &"link.door")
	node.set_marker_enabled(false) # not in the scene yet, so nothing should happen
	add_child(node)
	NavWorld.flush()
	_check(NavWorld.is_marker_enabled(node.get_marker_id()), "enabling: a call before it's registered does nothing")
	node.set_marker_enabled(false)
	NavWorld.flush()
	_check(not NavWorld.is_marker_enabled(node.get_marker_id()), "enabling: switches it off")
	node.free()


func _test_bad_setups() -> void:
	NavWorld.reset()
	var empty := NavMarkerNode.new()
	empty.name = "Empty"
	add_child(empty)
	NavWorld.flush()
	_check(empty.get_marker_id() == 0 and NavWorld.get_marker_count() == 0, "bad setups: no marker registers nothing, with no error")
	_check(empty._get_configuration_warnings().size() == 1, "bad setups: and shows an inspector warning")
	empty.free()

	var undeclared := _make_node("Undeclared", &"not.declared.anywhere")
	add_child(undeclared)
	_check(undeclared.get_marker_id() == 0, "bad setups: an undeclared tag is refused")
	_check(undeclared._get_configuration_warnings().size() == 1, "bad setups: and shows an inspector warning")
	undeclared.free()

	var no_tag := _make_node("NoTag", &"")
	add_child(no_tag)
	_check(no_tag.get_marker_id() == 0, "bad setups: no tag is refused")
	_check(no_tag._get_configuration_warnings().size() == 1, "bad setups: and shows an inspector warning")
	no_tag.free()

	var good := _make_node("Good", &"point.cover")
	add_child(good)
	_check(good._get_configuration_warnings().is_empty(), "bad setups: a good one shows no warning")
	good.free()

	var unnamed := _make_node("", &"point.cover")
	add_child(unnamed)
	NavWorld.flush()
	_check(String(unnamed.name).begins_with("@"), "bad setups: a node with no name gets an automatic one starting with @")
	_check(unnamed.get_marker_id() != 0, "bad setups: an automatic name warns but still works")
	unnamed.free()
	NavWorld.flush()


func _test_reentering() -> void:
	NavWorld.reset()
	var node := _make_node("Spot", &"point.cover")
	add_child(node)
	NavWorld.flush()
	var id := node.get_marker_id()
	remove_child(node)
	add_child(node) # out and back in, in the same tick
	NavWorld.flush()
	_check(node.get_marker_id() == id, "re-entering: same path, same id")
	_check(NavWorld.get_marker_count() == 1, "re-entering: one marker, not two")
	_check(NavWorld.find_in_radius(&"point.cover", Vector3.ZERO, 10.0).size() == 1, "re-entering: found once")
	node.free()
	NavWorld.flush()


func _test_debug_module_draws() -> void:
	NavWorld.reset()
	var debug := NavMarkerDebugModule.new()
	add_child(debug)
	NavWorld.flush()
	var point := NavPoint.new()
	point.tag = &"point.cover"
	var link := NavLink.new()
	link.tag = &"link.jump"
	var area := NavArea.new()
	area.tag = &"area.road"
	var markers: Array[NavMarker] = [point, link, area]
	NavWorld.request_markers(1, Vector2i.ZERO, markers)
	NavWorld.flush()
	debug.rebuild_now()
	_check(debug.get_drawn_count() == 3, "debug drawing: draws every marker")
	# A point: 3 for the cross + 1 facing. A link: the same + 1. An area: the same + 12 box edges.
	_check(debug.get_line_count() == 4 + 5 + 16, "debug drawing: each type gets its lines")
	NavWorld.set_enabled(NavWorld.chunk_marker_id(1, Vector2i.ZERO, 0), false)
	NavWorld.flush()
	debug.rebuild_now()
	_check(debug.get_drawn_count() == 3, "debug drawing: a disabled marker is still drawn")
	NavWorld.release_markers(1, Vector2i.ZERO)
	NavWorld.flush()
	debug.rebuild_now()
	_check(debug.get_drawn_count() == 0 and debug.get_line_count() == 0, "debug drawing: removed markers disappear")
	debug.free()


func _test_debug_module_limit() -> void:
	NavWorld.reset()
	var debug := NavMarkerDebugModule.new()
	debug.max_drawn = 5
	add_child(debug)
	var markers: Array[NavMarker] = []
	for index in 20:
		var point := NavPoint.new()
		point.tag = &"point.cover"
		markers.append(point)
	NavWorld.request_markers(1, Vector2i.ZERO, markers)
	NavWorld.flush()
	debug.rebuild_now()
	_check(debug.get_drawn_count() == 5, "debug drawing: stops at its limit, and warns once")
	debug.free()
	NavWorld.flush()


## A debug drawing must not hide that nothing actually acts on the markers.
func _test_debug_module_and_report() -> void:
	NavWorld.reset()
	var debug := NavMarkerDebugModule.new()
	add_child(debug)
	NavWorld.flush()
	var link := NavLink.new()
	link.tag = &"link.jump"
	var markers: Array[NavMarker] = [link]
	NavWorld.request_markers(1, Vector2i.ZERO, markers)
	NavWorld.flush()
	_check(NavWorld.get_unhandled_types() == {"NavLink": 1}, "debug drawing: doesn't count as handling a type in the report")
	debug.free()
	NavWorld.flush()


func _test_debug_module_rebuilds_by_itself() -> void:
	NavWorld.reset()
	var debug := NavMarkerDebugModule.new()
	debug.rebuild_interval = 0.0
	add_child(debug)
	NavWorld.flush()
	var point := NavPoint.new()
	point.tag = &"point.cover"
	var markers: Array[NavMarker] = [point]
	NavWorld.request_markers(1, Vector2i.ZERO, markers)
	NavWorld.flush()
	await get_tree().process_frame
	await get_tree().process_frame
	_check(debug.get_drawn_count() == 1, "debug drawing: rebuilds by itself when markers change")
	debug.free()
	NavWorld.flush()


func _test_sample_scene() -> void:
	NavWorld.reset()
	# Claude 2026-11-06: the sample scenes moved to assets/scenes/samples.
	var sample: Node = load("res://assets/scenes/samples/nav_marker_sample.tscn").instantiate()
	add_child(sample)
	NavWorld.flush()
	_check(NavWorld.get_marker_count() == 7, "sample scene: all seven markers register")
	_check(NavWorld.get_marker(sample.get_node("Ladder").get_marker_id()) is NavLink, "sample scene: types survive being loaded from a file")
	var bench: NavSmartObject = NavWorld.get_marker(sample.get_node("Bench").get_marker_id())
	_check(bench.slot_count == 2 and bench.tag == &"use.seat", "sample scene: values survive being loaded from a file")
	_check(not NavWorld.is_marker_enabled(sample.get_node("DisabledPatrol").get_marker_id()), "sample scene: starts_enabled = false is respected")
	_check(NavWorld.find_nearest(&"use", Vector3.ZERO, 100.0) == sample.get_node("Bench").get_marker_id(), "sample scene: search finds a placed marker")
	var debug: NavMarkerDebugModule = sample.get_node("NavMarkerDebugModule")
	debug.rebuild_now()
	_check(debug.get_drawn_count() == 7, "sample scene: the debug module draws them all")
	# The module's _ready ran before the sample's other nodes entered, so this also shows load order doesn't matter.
	sample.free()
	NavWorld.flush()
	_check(NavWorld.get_marker_count() == 0, "sample scene: freeing it removes every marker")


func _check(ok: bool, what: String) -> void:
	print(("  PASS  " if ok else "  FAIL  ") + what)
	if not ok:
		_failures += 1
