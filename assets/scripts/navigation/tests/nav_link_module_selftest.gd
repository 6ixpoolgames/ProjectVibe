## Written by Claude (claude-opus-5-5), 2026-11-08: headless self-test for NavLinkModule, which hands placed NavLink markers to nav.
## Uses the course from nav_links_selftest, where nothing leads from the low platform C back up to B, so a placed link is the only
## way up. Exits 0 on success, 1 on failure. Run from the project folder:
##   "C:\Git\Test 2\Godot_v4.7.2-stable_win64_console.exe" --headless --path . "res://assets/scripts/navigation/tests/nav_link_module_selftest.tscn"
extends Node

const Course := preload("res://assets/scripts/navigation/tests/nav_links_selftest.gd")
const ON_C := Vector3(16, -2, 0)
const ON_B := Vector3(6, 0, 0)

var _failures := 0


func _ready() -> void:
	print("--- Nav link module self-test ---")
	NavMarkerManager.reset()
	NavServer.configure({"worker_threads": 4})
	var layer := Course.build_course()
	var interest: int = NavServer.add_interest(Vector3(4, 0, 0), 45.0, 60.0, 1)
	_settle()
	_check(not _reaches(ON_C, ON_B), "before: no way from C up to B")

	var module := NavLinkModule.new()
	add_child(module)
	var ladder := NavLink.new()
	ladder.tag = &"link.climb"
	ladder.position = Vector3(13.5, -2, 0)
	ladder.end_offset = Vector3(-3, 2, 0)
	ladder.two_way = false
	ladder.press_action = &"climb"
	var marker_id := NavMarkerManager.request_scene_marker("res://test/ladder", ladder)
	_check(marker_id != 0, "a placed NavLink marker is accepted")
	NavMarkerManager.flush()
	_check(module.get_link_count() == 1 and module.get_link_id(marker_id) > 0, "the module hands it to nav")
	_settle()
	var path: Dictionary = NavServer.find_path_now_with_links(ON_C, ON_B)
	var link_id := module.get_link_id(marker_id)
	_check(not path.partial and path.link_ids.has(link_id), "and once the tile rebuilds, C reaches B up it")
	_check(NavServer.get_link_action(link_id) == &"climb", "pressing the marker's press_action")
	_check(NavLink.new().press_action == &"jump", "a new NavLink presses jump unless told otherwise")

	NavMarkerManager.set_enabled(marker_id, false)
	NavMarkerManager.flush()
	_settle()
	_check(module.get_link_count() == 0 and not _reaches(ON_C, ON_B), "disabling the marker takes the link away")
	NavMarkerManager.set_enabled(marker_id, false)
	NavMarkerManager.flush()
	_check(module.get_link_count() == 0, "disabling it again changes nothing")
	NavMarkerManager.set_enabled(marker_id, true)
	NavMarkerManager.flush()
	_settle()
	_check(module.get_link_count() == 1 and _reaches(ON_C, ON_B), "enabling it brings the link back")

	module.free() # leaving: a final _markers_removed undoes what it did
	_settle()
	_check(not _reaches(ON_C, ON_B), "the module leaving takes its link away")
	_check(NavMarkerManager.get_marker(marker_id) != null, "and the marker stays registered, since it belongs to NavMarkerManager")

	NavMarkerManager.remove_scene_marker(marker_id)
	NavMarkerManager.flush()
	NavServer.remove_interest(interest)
	NavServer.remove_input_layer(layer)
	_settle()
	print("--- ALL PASSED ---" if _failures == 0 else "--- %d FAILED ---" % _failures)
	get_tree().quit(0 if _failures == 0 else 1)


func _reaches(from: Vector3, to: Vector3) -> bool:
	var path: Dictionary = NavServer.find_path_now_with_links(from, to)
	return not path.points.is_empty() and not path.partial


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
