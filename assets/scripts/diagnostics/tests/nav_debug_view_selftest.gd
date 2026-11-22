## Written by Claude (claude-opus-5-5), 2026-11-17: headless self-test for NavDebugView: hidden it draws nothing and has no marker
## drawer; shown it draws the nav mesh, the links and the markers; hidden again it frees the marker drawer.
## Exits 0 on success, 1 on failure. Run from the project folder:
##   godot --headless --path . "res://assets/scripts/diagnostics/tests/nav_debug_view_selftest.tscn"
extends SelfTest


func _ready() -> void:
	print("--- Nav debug view self-test ---")
	await _test_toggle()
	print("--- ALL PASSED ---" if _failures == 0 else "--- %d FAILED ---" % _failures)
	get_tree().quit(0 if _failures == 0 else 1)


func _test_toggle() -> void:
	var nav: Object = Engine.get_singleton(&"NavServer") if Engine.has_singleton(&"NavServer") else null
	var ground: StaticBody3D = null
	var interest := -1
	var link := 0
	if nav:
		nav.configure({"worker_threads": 2})
		ground = StaticBody3D.new()
		var shape := CollisionShape3D.new()
		var box := BoxShape3D.new()
		box.size = Vector3(30, 1, 30)
		shape.shape = box
		ground.add_child(shape)
		ground.add_child(BodyNavFeeder.new())
		ground.position = Vector3(0, -0.5, 0)
		add_child(ground)
		interest = nav.add_interest(Vector3.ZERO, 30.0, 40.0, 1)
		for i in 2000:
			nav.tick(1.0 / 60.0)
			if i > 2 and nav.is_idle():
				break
			OS.delay_msec(2)
		link = nav.add_link(Vector3(-5, 0, 0), Vector3(5, 0, 3), false)
		for i in 2000: # a placed link goes in when the tiles under its ends rebuild
			nav.tick(1.0 / 60.0)
			if i > 2 and nav.is_idle():
				break
			OS.delay_msec(2)
	var point := NavMarkerNode.new()
	var marker := NavPoint.new()
	marker.tag = &"nav.point.cover"
	point.marker = marker
	point.name = "CoverPoint"
	add_child(point)
	var view := NavDebugView.new()
	add_child(view)
	await get_tree().physics_frame
	await get_tree().physics_frame # NavMarkerManager applies registrations on its tick
	_check(not view.visible and view.get_marker_drawer() == null, "it starts hidden, with no marker drawer")
	_check(view.get_triangle_count() == 0, "and draws no nav mesh")
	view.set_shown(true)
	_check(view.shown and view.visible, "set_shown(true) shows it")
	view.rebuild_now()
	await get_tree().physics_frame
	await get_tree().physics_frame
	await get_tree().process_frame
	if nav:
		_check(view.get_triangle_count() > 0, "the nav mesh is drawn (%d triangles)" % view.get_triangle_count())
		_check(view.get_link_count() == 1, "and the link (%d)" % view.get_link_count())
	var drawer := view.get_marker_drawer()
	if drawer:
		drawer.rebuild_now()
	_check(drawer != null and drawer.get_drawn_count() == 1, "and the cover point, by its marker drawer (%d)" % (drawer.get_drawn_count() if drawer else -1))
	view.set_shown(false)
	await get_tree().process_frame
	_check(not view.visible and view.get_marker_drawer() == null and not is_instance_valid(drawer), "hidden again, it frees the marker drawer")
	view.free()
	point.free()
	if nav:
		nav.remove_link(link)
		nav.remove_interest(interest)
		ground.free()
