## Written by Claude (claude-opus-5-5), 2026-11-19: headless self-test for the state store (docs/state_store/STATE_STORE_SPEC.md):
## layouts, handles and slots, the commit with its rounding, history depth, pushed columns, partial commits, loading a row back,
## the tripwire, and the C++ StateStore against its GDScript twin, row by row and checksum by checksum. Exits 0 on success, 1 on failure.
extends SelfTest


## Something to record: a position, a heading, a counter and a list, plus a part below it.
class Thing extends Node3D:
	var speed := 0.0
	var count := 0
	var trail: Array = []


func _ready() -> void:
	print("--- State store self-test ---")
	var kinds: Array = [["GDScript", func() -> Object: return StateStoreGD.new()]]
	if ClassDB.class_exists(&"StateStore"):
		kinds.push_front(["C++", func() -> Object: return ClassDB.instantiate(&"StateStore")])
	else:
		_check(false, "the navcore library has StateStore (rebuild native/ with the editor closed)")
	for kind in kinds:
		print("  [%s]" % kind[0])
		_test_layouts(kind[1].call())
		_test_commit(kind[1].call())
		_test_slots(kind[1].call())
		_test_pushed_and_partial(kind[1].call())
		_test_gone_nodes(kind[1].call())
		_test_tripwire(kind[1].call())
		_test_carry_forward(kind[1].call())
		_test_pushed_with_node(kind[1].call())
		_test_long_moves(kind[1].call())
	if kinds.size() == 2:
		_test_twins()
	_finish()


func _thing() -> Thing:
	var thing := Thing.new()
	var part := Node3D.new()
	part.name = "Part"
	thing.add_child(part)
	add_child(thing)
	return thing


func _layout(store: Object) -> int:
	return store.define_layout(PackedStringArray(["position", "heading", "count", "trail", "part"]),
			[&"vector3_mm", &"angle_u16", &"raw", &"raw", &"float"])


func _bind(store: Object, handle: int, thing: Thing) -> bool:
	var part := thing.get_node("Part")
	return store.bind(handle, [thing, thing, thing, thing, part], [^"position", ^":rotation:y", ^"count", ^"trail", ^":position:x"],
			[&"vector3_mm", &"angle_u16", &"raw", &"raw", &"float"], true)


# Claude 2026-11-21: find_long_moves, the MoveSanityCheck's first pass, from rows written by hand.
func _test_long_moves(store: Object) -> void:
	var moving: int = store.define_layout(PackedStringArray(["position", "velocity"]), [&"vector3_mm", &"vector3_mm"])
	var still: int = store.define_layout(PackedStringArray(["position"]), [&"vector3_mm"])
	var walker: int = store.add_entity(moving, null)
	var jumper: int = store.add_entity(moving, null)
	var dasher: int = store.add_entity(moving, null)
	var newcomer: int = store.add_entity(moving, null)
	var no_velocity: int = store.add_entity(still, null)
	store.write_row(walker, 1, [Vector3.ZERO, Vector3(1, 0, 0)])
	store.write_row(walker, 2, [Vector3(0.017, 0, 0), Vector3(1, 0, 0)])
	store.write_row(jumper, 1, [Vector3.ZERO, Vector3.ZERO])
	store.write_row(jumper, 2, [Vector3(5, 0, 0), Vector3.ZERO])
	store.write_row(dasher, 1, [Vector3.ZERO, Vector3(600, 0, 0)])
	store.write_row(dasher, 2, [Vector3(10, 0, 0), Vector3(600, 0, 0)])
	store.write_row(newcomer, 2, [Vector3(50, 0, 0), Vector3.ZERO])
	store.write_row(no_velocity, 1, [Vector3.ZERO])
	store.write_row(no_velocity, 2, [Vector3(50, 0, 0)])
	var found: Dictionary = store.find_long_moves(2, 1.0 / 60.0, 1.5, 0.5)
	_check(found["checked"] == 3, "find_long_moves compares entities with both rows, in layouts with position and velocity (%d)" % found["checked"])
	_check(found["handles"] == PackedInt64Array([jumper]) and is_equal_approx(found["moved"][0], 5.0) and found["speeds"][0] == 0.0,
			"and returns only a move its velocity doesn't explain, with its length and speed; a dash's velocity explains the dash")
	_check((store.find_long_moves(1, 1.0 / 60.0, 1.5, 0.5)["checked"] as int) == 0, "a tick with no row before it compares nothing")


func _test_layouts(store: Object) -> void:
	var a: int = _layout(store)
	var b: int = _layout(store)
	var c: int = store.define_layout(PackedStringArray(["position"]), [&"vector3_mm"])
	_check(a == 0 and b == 0 and c == 1 and store.get_layout_count() == 2, "the same columns give the same layout; other columns a new one")
	_check(store.get_layout_columns(0) == PackedStringArray(["position", "heading", "count", "trail", "part"]), "a layout lists its columns")
	var auto: int = store.define_layout(PackedStringArray(["position"]), [&"auto"])
	var thing := _thing()
	var loose: int = store.add_entity(auto, thing)
	_check(not store.bind(loose, [thing], [^"position"], [&"auto"], true), "a binding's encodings must be settled")
	_check(store.bind(loose, [thing], [^"position"], [&"vector3_cm"], true), "an auto column takes the binding's encoding")
	var fixed: int = store.add_entity(c, thing)
	_check(not store.bind(fixed, [thing], [^"position"], [&"vector3_cm"], true), "a fixed column refuses another encoding")
	thing.free()
	store.clear()
	a = _layout(store)
	_check(store.get_depth() == 64 and store.set_depth(16) and store.get_depth() == 16, "depth defaults to 64 and can change while empty")
	var handle: int = store.add_entity(a, self)
	_check(not store.set_depth(32) and store.get_depth() == 16, "but not once it holds an entity")
	_check(store.is_alive(handle) and store.get_owner(handle) == self and not store.is_bound(handle), "an entity starts alive, owned, unbound")


func _test_commit(store: Object) -> void:
	store.set_depth(8)
	var thing := _thing()
	var handle: int = store.add_entity(_layout(store), thing)
	_check(_bind(store, handle, thing), "binding one node and property per column")
	var unfinished: PackedInt64Array = store.commit(1)
	_check(unfinished.is_empty() and store.has_row(handle, 1), "a bound entity commits")
	thing.position = Vector3(1.23456, 0.0004, -2.0006)
	thing.rotation.y = 0.123456
	thing.count = 7
	thing.trail = [1, 2]
	thing.get_node("Part").position.x = 0.1
	store.commit(2)
	var row: Array = store.get_row(handle, 2)
	_check(row[0] == StateEncoding.quantize(Vector3(1.23456, 0.0004, -2.0006), StateEncoding.VECTOR3_MM) and thing.position == row[0], "rounded to its encoding, and written back to the node")
	_check(row[1] == StateEncoding.quantize(0.123456, StateEncoding.ANGLE_U16) and is_equal_approx(thing.rotation.y, row[1]), "parts of a property work (:rotation:y)")
	_check(row[2] == 7 and row[3] == [1, 2] and row[4] == StateEncoding.quantize(0.1, StateEncoding.FLOAT), "plain values, containers and a property on a part")
	thing.trail.append(3)
	_check(store.get_value(handle, 3, 2) == [1, 2], "containers are copied, so a frame keeps its own")
	row[2] = 99
	_check(store.get_value(handle, 2, 2) == 7, "a row handed out is a copy")
	_check(store.set_value(handle, 2, 2, 8) and store.get_value(handle, 2, 2) == 8, "set_value corrects a held row")
	for t in range(3, 11):
		thing.count = t
		store.commit(t)
	_check(store.has_row(handle, 3) and not store.has_row(handle, 2) and store.newest_tick(handle) == 10, "a depth of 8 keeps ticks 3 to 10")
	store.set_entity_depth(handle, 4)
	_check(store.has_row(handle, 7) and not store.has_row(handle, 6), "an entity's own depth can keep fewer")
	_check(store.load_row(handle, 8) and thing.count == 8 and thing.trail == [1, 2, 3], "load_row writes a row back into the nodes")
	var column: Dictionary = store.get_column(0, 2, 10)
	_check(column["handles"] == PackedInt64Array([handle]) and column["values"] == [10], "get_column reads one column of a frame")
	var at: PackedVector3Array = store.get_vector3s(PackedInt64Array([handle, -1, handle]), &"position", 10)
	_check(at.size() == 3 and at[0] == thing.position and is_nan(at[1].x) and at[2] == at[0],
			"get_vector3s reads a Vector3 column by name for many entities, NaN where there's no row")
	var not_vectors: PackedVector3Array = store.get_vector3s(PackedInt64Array([handle, handle]), &"count", 10)
	var no_column: PackedVector3Array = store.get_vector3s(PackedInt64Array([handle]), &"nothing", 10)
	var too_old: PackedVector3Array = store.get_vector3s(PackedInt64Array([handle]), &"position", 2)
	_check(is_nan(not_vectors[0].x) and is_nan(not_vectors[1].x) and is_nan(no_column[0].x) and is_nan(too_old[0].x),
			"and NaN for a column that isn't a Vector3, one the layout lacks, or a tick the history no longer holds")
	var wrote: int = store.write_through(PackedInt64Array([handle, -1]), &"position", [Vector3(5.00049, 0, 1), Vector3.ONE], 11)
	_check(wrote == 1 and thing.position == StateEncoding.quantize(Vector3(5.00049, 0, 1), StateEncoding.VECTOR3_MM),
			"write_through writes a column into each entity's node, rounded as the commit rounds, skipping a dead handle")
	_check(store.write_through(PackedInt64Array([handle]), &"nothing", [1], 11) == 0, "and skips a column the layout lacks")
	thing.position = Vector3(9, 9, 9) # written around it after the write-through: the row misses this, as documented
	thing.count = 11
	store.commit(11)
	_check(store.get_value(handle, 0, 11) == StateEncoding.quantize(Vector3(5.00049, 0, 1), StateEncoding.VECTOR3_MM)
			and store.get_value(handle, 2, 11) == 11, "the commit takes what was written through, and reads the other columns from the nodes")
	store.commit(12)
	_check(store.get_value(handle, 0, 12) == Vector3(9, 9, 9), "the next tick's commit reads that node again")
	# Claude 2026-11-21: a teleport after the crowd mover wrote a pawn through, in the same tick, must still be recorded.
	store.write_through(PackedInt64Array([handle]), &"position", [Vector3(1, 2, 3)], 13)
	thing.position = Vector3(-4, 0, 7)
	store.mark_changed(handle)
	store.commit(13)
	_check(store.get_value(handle, 0, 13) == StateEncoding.quantize(Vector3(-4, 0, 7), StateEncoding.VECTOR3_MM),
			"mark_changed drops what was written through, so the commit reads the node")
	var stats: Dictionary = store.get_stats()
	_check(stats["entities"] == 1 and stats["bound"] == 1 and stats["cells_per_frame"] == 5, "stats count entities and cells %s" % str(stats))
	thing.free()


func _test_slots(store: Object) -> void:
	store.set_depth(4)
	var layout: int = store.define_layout(PackedStringArray(["n"]), [&"raw"], PackedByteArray([1]))
	var first: int = store.add_entity(layout, null)
	store.push(first, 0, 1)
	store.commit(1)
	store.remove_entity(first)
	_check(not store.is_alive(first) and store.has_row(first, 1), "a freed entity's rows stay readable")
	var second: int = store.add_entity(layout, null)
	_check((second & 0xfffff) == 1, "its slot isn't reused while the history may still hold it (got slot %d)" % (second & 0xfffff))
	for t in range(2, 6):
		store.commit(t)
	var third: int = store.add_entity(layout, null)
	_check((third & 0xfffff) == 0 and third != first and (third >> 32) == 2, "once the history has moved past it, the slot comes back with a new generation")
	_check(not store.is_alive(first) and not store.has_row(first, 1), "the old handle matches nothing")
	store.push(third, 0, 5)
	store.commit(6)
	_check(store.get_value(third, 0, 6) == 5 and store.get_value(first, 0, 6) == null, "and reading through the old handle finds nothing")


func _test_pushed_and_partial(store: Object) -> void:
	var thing := _thing()
	var layout: int = store.define_layout(PackedStringArray(["position", "target"]), [&"vector3_mm", &"raw"], PackedByteArray([0, 1]))
	var handle: int = store.add_entity(layout, thing)
	_check(store.bind(handle, [thing, null], [^"position", ^""], [&"vector3_mm", &""], true), "a pushed column needs no node")
	store.push(handle, 1, 42)
	store.commit(1)
	store.commit(2)
	_check(store.get_value(handle, 1, 1) == 42 and store.get_value(handle, 1, 2) == 42, "a pushed value is recorded every tick until the next push")
	store.push(handle, 1, 43)
	store.load_row(handle, 1)
	store.commit(3)
	_check(store.get_value(handle, 1, 3) == 42, "load_row puts pushed values back too")
	var other := _thing()
	var other_handle: int = store.add_entity(layout, other)
	store.bind(other_handle, [other, null], [^"position", ^""], [&"vector3_mm", &""], true)
	store.commit(4)
	thing.position = Vector3(5, 0, 0)
	other.position = Vector3(6, 0, 0)
	store.commit_entities(4, PackedInt64Array([handle]))
	_check(store.get_value(handle, 0, 4) == Vector3(5, 0, 0) and store.get_value(other_handle, 0, 4) == Vector3.ZERO, "commit_entities rewrites only the entities named")
	store.set_active(other_handle, false)
	store.commit(5)
	_check(store.has_row(handle, 5) and not store.has_row(other_handle, 5), "an inactive entity isn't committed")
	thing.free()
	other.free()


func _test_gone_nodes(store: Object) -> void:
	var thing := _thing()
	var handle: int = store.add_entity(_layout(store), thing)
	var unfinished: PackedInt64Array = store.commit(1)
	_check(unfinished == PackedInt64Array([handle]) and not store.has_row(handle, 1), "an unbound entity is handed back for its owner to gather")
	_check(store.write_row(handle, 1, [Vector3.ONE, 0.0, 1, [], StateStoreGD.MISSING]) and store.has_row(handle, 1), "write_row is the owner's gather")
	_bind(store, handle, thing)
	var part := thing.get_node("Part")
	thing.remove_child(part)
	part.free()
	unfinished = store.commit(2)
	_check(unfinished == PackedInt64Array([handle]) and not store.is_bound(handle) and not store.has_row(handle, 2), "a freed node unbinds the entity and hands it back, writing nothing")
	thing.free()


func _test_tripwire(store: Object) -> void:
	var thing := _thing()
	var handle: int = store.add_entity(_layout(store), thing)
	_bind(store, handle, thing)
	thing.position = Vector3(1, 2, 3)
	store.commit(1)
	_check(store.verify_nodes(1).is_empty(), "the tripwire is quiet while nodes hold what was committed")
	thing.count += 1
	_check(store.verify_nodes(1) == PackedInt64Array([handle]), "and names an entity something changed outside a tick")
	thing.free()


func _test_carry_forward(store: Object) -> void:
	var thing := _thing()
	var handle: int = store.add_entity(_layout(store), thing)
	_bind(store, handle, thing)
	store.set_carry_forward(handle, true)
	thing.count = 1
	store.commit(1)
	_check(store.get_stats()["rows_read"] == 1, "a carry-forward entity is read at its first commit")
	thing.count = 2 # changed without saying so
	store.commit(2)
	_check(store.get_value(handle, 2, 2) == 1 and store.get_stats()["rows_carried"] == 1, "then its row is copied forward while nothing marks it, reading no node")
	_check(store.verify_nodes(2) == PackedInt64Array([handle]), "the tripwire catches a change nobody marked")
	store.mark_changed(handle)
	store.commit(3)
	_check(store.get_value(handle, 2, 3) == 2 and store.get_stats()["rows_read"] == 1, "marked changed, the next commit reads it")
	store.commit(5) # tick 4 never committed: nothing to copy from
	_check(store.get_value(handle, 2, 5) == 2 and store.get_stats()["rows_read"] == 1, "with no row for the tick before, it reads")
	thing.count = 9
	store.load_row(handle, 3)
	store.commit(6)
	_check(thing.count == 2 and store.get_stats()["rows_read"] == 1, "loading a row counts as a change")
	thing.count = 7
	store.commit_entities(6, PackedInt64Array([handle]))
	_check(store.get_value(handle, 2, 6) == 7, "a rollback's re-run always reads")
	thing.free()


func _test_pushed_with_node(store: Object) -> void:
	var thing := _thing()
	thing.count = 4
	var layout: int = store.define_layout(PackedStringArray(["position", "count"]), [&"vector3_mm", &"raw"], PackedByteArray([0, 1]))
	var handle: int = store.add_entity(layout, thing)
	_check(store.bind(handle, [thing, thing], [^"position", ^"count"], [&"vector3_mm", &"raw"], true), "a pushed column may be bound to a node")
	store.commit(1)
	_check(store.get_value(handle, 1, 1) == 4, "its value is read once, when bound")
	thing.count = 5
	store.commit(2)
	_check(store.get_value(handle, 1, 2) == 4 and store.verify_nodes(2) == PackedInt64Array([handle]), "a commit never reads it, and the tripwire catches a missed push")
	store.push(handle, 1, 5)
	store.commit(3)
	_check(store.get_value(handle, 1, 3) == 5 and store.verify_nodes(3).is_empty(), "a push is recorded")
	thing.count = 8
	store.load_row(handle, 1)
	_check(thing.count == 4, "load_row writes a pushed value back to its node")
	store.commit(4)
	_check(store.get_value(handle, 1, 4) == 4, "and the store's pushed value goes back with it")
	thing.free()


# The same scripted run through both stores: every row and every frame's checksum must match.
func _test_twins() -> void:
	var stores: Array = [ClassDB.instantiate(&"StateStore"), StateStoreGD.new()]
	var runs: Array = []
	for store in stores:
		store.set_depth(16)
		var things: Array = []
		var handles: Array = []
		for i in 6:
			var thing := _thing()
			things.append(thing)
			var handle: int = store.add_entity(_layout(store), thing)
			_bind(store, handle, thing)
			handles.append(handle)
		var pick := RandomNumberGenerator.new()
		pick.seed = 77
		var rows: Array = []
		var sums: Array = []
		for t in range(1, 41):
			for i in things.size():
				if not is_instance_valid(things[i]):
					continue
				var thing: Thing = things[i]
				thing.position += Vector3(pick.randf_range(-1, 1), pick.randf_range(-0.01, 0.01), pick.randf_range(-1, 1)) * 0.0137
				thing.rotation.y = wrapf(thing.rotation.y + pick.randf_range(-0.2, 0.2), -PI, PI)
				thing.count += pick.randi_range(0, 3)
				if pick.randf() < 0.1:
					thing.trail.append(t)
				thing.get_node("Part").position.x = pick.randf_range(-3, 3)
			if t == 20: # one leaves, one arrives: slots and generations must agree too
				store.remove_entity(handles[2])
				things[2].free()
				var newcomer := _thing()
				things.append(newcomer)
				var h: int = store.add_entity(_layout(store), newcomer)
				_bind(store, h, newcomer)
				handles.append(h)
			store.commit(t)
			var frame: Array = []
			for h in handles:
				frame.append(store.get_row(h, t))
			rows.append(frame)
			sums.append(store.frame_checksum(t))
		runs.append({"rows": rows, "sums": sums, "handles": handles})
		for thing in things:
			if is_instance_valid(thing):
				thing.free()
	var cpp: Dictionary = runs[0]
	var gd: Dictionary = runs[1]
	_check(cpp["handles"] == gd["handles"], "C++ and GDScript hand out the same handles, reused slot included")
	_check(cpp["rows"] == gd["rows"], "and record exactly the same rows, tick by tick (40 ticks, 7 entities)")
	_check(cpp["sums"] == gd["sums"] and cpp["sums"][0] != cpp["sums"][1], "and give the same checksum for every frame")
	var different := 0
	for value in [PI, -PI, PI + 0.000001, 0.0005, -0.0005, Vector3(0.0005, -0.0005, 1.0005), Vector2(0.0015, 2.0), 5, true, "text", null]:
		for encoding in [&"vector3_mm", &"vector2_mm", &"vector3_cm", &"angle_u16", &"angle_byte", &"float", &"raw"]:
			var a: Variant = stores[0].quantize(value, encoding)
			var b: Variant = stores[1].quantize(value, encoding)
			if typeof(a) != typeof(b) or a != b:
				different += 1
	_check(different == 0, "both round exactly as StateEncoding.quantize does")
