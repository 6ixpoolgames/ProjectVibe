# Written by Claude (claude-opus-5-5), 2026-11-24: headless self-test for the status manager's step 3a (pawn spec 16.8): stat thresholds
# and the events they send through the pawn, Death and AI threat started by events, and over-time effects kept as deadlines; step 3b:
# modifiers and effectors, multiply then add, overrides.
# Exits 0 on success, 1 on failure. Run from the project folder:
#   godot --headless --path . "res://assets/scripts/status/tests/status_selftest.tscn"
extends SelfTest

const PAWN_SCENE := "res://assets/scenes/pawn/pawn.tscn"
const NO_AI: Array[StringName] = [&"AISensingManager", &"AIMemory", &"AITargetSelector", &"AIStateManager", &"AIBehaviourManager"]


func _ready() -> void:
	print("--- Status self-test ---")
	TickDriver.tick_rate = TickDriver.REFERENCE_RATE
	var floor_body := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(200, 1, 200)
	shape.shape = box
	shape.position.y = -0.5
	floor_body.add_child(shape)
	add_child(floor_body)
	await _test_thresholds()
	await _test_death_and_threat()
	await _test_deadlines()
	await _test_modifier_rule()
	print("--- ALL PASSED ---" if _failures == 0 else "--- %d FAILED ---" % _failures)
	get_tree().quit(0 if _failures == 0 else 1)


func _test_thresholds() -> void:
	var a := _pawn(Vector3(0, 0, 0), NO_AI)
	var b := _pawn(Vector3(3, 0, 0), NO_AI)
	await _ticks(2)
	var events: Array[GameplayEventData] = []
	a.gameplay_event_received.connect(func(event: GameplayEventData) -> void: events.append(event))
	var status := a.status_manager
	_check(a.get_node_or_null(^"StatusManager") == status and a.get_node_or_null(^"StatManager") == null and a.get_node_or_null(^"EffectManager") == null, "one StatusManager holds the stats and effects")
	status.change_current(StatusManager.HEALTH, -50.0, b)
	_check(events.is_empty() and status.get_health() == 50.0, "100 to 50 crosses no threshold: no event")
	var hit := HitInfo.new()
	status.change_current(StatusManager.HEALTH, -30.0, b, hit)
	_check(events.size() == 1 and events[0].tag == Tags.EVENT.HEALTH_LOW and events[0].instigator == b and events[0].target == a and events[0].optional_object == hit and events[0].magnitude == 20.0,
			"50 to 20 crosses 25%%: event.health.low, with the source, the target, the cause and the Health left (%s)" % [events.map(func(e: GameplayEventData) -> StringName: return e.tag)])
	status.change_current(StatusManager.HEALTH, 30.0, b)
	_check(events.size() == 1, "going back up sends nothing")
	events.clear()
	status.fill_current(StatusManager.HEALTH)
	_check(events.is_empty() and status.get_health() == 100.0, "fill_current fills it and sends nothing")
	a.free()
	b.free()


func _test_death_and_threat() -> void:
	var victim := _pawn(Vector3(0, 0, 0), [])
	var attacker := _pawn(Vector3(3, 0, 0), NO_AI)
	await _ticks(2)
	var tags: Array[StringName] = []
	victim.gameplay_event_received.connect(func(event: GameplayEventData) -> void: tags.append(event.tag))
	var memory := victim.ai.memory if victim.ai else null
	if memory:
		memory.record_sighting(attacker, 1.0, TickDriver.tick, attacker.global_position) # remembered, so it can have threat
	var threat_before: float = memory.threat_at(memory.find(attacker)) if memory else 0.0
	victim.status_manager.apply_effect(Effect.make_damage(30), attacker)
	_check(tags == [Tags.EVENT.DAMAGE_TAKEN], "damage sends event.damage.taken (%s)" % [tags])
	_check(memory != null and memory.threat_at(memory.find(attacker)) > threat_before, "and the AI's memory notes threat from it")
	tags.clear()
	victim.status_manager.apply_effect(Effect.make_damage(500), attacker)
	_check(tags.has(Tags.EVENT.HEALTH_DEPLETED) and victim.is_dead(), "Health to 0 sends event.health.depleted, and Death starts from it (%s)" % [tags])
	victim.ability_manager.revive()
	_check(victim.status_manager.get_health() == 100.0, "revive fills Health")
	victim.free()
	attacker.free()


func _test_deadlines() -> void:
	var a := _pawn(Vector3(0, 0, 0), NO_AI)
	await _ticks(2)
	var poison := Effect.new()
	poison.effect_name = &"status test poison"
	poison.duration_ticks = 30
	poison.period_ticks = 10
	var tick_damage := StatChangeEffector.new()
	tick_damage.amount = -1.0
	poison.effectors = [tick_damage]
	var applied_at: int = TickDriver.tick
	a.status_manager.apply_effect(poison, null)
	var entry: Dictionary = a.status_manager.get_active_effects()[0]
	_check(entry["ends_at"] == applied_at + 30 and a.status_manager.active_effects[StatusManager.NEXT_PERIOD_AT] == applied_at + 10, "an over-time effect keeps the tick it ends and the tick of its next period (%d, %d)" % [entry["ends_at"] - applied_at, a.status_manager.active_effects[StatusManager.NEXT_PERIOD_AT] - applied_at])
	var list_before := a.status_manager.active_effects.duplicate()
	await _ticks(3)
	_check(a.status_manager.active_effects == list_before, "nothing in the list changes between deadlines")
	await _until(func() -> bool: return not a.status_manager.has_effect(poison), 40)
	_check(a.status_manager.get_health() == 97.0, "once when applied, then at 10 and 20 ticks, none on the tick it ends at 30: 3 damage (%.0f)" % (100.0 - a.status_manager.get_health()))
	a.free()


func _test_modifier_rule() -> void:
	var a := _pawn(Vector3(0, 0, 0), NO_AI)
	await _ticks(2)
	var status := a.status_manager
	var base: float = status.get_value(&"MoveSpeed")
	var both := Effect.new()
	both.effect_name = &"status test add and multiply"
	both.duration_ticks = 600
	var change := StatModifier.new()
	change.stat = &"MoveSpeed"
	change.add = 2.0
	change.multiply = 0.5
	both.modifiers = [change]
	status.apply_effect(both, null)
	_check(is_equal_approx(status.get_value(&"MoveSpeed"), base * 0.5 + 2.0), "multiply, then add: %.1f x0.5 + 2 = %.2f" % [base, status.get_value(&"MoveSpeed")])
	var freeze := Effect.new()
	freeze.effect_name = &"status test freeze"
	freeze.duration_ticks = 600
	var stop := StatModifier.new()
	stop.stat = &"MoveSpeed"
	stop.overrides = true
	stop.override_value = 0.0
	freeze.modifiers = [stop]
	status.apply_effect(freeze, null)
	_check(status.get_value(&"MoveSpeed") == 0.0, "an override sets the value whatever the base and the other modifiers")
	status.remove_effect(freeze)
	_check(is_equal_approx(status.get_value(&"MoveSpeed"), base * 0.5 + 2.0), "and without it, the other modifiers hold again")
	status.remove_effect(both)
	_check(status.get_value(&"MoveSpeed") == base, "with none, the base value")
	_check(both.has_modifiers() and not Effect.make_damage(5).has_modifiers() and Effect.make_damage(5).effectors.size() == 1, "an effect's modifiers and effectors are two lists")
	a.free()


func _pawn(at: Vector3, skip: Array[StringName]) -> Pawn:
	var pawn: Pawn = load(PAWN_SCENE).instantiate()
	pawn.skip_default_parts = skip
	pawn.position = at
	add_child(pawn)
	return pawn


func _ticks(count: int) -> void:
	for i in count:
		await get_tree().physics_frame


func _until(condition: Callable, max_ticks: int) -> void:
	for i in max_ticks:
		if condition.call():
			return
		await get_tree().physics_frame
