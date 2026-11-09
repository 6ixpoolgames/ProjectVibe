## Written by Claude (claude-opus-5-5), 2026-11-09: headless self-test for the shared pawn table (PawnTable, scaling spec section 3,
## tier 1 step 1) and the AI grid built from it (AIPawnGrid). Needs the navcore C++ library; without it, it says so and passes.
## Exits 0 on success, 1 on failure. Run from the project folder:
##   "C:\Git\Test 2\Godot_v4.7.2-stable_win64_console.exe" --headless --path . "res://assets/scripts/pawn/tests/pawn_table_selftest.tscn"
extends Node

const PAWN_SCENE := "res://assets/scenes/pawn/pawn.tscn"

var _failures := 0


func _ready() -> void:
	print("--- Pawn table self-test ---")
	if not ClassDB.class_exists(&"PawnTable"):
		print("  no C++ library here: nothing to test")
		print("--- ALL PASSED ---")
		get_tree().quit(0)
		return
	await _test_keys_and_order()
	await _test_columns()
	await _test_once_a_tick()
	await _test_leaving()
	await _test_grid_matches_brute_force()
	print("--- ALL PASSED ---" if _failures == 0 else "--- %d FAILED ---" % _failures)
	get_tree().quit(0 if _failures == 0 else 1)


## Pawns are in key order: networked pawns by entity id, and pawns with no id after them, in the order they joined.
func _test_keys_and_order() -> void:
	var table: Object = null
	var plain_a := _make_pawn(Vector3(0, 0, 0))
	table = Pawn.get_table()
	var networked_9 := _make_pawn(Vector3(1, 0, 0), 9)
	var plain_b := _make_pawn(Vector3(2, 0, 0))
	var networked_4 := _make_pawn(Vector3(3, 0, 0), 4)
	var keys: PackedInt64Array = table.get_keys()
	var slots := [table.get_slot(networked_4), table.get_slot(networked_9), table.get_slot(plain_a), table.get_slot(plain_b)]
	_check(table != null and slots == [0, 1, 2, 3], "slots in key order: entity ids 4 and 9 first, then pawns with no id in the order they joined (%s)" % str(slots))
	_check(keys[0] == 4 and keys[1] == 9 and keys[2] >= Pawn.TABLE_KEYS_WITHOUT_ID and keys[3] > keys[2], "keys: entity ids, then numbers past every id (%s)" % str(keys))
	for pawn in [plain_a, networked_9, plain_b, networked_4]:
		pawn.free()
	_check(table.get_count() == 0, "every pawn that left is gone from the table")


## Claude 2026-11-09 (scaling spec step 2): columns are off until switched on, by hand or by a system that requires them, and a game
## can add its own.
func _test_columns() -> void:
	var pawn := _make_pawn(Vector3(1, 0, 2))
	pawn.velocity = Vector3(3, 0, 4)
	var table: Object = Pawn.get_table()
	table.refresh(50)
	var row: Dictionary = table.get_row(table.get_slot(pawn))
	_check(not table.is_column_on(&"velocity") and not row.has("velocity") and row.has("position") and row.has("team"), "optional columns start off; key, position and team are always there (%s)" % str(row.keys()))
	_check(table.enable_column(&"velocity") and table.is_column_on(&"velocity"), "switched on by hand")
	table.refresh(50) # the same tick: switching a column on makes the next refresh read anyway
	_check(table.get_row(table.get_slot(pawn)).get("velocity") == Vector3(3, 0, 4), "and the next refresh fills it, even in the same tick")
	table.disable_column(&"velocity")
	_check(not table.is_column_on(&"velocity") and not table.get_row(table.get_slot(pawn)).has("velocity"), "switched off by hand: gone")
	table.require_column(&"grounded") # what a system that reads it does
	table.disable_column(&"grounded") # warns: a system needs it
	_check(table.is_column_on(&"grounded"), "a column a system requires stays on when switched off by hand (with a warning)")
	_check(table.add_column(&"rest_ticks", TYPE_INT, &"rest_check_ticks", 0) and table.is_column_on(&"rest_ticks"), "a game's own column, read from a property, on once added")
	table.refresh(51)
	_check(table.get_row(table.get_slot(pawn)).get("rest_ticks") == pawn.rest_check_ticks and Array(table.get_column(&"rest_ticks")) == [pawn.rest_check_ticks], "its values, in a row and as a whole column")
	_check(not table.add_column(&"rest_ticks", TYPE_INT, &"x", 0) and not table.enable_column(&"no_such_column"), "a name that's taken, or one that doesn't exist, is refused with an error")
	pawn.free()


## Rows are read once a tick: moving a pawn and refreshing again in the same tick changes nothing; the next tick sees the move.
func _test_once_a_tick() -> void:
	var pawn := _make_pawn(Vector3(5, 0, 7))
	pawn.team = 3
	pawn.velocity = Vector3(1, 0, 2)
	pawn.yaw = 0.5
	pawn.detectability = 0.25
	var table: Object = Pawn.get_table()
	for column in [&"velocity", &"yaw", &"detectability"]: # Claude 2026-11-09 (step 2): optional columns are off until switched on
		table.enable_column(column)
	_check(table.refresh(100), "the first refresh of a tick reads")
	var row: Dictionary = table.get_row(table.get_slot(pawn))
	_check(row["position"] == pawn.global_position and row["velocity"] == Vector3(1, 0, 2) and row["team"] == 3 and is_equal_approx(row["yaw"], 0.5) and is_equal_approx(row["detectability"], 0.25), "its row holds the pawn's values (%s)" % str(row))
	pawn.global_position = Vector3(50, 0, 50)
	_check(not table.refresh(100) and table.get_row(table.get_slot(pawn))["position"] == Vector3(5, 0, 7), "a second refresh in the same tick reads nothing: everyone sees the same frozen copy")
	_check(table.refresh(101) and table.get_row(table.get_slot(pawn))["position"] == Vector3(50, 0, 50), "the next tick reads the move")
	pawn.free()


## A pawn leaving keeps the others in order; one freed without leaving is dropped at the next refresh.
func _test_leaving() -> void:
	var pawns: Array[Pawn] = []
	for i in 5:
		pawns.append(_make_pawn(Vector3(i * 2, 0, 0), 20 + i))
	var table: Object = Pawn.get_table()
	remove_child(pawns[1])
	var keys: PackedInt64Array = table.get_keys()
	_check(Array(keys) == [20, 22, 23, 24], "a pawn leaving the tree leaves the table, and the rest keep their order (%s)" % str(keys))
	add_child(pawns[1])
	_check(Array(table.get_keys()) == [20, 21, 22, 23, 24], "and coming back puts it back in its place")
	for pawn in pawns:
		pawn.free()
	await get_tree().physics_frame


## The grid's answers equal a brute-force search: everyone in range on other teams, nearest first, ties by entity id.
func _test_grid_matches_brute_force() -> void:
	var pick := RandomNumberGenerator.new()
	pick.seed = 7
	var pawns: Array[Pawn] = []
	var id := 100
	for i in 60:
		pawns.append(_make_pawn(Vector3(pick.randi_range(-20, 20), 0, pick.randi_range(-20, 20)), id))
		pawns[-1].team = i % 3
		id += 1
	# Four on a circle around the middle, all exactly 6 m away, to check ties.
	for angle in [0.0, PI * 0.5, PI, PI * 1.5]:
		pawns.append(_make_pawn(Vector3(cos(angle) * 6.0, 0, sin(angle) * 6.0).round(), id))
		pawns[-1].team = 1
		id += 1
	var grid: Object = ClassDB.instantiate(&"AIPawnGrid")
	grid.set_table(Pawn.get_table())
	var mismatches := 0
	var asked := 0
	for tick in range(200, 230):
		for seeker in pawns:
			asked += 1
			var radius := 9.0
			var cap := 8
			var got: Array = grid.query(seeker.global_position, radius, seeker.team, seeker, cap, tick)
			if got != _brute_force(pawns, seeker, radius, cap):
				mismatches += 1
	_check(mismatches == 0, "the grid matches a brute-force search, nearest first, ties by entity id (%d queries, %d differ)" % [asked, mismatches])
	# What one refresh costs per pawn: the step's budget is at most 1 µs per pawn extra (scaling spec section 10, step 1).
	var table: Object = Pawn.get_table()
	var started := Time.get_ticks_usec()
	for tick in range(1000, 1200):
		table.refresh(tick)
	# GDScript note: table is untyped (it's made by name), so its results need an explicit type here.
	var per_pawn: float = float(Time.get_ticks_usec() - started) / 200.0 / table.get_count()
	print("        a refresh reads %d pawns in %.1f µs, %.2f µs per pawn" % [table.get_count(), per_pawn * table.get_count(), per_pawn])
	_check(per_pawn < 1.0, "a refresh costs under 1 µs per pawn (%.2f)" % per_pawn)
	for pawn in pawns:
		pawn.free()


func _brute_force(pawns: Array[Pawn], seeker: Pawn, radius: float, cap: int) -> Array:
	var found := []
	for other in pawns:
		if other == seeker or other.team == seeker.team:
			continue
		var d := seeker.global_position.distance_squared_to(other.global_position)
		if d <= radius * radius:
			found.append([d, other.get_network_entity().entity_id, other])
	found.sort_custom(func(a, b): return a[0] < b[0] or (a[0] == b[0] and a[1] < b[1]))
	return found.slice(0, cap).map(func(e): return e[2])


# A pawn placed directly, not simulated (no ticks run here). With an entity id, its NetworkEntity gets that id before it enters the
# tree, the way NetworkSession configures one.
func _make_pawn(at: Vector3, entity_id := -1) -> Pawn:
	var pawn: Pawn = load(PAWN_SCENE).instantiate()
	pawn.position = at
	pawn.skip_default_parts = [&"AIContextComponent", &"AISensingManager", &"AIMemory", &"AITargetSelector", &"AIStateManager", &"AIBehaviourManager"]
	if entity_id >= 0:
		for child in pawn.get_children():
			if child is NetworkEntity:
				child.entity_id = entity_id
	add_child(pawn)
	return pawn


func _check(passed: bool, what: String) -> void:
	print("  %s %s" % ["ok  " if passed else "FAIL", what])
	if not passed:
		_failures += 1
