## Written by Claude (claude-opus-5-5), 2026-11-06: headless self-test for marker types, modules and the debug report.
## The rules it checks are listed at the top of NavMarkerModule.gd and NavMarkerManager.gd.
## Exits 0 on success, 1 on failure. Run from the project folder:
##   "C:\Git\Test 2\Godot_v4.7.2-stable_win64_console.exe" --headless --path . "res://assets/scripts/navigation/tests/nav_markers_selftest.tscn"
## It prints a few warnings on purpose, because the debug report is one of the things being tested.
extends Node

const TERRAIN := 1


## A module that writes down every call it gets, so tests can check exactly what happened.
# GDScript note: "class" inside a script makes a small class only this file uses.
class RecordingModule extends NavMarkerModule:
	var types: Array[Script] = []
	var added_calls: Array[PackedInt64Array] = []
	var changed_calls: Array[PackedInt64Array] = []
	var removed_calls: Array[PackedInt64Array] = []
	var ready_before_first_call := false
	var was_ready := false
	var on_added: Callable # optional: something extra to do during _markers_added

	func _ready() -> void:
		was_ready = true

	func handled_types() -> Array[Script]:
		return types

	func _markers_added(ids: PackedInt64Array) -> void:
		ready_before_first_call = was_ready
		added_calls.append(ids)
		if on_added.is_valid():
			on_added.call(ids)

	func _markers_changed(ids: PackedInt64Array) -> void:
		changed_calls.append(ids)

	func _markers_removed(ids: PackedInt64Array) -> void:
		removed_calls.append(ids)

	func total_added() -> int:
		var total := 0
		for ids in added_calls:
			total += ids.size()
		return total

	func total_removed() -> int:
		var total := 0
		for ids in removed_calls:
			total += ids.size()
		return total


## A modder's own kind of link, to check a module for NavLink handles it too.
class ModdedLink extends NavLink:
	pass


## A module that writes its own _enter_tree and forgets super(), which must not stop it from registering.
class ForgetfulModule extends RecordingModule:
	func _enter_tree() -> void:
		pass

	func _exit_tree() -> void:
		pass


var _failures := 0


func _ready() -> void:
	print("--- Nav markers self-test ---")
	NavMarkerManager.report_quiet_seconds = 1000000.0 # the automatic report stays quiet until its own test
	_test_marker_types()
	_test_modules_get_their_types()
	_test_load_order()
	_test_module_is_ready_first()
	_test_batches()
	_test_changes()
	_test_removal_and_chunk_return()
	_test_module_leaving()
	_test_module_leaving_before_joining()
	_test_module_requests_wait()
	_test_module_removing_another()
	_test_reset()
	_test_forgotten_super()
	_test_unhandled_list()
	await _test_automatic_report()
	_measure_with_modules()
	NavMarkerManager.report_quiet_seconds = 2.0
	NavMarkerManager.reset()
	print("--- ALL PASSED ---" if _failures == 0 else "--- %d FAILED ---" % _failures)
	get_tree().quit(0 if _failures == 0 else 1)


# --- Helpers --------------------------------------------------------------------------------------

## Makes a module, adds it to the tree and lets it join.
func _add_module(types: Array[Script]) -> RecordingModule:
	var module := RecordingModule.new()
	module.types = types
	add_child(module)
	NavMarkerManager.flush()
	return module


## Removes and frees a module right away.
func _free_module(module: Node) -> void:
	remove_child(module)
	module.free()


## Registers these markers as one chunk's list and applies them. Returns their ids.
func _add_chunk(chunk: Vector2i, markers: Array[NavMarker]) -> PackedInt64Array:
	NavMarkerManager.request_markers(TERRAIN, chunk, markers)
	NavMarkerManager.flush()
	var ids := PackedInt64Array()
	for index in markers.size():
		ids.append(NavMarkerManager.chunk_marker_id(TERRAIN, chunk, index))
	return ids


func _link() -> NavLink:
	var marker := NavLink.new()
	marker.tag = &"link.jump"
	return marker


func _point() -> NavPoint:
	var marker := NavPoint.new()
	marker.tag = &"point.cover"
	return marker


func _smart_object() -> NavSmartObject:
	var marker := NavSmartObject.new()
	marker.tag = &"use.seat"
	return marker


func _area() -> NavArea:
	var marker := NavArea.new()
	marker.tag = &"area.road"
	return marker


func _obstacle() -> NavObstacle:
	var marker := NavObstacle.new()
	marker.tag = &"obstacle.crate"
	return marker


# --- Marker types ---------------------------------------------------------------------------------

func _test_marker_types() -> void:
	NavMarkerManager.reset()
	var link := _link()
	link.position = Vector3(1, 2, 3)
	link.end_offset = Vector3(0, 5, 0)
	_check(link.get_end_position() == Vector3(1, 7, 3), "types: a link's end is its position plus its offset")
	_check(link is NavMarker and link is NavLink, "types: a link is a marker")
	_check(not (link as Variant is NavPoint), "types: a link isn't a point")
	_check(_smart_object() is NavPoint, "types: a smart object is a point")
	_check(_area() is NavMarker and _obstacle() is NavMarker, "types: areas and obstacles are markers")
	_check(_obstacle().mode == NavObstacle.Mode.AVOID, "types: an obstacle defaults to avoid, the cheap mode")

	# Hand-placed markers rely on duplicate() to stop copies of a scene sharing one marker.
	var copy: NavLink = link.duplicate()
	copy.end_offset = Vector3(9, 9, 9)
	copy.two_way = false
	_check(link.end_offset == Vector3(0, 5, 0) and link.two_way, "types: changing a duplicate leaves the original alone")
	_check(copy.tag == &"link.jump", "types: a duplicate keeps the original's values")

	var ids := _add_chunk(Vector2i(0, 0), [_link(), _point(), _smart_object(), _area(), _obstacle()])
	_check(NavMarkerManager.get_marker(ids[0]) is NavLink and NavMarkerManager.get_marker(ids[2]) is NavSmartObject, "types: get_marker gives back the real type")
	_check(NavMarkerManager.find_nearest(&"use", Vector3.ZERO, 10.0) == ids[2], "types: search works by tag for every type")


# --- Modules ---------------------------------------------------------------------------------------

func _test_modules_get_their_types() -> void:
	NavMarkerManager.reset()
	var links := _add_module([NavLink])
	var points := _add_module([NavPoint])
	var both := _add_module([NavLink, NavArea])
	var everything := _add_module([NavMarker])
	var nothing := _add_module([])

	var modded := ModdedLink.new()
	modded.tag = &"link.climb"
	var ids := _add_chunk(Vector2i(0, 0), [_link(), _point(), _smart_object(), _area(), modded, _obstacle()])
	_check(links.added_calls == [PackedInt64Array([ids[0], ids[4]])], "modules: a module gets its type and a modder's subclass of it")
	_check(points.added_calls == [PackedInt64Array([ids[1], ids[2]])], "modules: a NavPoint module gets smart objects too")
	_check(both.total_added() == 3, "modules: a module can announce several types, and several modules can share one")
	_check(everything.total_added() == 6, "modules: announcing NavMarker gets everything")
	_check(nothing.added_calls.is_empty(), "modules: announcing nothing gets nothing")

	for module in [links, points, both, everything, nothing]:
		_free_module(module)


func _test_load_order() -> void:
	NavMarkerManager.reset()
	var early := _add_chunk(Vector2i(0, 0), [_link(), _point()])
	var late := _add_module([NavLink])
	_check(late.added_calls == [PackedInt64Array([early[0]])], "load order: a module joining late gets the matching markers already there")
	var later := _add_chunk(Vector2i(1, 0), [_link()])
	_check(late.added_calls.size() == 2 and late.added_calls[1] == later, "load order: and new ones as they arrive")
	# A marker requested but not yet applied must arrive exactly once, whichever way round things happen.
	NavMarkerManager.request_markers(TERRAIN, Vector2i(2, 0), [_link()] as Array[NavMarker])
	var joining := RecordingModule.new()
	joining.types = [NavLink]
	add_child(joining)
	NavMarkerManager.flush()
	_check(joining.total_added() == 3, "load order: a marker applied in the same tick as a module joins arrives once")
	_free_module(late)
	_free_module(joining)


func _test_module_is_ready_first() -> void:
	NavMarkerManager.reset()
	_add_chunk(Vector2i(0, 0), [_link()])
	var module := RecordingModule.new()
	module.types = [NavLink]
	add_child(module)
	_check(module.added_calls.is_empty(), "joining: nothing arrives until the next tick")
	NavMarkerManager.flush()
	_check(module.ready_before_first_call, "joining: so a module's _ready has run before its first call")
	_free_module(module)


func _test_batches() -> void:
	NavMarkerManager.reset()
	var module := _add_module([NavLink])
	var markers: Array[NavMarker] = []
	for index in 250:
		markers.append(_link())
	_add_chunk(Vector2i(0, 0), markers)
	_check(module.added_calls.size() == 1 and module.total_added() == 250, "batches: a chunk of 250 is one call, not 250")
	NavMarkerManager.release_markers(TERRAIN, Vector2i(0, 0))
	NavMarkerManager.flush()
	_check(module.removed_calls.size() == 1 and module.total_removed() == 250, "batches: and leaving is one call too")
	_free_module(module)


func _test_changes() -> void:
	NavMarkerManager.reset()
	var links := _add_module([NavLink])
	var points := _add_module([NavPoint])
	var ids := _add_chunk(Vector2i(0, 0), [_link(), _link(), _point()])
	NavMarkerManager.set_enabled(ids[0], false)
	NavMarkerManager.set_enabled(ids[1], false)
	NavMarkerManager.set_enabled(ids[2], false)
	_check(links.changed_calls.is_empty(), "changes: nothing until the tick")
	NavMarkerManager.flush()
	_check(links.changed_calls == [PackedInt64Array([ids[0], ids[1]])], "changes: switches in a row become one call")
	_check(points.changed_calls == [PackedInt64Array([ids[2]])], "changes: and each module hears only about its own")
	NavMarkerManager.set_enabled(ids[0], false)
	NavMarkerManager.flush()
	_check(links.changed_calls.size() == 1, "changes: setting the same value isn't a change")
	NavMarkerManager.set_enabled(ids[0], true)
	NavMarkerManager.flush()
	_check(links.changed_calls.size() == 2 and NavMarkerManager.is_marker_enabled(ids[0]), "changes: a real change is reported, and modules can read the new state")
	# A marker switched off and removed in one tick: told of the change first, then the removal.
	NavMarkerManager.set_enabled(ids[0], false)
	NavMarkerManager.release_markers(TERRAIN, Vector2i(0, 0))
	NavMarkerManager.flush()
	_check(links.changed_calls.size() == 3 and links.total_removed() == 2, "changes: a switch and a removal in one tick arrive in order")
	_free_module(links)
	_free_module(points)


func _test_removal_and_chunk_return() -> void:
	NavMarkerManager.reset()
	var module := _add_module([NavLink])
	var ids := _add_chunk(Vector2i(0, 0), [_link()])
	NavMarkerManager.release_markers(TERRAIN, Vector2i(0, 0))
	NavMarkerManager.request_markers(TERRAIN, Vector2i(0, 0), [_link()] as Array[NavMarker])
	NavMarkerManager.flush()
	_check(module.removed_calls == [ids] and module.added_calls == [ids, ids], "chunk return: leaving and coming back in one tick is removed, then added")
	var scene_id := NavMarkerManager.request_scene_marker("/root/Level/Ladder", _link())
	NavMarkerManager.flush()
	NavMarkerManager.remove_scene_marker(scene_id)
	NavMarkerManager.flush()
	_check(module.removed_calls[-1] == PackedInt64Array([scene_id]), "removal: hand-placed markers tell modules too")
	_free_module(module)


func _test_module_leaving() -> void:
	NavMarkerManager.reset()
	var first := _add_module([NavLink])
	var second := _add_module([NavLink])
	var ids := _add_chunk(Vector2i(0, 0), [_link(), _point()])
	var first_removed := first.removed_calls # keeps a reference, so it's readable after the module is gone
	remove_child(first)
	_check(first_removed == [PackedInt64Array([ids[0]])], "leaving: a module gets a final call straight away, for exactly what it handled")
	_check(second.removed_calls.is_empty(), "leaving: another module sharing the type hears nothing")
	_check(NavMarkerManager.get_marker(ids[0]) != null, "leaving: the markers stay registered")
	_check(NavMarkerManager.find_nearest(&"link", Vector3.ZERO, 10.0) == ids[0], "leaving: and can still be found")
	first.free()
	var later := _add_chunk(Vector2i(1, 0), [_link()])
	_check(second.added_calls[-1] == later, "leaving: everything carries on for the other module")
	# A pending removal mustn't reach a module that has already said goodbye.
	var third := _add_module([NavLink])
	NavMarkerManager.release_markers(TERRAIN, Vector2i(1, 0))
	var third_removed := third.removed_calls
	remove_child(third)
	var count_at_leaving := third.total_removed()
	NavMarkerManager.flush()
	_check(third.total_removed() == count_at_leaving and third_removed.size() == 1, "leaving: a module gets no calls after it leaves")
	third.free()
	_free_module(second)


func _test_module_leaving_before_joining() -> void:
	NavMarkerManager.reset()
	var module := RecordingModule.new()
	module.types = [NavLink]
	add_child(module)
	_free_module(module) # gone before the tick came
	_add_chunk(Vector2i(0, 0), [_link()]) # this flush would crash if it tried to use the freed module
	_check(NavMarkerManager.get_marker_count() == 1, "leaving early: a module that leaves before joining causes no trouble")


func _test_module_requests_wait() -> void:
	NavMarkerManager.reset()
	var module := _add_module([NavLink])
	var requested := {"done": false}
	# GDScript note: a Dictionary is shared with the small function below, so the function can change it.
	module.on_added = func(_ids: PackedInt64Array) -> void:
		if not requested["done"]:
			requested["done"] = true
			NavMarkerManager.request_markers(TERRAIN, Vector2i(9, 9), [_link()] as Array[NavMarker])
	_add_chunk(Vector2i(0, 0), [_link()])
	_check(requested["done"] and NavMarkerManager.get_pending_count() == 1, "requests in a call: wait for the next tick")
	NavMarkerManager.flush()
	_check(module.total_added() == 2, "requests in a call: and then arrive normally")
	_free_module(module)


func _test_module_removing_another() -> void:
	NavMarkerManager.reset()
	var victim: RecordingModule # declared here so the function below can see it
	var first := _add_module([NavLink])
	victim = _add_module([NavLink])
	first.on_added = func(_ids: PackedInt64Array) -> void:
		if victim != null and victim.get_parent() != null:
			remove_child(victim)
	_add_chunk(Vector2i(0, 0), [_link()]) # would misbehave if it still called the removed module
	_check(victim.added_calls.is_empty(), "module removing another: the removed one gets no more calls")
	victim.free()
	victim = null
	_free_module(first)


func _test_reset() -> void:
	NavMarkerManager.reset()
	var module := _add_module([NavLink])
	var ids := _add_chunk(Vector2i(0, 0), [_link(), _link()])
	NavMarkerManager.reset()
	_check(module.removed_calls == [ids], "reset: modules are told their markers have gone")
	var later := _add_chunk(Vector2i(1, 0), [_link()])
	_check(module.added_calls[-1] == later, "reset: modules stay and keep working")
	_free_module(module)
	var waiting := RecordingModule.new()
	waiting.types = [NavLink]
	add_child(waiting)
	NavMarkerManager.reset()
	_add_chunk(Vector2i(2, 0), [_link()])
	_check(waiting.total_added() == 1, "reset: a module waiting to join still joins")
	_free_module(waiting)


func _test_forgotten_super() -> void:
	NavMarkerManager.reset()
	var module := ForgetfulModule.new()
	module.types = [NavLink]
	add_child(module)
	NavMarkerManager.flush()
	_add_chunk(Vector2i(0, 0), [_link()])
	_check(module.total_added() == 1, "forgotten super: a module with its own _enter_tree still joins")
	var removed := module.removed_calls
	remove_child(module)
	_check(removed.size() == 1, "forgotten super: and one with its own _exit_tree still leaves")
	module.free()


# --- The debug report ------------------------------------------------------------------------------

func _test_unhandled_list() -> void:
	NavMarkerManager.reset()
	_check(NavMarkerManager.get_unhandled_types().is_empty(), "report: no markers, nothing to report")
	_add_chunk(Vector2i(0, 0), [_link(), _link(), _point(), _smart_object()])
	_check(NavMarkerManager.get_unhandled_types() == {"NavLink": 2, "NavPoint": 1, "NavSmartObject": 1}, "report: lists each unclaimed type with its count")
	var points := _add_module([NavPoint])
	_check(NavMarkerManager.get_unhandled_types() == {"NavLink": 2}, "report: a NavPoint module claims smart objects too")
	var everything := _add_module([NavMarker])
	_check(NavMarkerManager.get_unhandled_types().is_empty(), "report: a module for NavMarker claims the lot")
	_free_module(everything)
	_check(NavMarkerManager.get_unhandled_types() == {"NavLink": 2}, "report: a type is unclaimed again when its module leaves")
	NavMarkerManager.release_markers(TERRAIN, Vector2i(0, 0))
	NavMarkerManager.flush()
	_check(NavMarkerManager.get_unhandled_types().is_empty(), "report: a type with no markers left isn't listed")
	_free_module(points)
	var file_only: NavMarker = load("res://assets/scripts/navigation/markers/NavMarker.gd").new()
	file_only.tag = &"point.wander"
	_add_chunk(Vector2i(1, 0), [file_only])
	_check(NavMarkerManager.get_unhandled_types() == {"NavMarker": 1}, "report: a plain NavMarker counts as its own type")
	NavMarkerManager.print_report()


## Uses real ticks and a short quiet time, because timing is the point of this one.
func _test_automatic_report() -> void:
	const QUIET := 0.1
	NavMarkerManager.reset()
	NavMarkerManager.report_quiet_seconds = QUIET
	_add_chunk(Vector2i(0, 0), [_link()])
	_check(NavMarkerManager.get_automatic_report_count() == 0, "automatic: nothing straight away")
	await get_tree().create_timer(QUIET * 3.0).timeout
	_check(NavMarkerManager.get_automatic_report_count() == 1, "automatic: reports once things go quiet")

	_add_chunk(Vector2i(1, 0), [_link()])
	await get_tree().create_timer(QUIET * 3.0).timeout
	_check(NavMarkerManager.get_automatic_report_count() == 1, "automatic: more of the same type doesn't report again, so streaming is quiet")

	_add_chunk(Vector2i(2, 0), [_point()])
	await get_tree().create_timer(QUIET * 3.0).timeout
	_check(NavMarkerManager.get_automatic_report_count() == 2, "automatic: a new unclaimed type reports")

	var module := _add_module([NavLink])
	await get_tree().create_timer(QUIET * 3.0).timeout
	_check(NavMarkerManager.get_automatic_report_count() == 2, "automatic: a type gaining a module doesn't report")
	_free_module(module)
	await get_tree().create_timer(QUIET * 3.0).timeout
	_check(NavMarkerManager.get_automatic_report_count() == 3, "automatic: a type losing its last module reports again")

	# A module arriving before the quiet time is up means there's nothing to report.
	NavMarkerManager.reset()
	NavMarkerManager.report_quiet_seconds = QUIET
	_add_chunk(Vector2i(0, 0), [_link()])
	var in_time := _add_module([NavLink])
	await get_tree().create_timer(QUIET * 3.0).timeout
	_check(NavMarkerManager.get_automatic_report_count() == 0, "automatic: a module arriving in time means no report")
	_free_module(in_time)

	NavMarkerManager.reset()
	NavMarkerManager.report_unhandled = false
	_add_chunk(Vector2i(0, 0), [_link()])
	await get_tree().create_timer(QUIET * 3.0).timeout
	_check(NavMarkerManager.get_automatic_report_count() == 0, "automatic: the off switch works")
	_check(NavMarkerManager.get_unhandled_types().size() == 1, "automatic: and the list is still there on demand")
	NavMarkerManager.report_unhandled = true
	NavMarkerManager.report_quiet_seconds = 1000000.0


# --- Cost ------------------------------------------------------------------------------------------

## What modules add when a lot of markers arrive. Printed, not checked, because it depends on the machine.
func _measure_with_modules() -> void:
	const CHUNKS := 400
	const PER_CHUNK := 250
	var lists: Array = []
	for chunk_number in CHUNKS:
		var markers: Array[NavMarker] = []
		for index in PER_CHUNK:
			var marker := _link()
			marker.position = Vector3(chunk_number, 0, index)
			markers.append(marker)
		lists.append(markers)

	NavMarkerManager.reset()
	var no_modules := _timed_register(lists)
	NavMarkerManager.reset()
	var one := _add_module([NavLink])
	var two := _add_module([NavMarker])
	var with_modules := _timed_register(lists)
	var start := Time.get_ticks_usec()
	remove_child(one)
	var leaving_ms := (Time.get_ticks_usec() - start) / 1000.0
	one.free()
	_check(two.total_added() == CHUNKS * PER_CHUNK, "cost: every marker reached the module")
	print("        applying 100,000 markers: %.1f ms with no modules, %.1f ms with two" % [no_modules, with_modules])
	print("        a module leaving, with 100,000 markers registered: %.1f ms" % leaving_ms)
	_free_module(two)


func _timed_register(lists: Array) -> float:
	for chunk_number in lists.size():
		var markers: Array[NavMarker] = lists[chunk_number]
		NavMarkerManager.request_markers(TERRAIN, Vector2i(chunk_number, 0), markers)
	var start := Time.get_ticks_usec()
	NavMarkerManager.flush()
	return (Time.get_ticks_usec() - start) / 1000.0


func _check(ok: bool, what: String) -> void:
	print(("  PASS  " if ok else "  FAIL  ") + what)
	if not ok:
		_failures += 1
