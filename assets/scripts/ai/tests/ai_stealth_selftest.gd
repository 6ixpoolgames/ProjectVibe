## Written by Claude (claude-opus-5-5), 2026-11-09: headless self-test that plays pawn spec 10.6's walkthrough with real pawns: a goblin
## with the default parts and all five t0 behaviours (Wander, Look Toward, Investigate, Search, Chase), and an intruder on another
## team that the test moves around. It checks each step of Idle → Alert → Combat → Alert (searching) → Idle, and that a pawn on its
## own team, or an invisible one, never alerts it.
## Exits 0 on success, 1 on failure. Run from the project folder:
##   "C:\Git\Test 2\Godot_v4.7.2-stable_win64_console.exe" --headless --path . "res://assets/scripts/ai/tests/ai_stealth_selftest.tscn"
extends Node

const PAWN_SCENE := "res://assets/scenes/pawn/pawn.tscn"
const FAR_AWAY := Vector3(80, 0, 80) # out of sight range

var _failures := 0


func _ready() -> void:
	print("--- AI stealth self-test ---")
	var floor_body := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(300, 1, 300)
	shape.shape = box
	shape.position.y = -0.5
	floor_body.add_child(shape)
	add_child(floor_body)
	await _test_walkthrough()
	await _test_never_alerted()
	print("--- ALL PASSED ---" if _failures == 0 else "--- %d FAILED ---" % _failures)
	get_tree().quit(0 if _failures == 0 else 1)


func _test_walkthrough() -> void:
	var goblin := _make_goblin(Vector3.ZERO)
	var intruder := _make_pawn(0, FAR_AWAY)
	await _ticks(60)
	_check(_state(goblin) == &"Idle" and _running(goblin) == &"Wander", "nobody in sight: Idle, wandering")

	# 1. A glimpse at the edge of its vision: the intruder stays 22 m in front of it, where sight is weak.
	var ticks := await _until(func() -> bool:
		_put_in_front(intruder, goblin, 22.0)
		return _state(goblin) == &"Alert", 600)
	_check(ticks >= 0, "a glimpse at 22 m: Alert after %d ticks" % ticks)
	_check(_running(goblin) == &"LookToward", "it stops and looks (Look Toward)")
	_check(not _certain(goblin, intruder), "still uncertain")
	var last_known: Vector3 = goblin.ai_memory.last_known_position_at(goblin.ai_memory.find(intruder))
	intruder.global_position = FAR_AWAY # it ducks out of sight
	ticks = await _until(func() -> bool: return _running(goblin) == &"Investigate", 120)
	_check(ticks >= 0, "after looking, it goes to investigate (%d ticks later)" % ticks)
	var start_distance := _flat_distance(goblin.global_position, last_known)
	await _ticks(40)
	_check(_flat_distance(goblin.global_position, last_known) < start_distance - 2.0, "walking toward where the intruder was (%.1f m to go, from %.1f)" % [_flat_distance(goblin.global_position, last_known), start_distance])
	_check(not goblin.is_action_held(&"sprint"), "without sprinting")

	# 2. The intruder steps out close in front: certain at once, chased.
	ticks = await _until(func() -> bool:
		_put_in_front(intruder, goblin, 5.0)
		return _state(goblin) == &"Combat", 60)
	_check(ticks >= 0 and ticks < 30, "close in front: certain and in Combat within half a second (%d ticks)" % ticks)
	_check(goblin.ai_context.current_target == intruder, "the intruder is its target")
	await _ticks(5)
	_check(_running(goblin) == &"Chase" and goblin.is_action_held(&"sprint"), "Chase runs, holding sprint")
	ticks = await _until(func() -> bool: return _flat_distance(goblin.global_position, intruder.global_position) < 2.5, 120)
	_check(ticks >= 0, "it closes in on the intruder, and stops near it (%d ticks)" % ticks)

	# 3. The intruder vanishes: two seconds later the goblin is Alert again, searching where it was.
	goblin.ai_memory.certain_fade = _straight_line(400) # shorter than the default 1200, to keep the test quick
	var vanished_at: Vector3 = intruder.global_position
	intruder.global_position = FAR_AWAY
	await _ticks(100)
	_check(_state(goblin) == &"Combat", "out of sight for under 2 s: still Combat")
	ticks = await _until(func() -> bool: return _state(goblin) == &"Alert", 60)
	_check(ticks >= 0, "after 2 s unseen: back to Alert")
	await _ticks(2)
	_check(_running(goblin) == &"Search", "searching, because it became certain (Search, not Investigate)")
	_check(goblin.ai_memory.last_known_position_at(goblin.ai_memory.find(intruder)).distance_to(vanished_at) < 1.0, "around where it was last seen")

	# 4. It forgets: the certain entry fades below Alert's 0.3, and it wanders again.
	ticks = await _until(func() -> bool: return _state(goblin) == &"Idle", 600)
	_check(ticks >= 0, "the memory fades: Idle again")
	await _ticks(2)
	_check(_running(goblin) == &"Wander", "and wandering")
	goblin.free()
	intruder.free()


func _test_never_alerted() -> void:
	var goblin := _make_goblin(Vector3(50, 0, 0))
	var friend := _make_pawn(1, Vector3(50, 0, -50))
	var ghost := _make_pawn(0, Vector3(50, 0, -50))
	ghost.detectability = 0.0
	await _ticks(10)
	for i in 120:
		_put_in_front(friend, goblin, 4.0)
		_put_in_front(ghost, goblin, 3.0)
		await get_tree().physics_frame
	_check(_state(goblin) == &"Idle" and goblin.ai_memory.entry_count() == 0, "a pawn on its own team, and an invisible one, close in front for 2 s: never noticed")
	goblin.free()
	friend.free()
	ghost.free()


# --- Helpers ---


## A goblin: a pawn on team 1 with the default parts and every t0 behaviour.
func _make_goblin(at: Vector3) -> Pawn:
	var goblin: Pawn = load(PAWN_SCENE).instantiate()
	goblin.name = "Goblin"
	goblin.team = 1
	goblin.position = at
	var manager := AIBehaviourManager.new()
	manager.name = "AIBehaviourManager"
	var wander := AIWanderBehaviour.new()
	wander.name = "Wander"
	wander.wander_radius = 4.0
	manager.add_child(wander)
	for pair in [["LookToward", AILookTowardBehaviour], ["Investigate", AIInvestigateBehaviour], ["Search", AISearchBehaviour], ["Chase", AIChaseBehaviour]]:
		var behaviour: AIBehaviourBase = pair[1].new()
		behaviour.name = pair[0]
		manager.add_child(behaviour)
	goblin.add_child(manager)
	add_child(goblin)
	return goblin


func _make_pawn(team: int, at: Vector3) -> Pawn:
	var pawn: Pawn = load(PAWN_SCENE).instantiate()
	pawn.team = team
	pawn.position = at
	add_child(pawn)
	return pawn


## Puts a pawn this far in front of the goblin's eyes.
func _put_in_front(pawn: Pawn, goblin: Pawn, distance: float) -> void:
	var sight: SightSense = goblin.ai_sensing_manager.get_node("Sight")
	var yaw: float = sight._eye_yaw()
	pawn.global_position = goblin.global_position + Vector3(-sin(yaw), 0.0, -cos(yaw)) * distance
	pawn.velocity = Vector3.ZERO


func _state(pawn: Pawn) -> StringName:
	return pawn.ai_context.current_state_name()


func _running(pawn: Pawn) -> StringName:
	var behaviour := pawn.ai_behaviour_manager.get_running_behaviour()
	return behaviour.name if behaviour else &""


func _certain(goblin: Pawn, other: Pawn) -> bool:
	var i := goblin.ai_memory.find(other)
	return i >= 0 and goblin.ai_memory.is_certain_at(i)


func _flat_distance(a: Vector3, b: Vector3) -> float:
	return Vector2(a.x - b.x, a.z - b.z).length()


func _straight_line(ticks: int) -> FadeProfile:
	var profile := FadeProfile.new()
	profile.mode = FadeProfile.Mode.LINEAR
	profile.fade_ticks = ticks
	return profile


func _until(condition: Callable, max_ticks: int) -> int:
	for i in max_ticks:
		if condition.call():
			return i
		await get_tree().physics_frame
	return -1


func _ticks(count: int) -> void:
	for i in count:
		await get_tree().physics_frame


func _check(passed: bool, what: String) -> void:
	print("  %s %s" % ["ok  " if passed else "FAIL", what])
	if not passed:
		_failures += 1
