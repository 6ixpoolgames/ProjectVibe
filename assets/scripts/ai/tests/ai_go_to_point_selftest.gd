## Written by Claude (claude-opus-5-5), 2026-11-15: headless self-test for AIGoToPointBehaviour, the mass battle's march to the middle:
## an idle AI pawn walks to the nearest node in the rally_point group, in legs, and once it's within arrive_radius Wander takes over;
## with no point in the level it isn't available, so the pawn just wanders.
## Exits 0 on success, 1 on failure. Run from the project folder:
##   godot --headless --path . "res://assets/scripts/ai/tests/ai_go_to_point_selftest.tscn"
extends SelfTest # Claude 2026-11-16 (wider audit): _check and _failures come from tests/SelfTest.gd now

const GOBLIN_SCENE := "res://assets/scenes/samples/faction_goblin.tscn" # has GoToPoint and Wander, among others


func _ready() -> void:
	print("--- Go to point self-test ---")
	TickDriver.tick_rate = TickDriver.REFERENCE_RATE
	var floor_body := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(400, 1, 400)
	shape.shape = box
	shape.position.y = -0.5
	floor_body.add_child(shape)
	add_child(floor_body)
	await _test_no_point()
	await _test_march()
	print("--- ALL PASSED ---" if _failures == 0 else "--- %d FAILED ---" % _failures)
	get_tree().quit(0 if _failures == 0 else 1)


func _test_no_point() -> void:
	var goblin := _make_goblin(Vector3(0, 0.1, 0))
	await _ticks(60)
	var running := goblin.ai.behaviour_manager.get_running_behaviour()
	_check(running != null and running.name == &"Wander", "with no rally point in the level, it wanders (%s)" % (String(running.name) if running else "nothing"))
	goblin.queue_free()
	await _ticks(2)


func _test_march() -> void:
	var point := Node3D.new()
	point.position = Vector3(70, 0, 0)
	point.add_to_group(&"rally_point")
	add_child(point)
	var goblin := _make_goblin(Vector3(0, 0.1, 0))
	await _ticks(30)
	var running := goblin.ai.behaviour_manager.get_running_behaviour()
	_check(running != null and running.name == &"GoToPoint", "with one, an idle pawn walks to it (%s)" % (String(running.name) if running else "nothing"))
	var go: AIGoToPointBehaviour = goblin.get_node("AIManager/AIBehaviourManager/GoToPoint")
	for i in 1200:
		await get_tree().physics_frame
		if Vector2(goblin.global_position.x - 70.0, goblin.global_position.z).length() <= go.arrive_radius:
			break
	var left := Vector2(goblin.global_position.x - 70.0, goblin.global_position.z).length()
	_check(left <= go.arrive_radius, "it gets there, 70 m in legs of up to %d m (%.1f m left)" % [go.leg_metres, left])
	await _ticks(40)
	running = goblin.ai.behaviour_manager.get_running_behaviour()
	_check(running != null and running.name == &"Wander", "then Wander takes over (%s)" % (String(running.name) if running else "nothing"))
	goblin.queue_free()
	point.queue_free()
	await _ticks(2)


func _make_goblin(at: Vector3) -> Pawn:
	var goblin: Pawn = load(GOBLIN_SCENE).instantiate()
	goblin.position = at
	add_child(goblin)
	return goblin


func _ticks(count: int) -> void:
	for i in count:
		await get_tree().physics_frame
