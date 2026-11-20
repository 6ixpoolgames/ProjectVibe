## Written by Claude (claude-opus-5-5), 2026-11-21: headless self-test for the "place what's drawn" pass: VisualPlacement (C++) and
## VisualPlacementGD place Visuals the same way: gliding by the tick fraction, across a whole run for a run longer than a tick, snaps,
## corrections fading, slots reused, a freed Visual skipped. Exits 0 on success, 1 on failure.
extends SelfTest


func _ready() -> void:
	print("--- Visual placement self-test ---")
	var kinds: Array = [["GDScript", func() -> Object: return VisualPlacementGD.new()]]
	if ClassDB.class_exists(&"VisualPlacement"):
		kinds.push_front(["C++", func() -> Object: return ClassDB.instantiate(&"VisualPlacement")])
	else:
		_check(false, "the navcore library has VisualPlacement (rebuild native/ with the editor closed)")
	for kind in kinds:
		print("  [%s]" % kind[0])
		_test_placing(kind[1].call())
	if kinds.size() == 2:
		_test_twins(kinds[0][1].call(), kinds[1][1].call())
	_finish()


func _visual() -> Node3D:
	var visual := Node3D.new()
	var model := Node3D.new()
	model.name = "Model"
	visual.add_child(model)
	add_child(visual)
	return visual


func _test_placing(placement: Object) -> void:
	var visual := _visual()
	var model: Node3D = visual.get_node("Model")
	var slot: int = placement.add(visual, model, Vector3(1, 0, 0), 0.0)
	_check(slot == 0 and placement.get_count() == 1, "add gives a slot")
	placement.place(10, 0.5, 0.016, true)
	_check(visual.global_position == Vector3(1, 0, 0), "a new slot stands where it was added")
	placement.note_run(slot, Vector3(3, 0, 0), PI / 2, 1, 10)
	placement.place(10, 0.5, 0.016, true)
	_check(visual.global_position.is_equal_approx(Vector3(2, 0, 0)) and is_equal_approx(model.rotation.y, PI / 4),
			"a one-tick run glides by the tick fraction, the model turning with it")
	placement.note_run(slot, Vector3(7, 0, 0), PI / 2, 4, 12)
	placement.place(13, 0.0, 0.016, true)
	_check(visual.global_position.is_equal_approx(Vector3(4, 0, 0)), "a four-tick run is glided across in full (%s)" % visual.global_position)
	placement.place(13, 0.0, 0.016, false)
	_check(visual.global_position.is_equal_approx(Vector3(3, 0, 0)), "without a tick driver, every glide is one tick")
	placement.snap(slot, Vector3(-5, 0, 0), 1.0)
	placement.place(13, 0.5, 0.016, true)
	_check(visual.global_position == Vector3(-5, 0, 0) and is_equal_approx(model.rotation.y, 1.0), "a snap goes straight there")
	placement.note_moved(slot, Vector3(-4, 0, 0), 1.0)
	placement.place(13, 0.5, 0.016, true)
	_check(visual.global_position.is_equal_approx(Vector3(-4.5, 0, 0)), "a move between snapshots glides over one tick")
	placement.snap(slot, Vector3.ZERO, 0.0)
	placement.add_correction(slot, Vector3(2, 0, 0))
	placement.place(13, 1.0, 0.0, true)
	_check(visual.global_position.is_equal_approx(Vector3(2, 0, 0)), "a correction shows as an offset at first")
	for i in 30:
		placement.place(13, 1.0, 0.016, true)
	_check((placement.get_correction(slot) as Vector3).length() < 0.01 and visual.global_position.length() < 0.01,
			"and fades out within half a second")
	var runs := PackedInt64Array([slot, -1])
	placement.note_runs(runs, PackedVector3Array([Vector3(0, 0, 2), Vector3.ONE]), PackedFloat32Array([0.0, 0.0]), PackedInt64Array([1, 1]), 14)
	placement.place(14, 1.0, 0.016, true)
	_check(visual.global_position.is_equal_approx(Vector3(0, 0, 2)), "note_runs tells many slots at once, skipping a slot below 0")
	var other := _visual()
	placement.remove(slot)
	var reused: int = placement.add(other, null, Vector3.ZERO, 0.0)
	_check(reused == slot and placement.get_count() == 1, "a removed slot is reused")
	other.free()
	placement.place(14, 0.5, 0.016, true)
	_check(placement.get_count() == 1, "a freed Visual is skipped, not an error")
	visual.free()


# The same calls into both twins put their Visuals in the same places.
func _test_twins(cpp: Object, gd: Object) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	var placements: Array = [cpp, gd]
	var visuals: Array = [[], []]
	for k in 2:
		for i in 8:
			var visual := _visual()
			visuals[k].append(visual)
			placements[k].add(visual, visual.get_node("Model"), Vector3(i, 0, 0), 0.0)
	var same := true
	for tick in range(1, 40):
		var slots := PackedInt64Array()
		var positions := PackedVector3Array()
		var yaws := PackedFloat32Array()
		var spans := PackedInt64Array()
		for i in 8:
			if rng.randf() < 0.6:
				slots.append(i)
				positions.append(Vector3(rng.randf_range(-20, 20), rng.randf_range(0, 2), rng.randf_range(-20, 20)))
				yaws.append(rng.randf_range(-PI, PI))
				spans.append(rng.randi_range(1, 4))
		var jump := Vector3(rng.randf_range(-1, 1), 0, 0)
		var fraction := rng.randf()
		for k in 2:
			placements[k].note_runs(slots, positions, yaws, spans, tick)
			placements[k].add_correction(tick % 8, jump)
			placements[k].place(tick, fraction, 0.016, true)
		for i in 8:
			var a: Node3D = visuals[0][i]
			var b: Node3D = visuals[1][i]
			if a.global_position != b.global_position or a.get_node("Model").rotation != b.get_node("Model").rotation:
				same = false
	_check(same, "C++ and GDScript place every Visual and turn every model exactly the same")
	for k in 2:
		for visual in visuals[k]:
			visual.free()
