## Written by Claude (claude-opus-5-5), 2026-11-09: headless self-test for pawn spec step 10, the fight loop: the Health stat, damage,
## the Death ability, revive, being hit as a state rule, threat from damage, dead pawns ignored by sensing and memory, and a goblin
## fighting an intruder to the death.
## Exits 0 on success, 1 on failure. Run from the project folder:
##   "C:\Git\Test 2\Godot_v4.7.2-stable_win64_console.exe" --headless --path . "res://assets/scripts/abilities/tests/fight_selftest.tscn"
extends Node

const PAWN_SCENE := "res://assets/scenes/pawn/pawn.tscn"

var _failures := 0


func _ready() -> void:
	print("--- Fight self-test ---")
	var floor_body := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(300, 1, 300)
	shape.shape = box
	shape.position.y = -0.5
	floor_body.add_child(shape)
	add_child(floor_body)
	await _test_health_and_death()
	await _test_being_hit_states()
	await _test_dead_are_ignored()
	await _test_fight_to_the_death()
	print("--- ALL PASSED ---" if _failures == 0 else "--- %d FAILED ---" % _failures)
	get_tree().quit(0 if _failures == 0 else 1)


func _test_health_and_death() -> void:
	var attacker := _make_pawn(Vector3(0, 0.1, 0), 1)
	var victim := _make_pawn(Vector3(0, 0.1, -2), 0)
	await _ticks(10)
	_check(is_equal_approx(victim.get_health(), 100.0), "Health is a stat that starts full (100)")
	var listed: Array[String] = (victim.get_node("TickState") as TickStateComponent).state_properties
	_check(listed.has("StatManager/Health:current") and listed.has("AbilityManager/Death:ticks_left"), "Health's current value and the Death ability roll back")
	var deaths := []
	victim.died.connect(func(who, hit): deaths.append([who, hit]))
	for i in 4:
		victim.receive_hit(_hit(attacker, victim, 20))
	_check(is_equal_approx(victim.get_health(), 20.0) and not victim.is_dead(), "four hits of 20: 20 left, alive")
	victim.receive_hit(_hit(attacker, victim, 20))
	_check(victim.get_health() == 0.0 and victim.is_dead(), "the fifth: Health 0, and the Death ability runs")
	_check(deaths.size() == 1 and deaths[0][0] == victim, "died goes out once")
	victim.receive_hit(_hit(attacker, victim, 20))
	_check(deaths.size() == 1, "a hit on a dead pawn does nothing")
	var ai := victim.controller_manager.ai_controller as AIController
	ai.move_in_direction(Vector3(1, 0, 0))
	ai.press(&"jump")
	await _ticks(20)
	_check(victim.is_dead() and Vector2(victim.velocity.x, victim.velocity.z).length() < 0.2 and victim.velocity.y <= 0.01, "dead, it ignores its input: no walking, no jumping")
	var pressed_dash := victim.ability_manager.can_start(&"dash") or victim.ability_manager.can_start(&"primary")
	_check(not pressed_dash, "and no ability can start")
	victim.revive()
	await _ticks(2)
	_check(not victim.is_dead() and is_equal_approx(victim.get_health(), 100.0), "revive: full Health, and Death ends on its next tick")
	await _ticks(15)
	_check(victim.velocity.x > 1.0, "alive again, it follows its input")
	# On a client, hits are ignored: only the server decides them.
	var real_entity: NetworkEntity = victim._entity
	var client_entity := NetworkEntity.new()
	client_entity.role = NetworkEntity.Role.REMOTE_FOLLOWING
	victim._entity = client_entity
	victim.receive_hit(_hit(attacker, victim, 50))
	_check(is_equal_approx(victim.get_health(), 100.0), "on a client, receive_hit does nothing")
	victim._entity = real_entity
	client_entity.free()
	attacker.free()
	victim.free()


func _test_being_hit_states() -> void:
	var goblin := _make_goblin(Vector3(40, 0.1, 0))
	var sneak := _make_pawn(Vector3(40, 0.1, 6), 0) # behind the goblin, which faces -Z: never seen
	await _ticks(20)
	_check(goblin.ai_context.current_state_name() == &"Idle", "an unseen pawn behind it: Idle")
	goblin.receive_hit(_hit(sneak, goblin, 10))
	await _ticks(3)
	_check(goblin.ai_context.current_state_name() == &"Alert", "hit by an attacker it doesn't know: Alert at once (the hit rule)")
	_check(goblin.ai_behaviour_manager.get_running_behaviour().name == &"LookToward", "and it looks toward where the hit came from")
	await _ticks(20)
	var sight: SightSense = goblin.ai_sensing_manager.get_node("Sight")
	_check(sight.visibility_of(sneak) > 0.5, "turning its eyes there, it can now see the attacker")
	goblin.free()
	sneak.free()
	# Known attacker: straight to Combat.
	goblin = _make_goblin(Vector3(60, 0.1, 0))
	var known := _make_pawn(Vector3(60, 0.1, 6), 0)
	await _ticks(20)
	goblin.ai_memory.record_sighting(known, 0.4, TickDriver.tick, known.global_position) # half-noticed earlier
	goblin.receive_hit(_hit(known, goblin, 10))
	await _ticks(3)
	_check(goblin.ai_context.current_state_name() == &"Combat", "hit by an attacker it knows: straight to Combat")
	_check(goblin.ai_memory.threat_at(goblin.ai_memory.find(known)) > 0.09, "and the damage added threat to the attacker's entry (%.2f)" % goblin.ai_memory.threat_at(goblin.ai_memory.find(known)))
	goblin.free()
	known.free()


func _test_dead_are_ignored() -> void:
	var watcher := _make_pawn(Vector3(80, 0.1, 0), 1)
	var corpse := _make_pawn(Vector3(80, 0.1, -5), 0)
	await _ticks(30)
	_check(watcher.ai_memory.find(corpse) >= 0, "a living enemy in front is sensed")
	for i in 5:
		corpse.receive_hit(_hit(watcher, corpse, 20))
	_check(corpse.is_dead(), "it dies")
	await _ticks(25) # past a full sensing pass
	_check(watcher.ai_memory.find(corpse) < 0, "and memory forgets it on the next pass; sensing doesn't put it back")
	watcher.free()
	corpse.free()


func _test_fight_to_the_death() -> void:
	var goblin := _make_goblin(Vector3(120, 0.1, 0))
	var intruder := _make_pawn(Vector3(120, 0.1, -6), 0)
	var deaths := []
	intruder.died.connect(func(who, _hit): deaths.append(who))
	for i in 900:
		await get_tree().physics_frame
		if not deaths.is_empty():
			break
	_check(deaths.size() == 1, "the goblin chases and swings until the intruder dies (5 hits of 20)")
	await _ticks(90)
	_check(goblin.ai_context.current_state_name() != &"Combat" and goblin.ai_memory.find(intruder) < 0, "then it forgets the body and leaves Combat")
	goblin.free()
	intruder.free()


# --- Helpers ---


func _hit(attacker: Pawn, target: Pawn, damage: int) -> HitInfo:
	var hit := HitInfo.new()
	hit.attacker = attacker
	hit.target = target
	hit.tick = TickDriver.tick
	hit.damage = damage
	var away := target.global_position - attacker.global_position
	away.y = 0.0
	hit.direction = away.normalized()
	hit.knockback_speed = 0.0 # these tests check damage; knockback has its own test
	return hit


func _make_pawn(at: Vector3, team: int) -> Pawn:
	var pawn: Pawn = load(PAWN_SCENE).instantiate()
	pawn.team = team
	pawn.position = at
	add_child(pawn)
	return pawn


func _make_goblin(at: Vector3) -> Pawn:
	var goblin: Pawn = load(PAWN_SCENE).instantiate()
	goblin.team = 1
	goblin.position = at
	var manager := AIBehaviourManager.new()
	manager.name = "AIBehaviourManager"
	for pair in [["LookToward", AILookTowardBehaviour], ["Investigate", AIInvestigateBehaviour], ["Search", AISearchBehaviour], ["Chase", AIChaseBehaviour], ["Attack", AIAttackBehaviour]]:
		var behaviour: AIBehaviourBase = pair[1].new()
		behaviour.name = pair[0]
		manager.add_child(behaviour)
	goblin.add_child(manager)
	add_child(goblin)
	return goblin


func _ticks(count: int) -> void:
	for i in count:
		await get_tree().physics_frame


func _check(passed: bool, what: String) -> void:
	print("  %s %s" % ["ok  " if passed else "FAIL", what])
	if not passed:
		_failures += 1
