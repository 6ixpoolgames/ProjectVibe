## Written by Claude (claude-opus-5-5), 2026-11-10: headless self-test for effects (pawn spec 8.11): effect tags, instant effects
## (damage, resistances and weaknesses, immunity, lifesteal, invulnerability), over-time effects (slows that hold and end, poisons
## that tick and can kill, stacking, cleanses, dying clearing them), boosts to ability numbers, a rollback loading the active list,
## and the odd cases at the top of EffectManager.gd and Effect.gd.
## Exits 0 on success, 1 on failure. Run from the project folder:
##   "C:\Git\Test 2\Godot_v4.7.2-stable_win64_console.exe" --headless --path . "res://assets/scripts/effects/tests/effect_selftest.tscn"
extends Node

const PAWN_SCENE := "res://assets/scenes/pawn/pawn.tscn"
const NO_AI: Array[StringName] = [&"AISensingManager", &"AIMemory", &"AITargetSelector", &"AIStateManager", &"AIBehaviourManager"]

var _failures := 0


func _ready() -> void:
	print("--- Effect self-test ---")
	TickDriver.tick_rate = TickDriver.REFERENCE_RATE # these checks count ticks at 60
	var floor_body := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(200, 1, 200)
	shape.shape = box
	shape.position.y = -0.5
	floor_body.add_child(shape)
	add_child(floor_body)
	_test_tags()
	await _test_instant()
	await _test_over_time()
	await _test_poison()
	await _test_stacking_and_removing()
	await _test_ability_numbers()
	await _test_rollback_load()
	print("--- ALL PASSED ---" if _failures == 0 else "--- %d FAILED ---" % _failures)
	get_tree().quit(0 if _failures == 0 else 1)


func _test_tags() -> void:
	var declared := EffectTags.read_declared_tags()
	var constants: Array[StringName] = [EffectTags.DAMAGE, EffectTags.DAMAGE_PHYSICAL, EffectTags.DAMAGE_ELEMENTAL,
			EffectTags.DAMAGE_ELEMENTAL_FIRE, EffectTags.DAMAGE_ELEMENTAL_FROST, EffectTags.DAMAGE_POISON, EffectTags.HEAL,
			EffectTags.BUFF, EffectTags.BUFF_COMBO, EffectTags.DEBUFF, EffectTags.DEBUFF_SLOW]
	var missing: Array[StringName] = []
	for tag in constants:
		if not declared.has(tag):
			missing.append(tag)
	_check(missing.is_empty(), "every EffectTags constant is declared in the effect tag declarations (missing: %s)" % [missing])
	var fire := EffectTags.mask_of(EffectTags.DAMAGE_ELEMENTAL_FIRE)
	_check(fire & EffectTags.own_bit(EffectTags.DAMAGE) != 0 and fire & EffectTags.own_bit(EffectTags.DAMAGE_ELEMENTAL) != 0 and fire & EffectTags.own_bit(EffectTags.DAMAGE_PHYSICAL) == 0, "a fire tag's mask holds damage and damage.elemental, and not damage.physical")
	_check(not EffectTags.has_tag(&"no.such.tag") and EffectTags.own_bit(&"") == 0, "a question never adds a tag, and an empty tag has no bit")
	var effect := Effect.make_damage(5, [EffectTags.DAMAGE_ELEMENTAL_FIRE])
	_check(effect.has_tag(EffectTags.DAMAGE_ELEMENTAL) and not effect.has_tag(EffectTags.DAMAGE_PHYSICAL), "an effect answers to its tags' parents")
	_check(effect.get_id() == Effect.make_damage(1).get_id() and effect.get_id() != 0, "effects made in code with the same effect_name share an id, which is never 0")
	_check(TagRegistry.has_tag(Tags.COMBO_SECOND) and TagRegistry.has_tag(Tags.COMBO_FINISHER), "the combo ability tags are declared")


func _test_instant() -> void:
	var a := _pawn(Vector3(0, 0.1, 0))
	var b := _pawn(Vector3(3, 0.1, 0))
	await _ticks(3)
	_check(a.effect_manager != null and a.effect_manager.name == &"EffectManager", "a pawn gets an EffectManager as a default part")
	a.effect_manager.apply_effect(Effect.make_damage(20), b)
	_check(a.get_health() == 80.0, "damage takes Health (%d)" % a.get_health())
	a.effect_manager.resistances[EffectTags.DAMAGE_ELEMENTAL] = 0.2
	a.effect_manager.resistances[EffectTags.DAMAGE_ELEMENTAL_FIRE] = 0.3
	a.effect_manager.active_effects = a.effect_manager.active_effects # the inspector's resistances are read when the list changes
	var fire := Effect.make_damage(20, [EffectTags.DAMAGE_ELEMENTAL_FIRE])
	_check(is_equal_approx(a.effect_manager.resistance_to(fire), 0.5), "resistances to a tag and its parent add up (0.2 + 0.3 = %.2f)" % a.effect_manager.resistance_to(fire))
	a.effect_manager.apply_effect(fire, b)
	_check(a.get_health() == 70.0, "and take that share off (20 fire damage takes 10: %d)" % a.get_health())
	a.effect_manager.resistances[EffectTags.DAMAGE_ELEMENTAL_FROST] = -0.5
	a.effect_manager.active_effects = a.effect_manager.active_effects
	a.effect_manager.apply_effect(Effect.make_damage(10, [EffectTags.DAMAGE_ELEMENTAL_FROST]), b)
	_check(a.get_health() == 57.0, "a weakness adds to it (10 frost with 0.2 - 0.5 takes 13: %d)" % a.get_health())
	a.effect_manager.resistances[EffectTags.DAMAGE_POISON] = 1.0
	a.effect_manager.active_effects = a.effect_manager.active_effects
	_check(not a.effect_manager.apply_effect(Effect.make_damage(10, [EffectTags.DAMAGE_POISON]), b) and a.get_health() == 57.0, "1 or more: immune, the effect is refused")
	var heal := _effect(&"test heal", false, 0.0, [_change(&"Health", 15.0)])
	a.effect_manager.apply_effect(heal, a)
	_check(a.get_health() == 72.0, "a heal adds Health, and resistances don't touch it (%d)" % a.get_health())
	# Lifesteal: b hits a for 20 physical and gets 30% back.
	b.stat_manager.change_current(&"Health", -50.0)
	var vampire := _effect(&"vampire hit", true, 0.0, [_change(&"Health", -20.0), _lifesteal(0.3)])
	a.effect_manager.apply_effect(vampire, b)
	_check(a.get_health() == 52.0 and is_equal_approx(b.get_health(), 56.0), "lifesteal gives the source a share of the damage just dealt (a %d, b %.1f)" % [a.get_health(), b.get_health()])
	# A hit's damage_dealt, and the attacker's own on-hit effects.
	var hit := HitInfo.new()
	hit.attacker = b
	hit.target = a
	hit.direction = Vector3(1, 0, 0)
	hit.effects = [Effect.make_damage(10)]
	hit.attacker_effects = [heal]
	a.receive_hit(hit)
	_check(hit.damage_dealt == 10.0 and a.get_health() == 42.0 and is_equal_approx(b.get_health(), 71.0), "a hit fills in damage_dealt, and its attacker effects go on the attacker (dealt %d, b %.1f)" % [hit.damage_dealt, b.get_health()])
	# Invulnerability stops harmful effects and lets helpful ones through.
	_ai(a).move_in_direction(Vector3(0, 0, 1))
	await _ticks(2)
	_ai(a).press(&"dash")
	await _ticks(2)
	_check(a.is_invulnerable(), "(a is dashing)")
	_check(not a.effect_manager.apply_effect(Effect.make_damage(10), b) and a.get_health() == 42.0, "a dashing pawn refuses harmful effects")
	_check(a.effect_manager.apply_effect(heal, a) and a.get_health() == 57.0, "and takes helpful ones (%d)" % a.get_health())
	_ai(a).stop()
	await _ticks(30)
	# Instant effects with held parts warn and do nothing.
	var held_on_instant := _effect(&"held on instant", false, 0.0, [_modifier(&"MoveSpeed", 0.0, 2.0)])
	a.effect_manager.apply_effect(held_on_instant, a)
	_check(a.stat_manager.get_value(&"MoveSpeed") == 5.0, "held parts on an instant effect do nothing")
	# Death: an effect that takes the last Health kills, and the parts after it are skipped.
	var after_death := _effect(&"overkill", true, 0.0, [_change(&"Health", -1000.0), _change(&"Health", 50.0)])
	a.effect_manager.apply_effect(after_death, b)
	_check(a.is_dead() and a.get_health() == 0.0, "an effect that takes the last Health kills the pawn, and the parts after it don't run")
	_check(not a.effect_manager.apply_effect(heal, a), "a dead pawn takes no effects")
	a.free()
	b.free()


func _test_over_time() -> void:
	var a := _pawn(Vector3(0, 0.1, 0))
	await _ticks(3)
	var slow := _effect(&"test slow", true, 0.5, [_modifier(&"MoveSpeed", 0.0, 0.6)])
	slow.tags = [EffectTags.DEBUFF_SLOW]
	a.effect_manager.apply_effect(slow, null)
	_check(a.effect_manager.has_effect(slow) and is_equal_approx(a.stat_manager.get_value(&"MoveSpeed"), 3.0), "a slow holds while it lasts: MoveSpeed 5 x0.6 = %.2f" % a.stat_manager.get_value(&"MoveSpeed"))
	_check(not a.effect_manager.can_rest() and a.effect_manager.get_ticks_left(slow) == 30, "a pawn with an effect on it doesn't rest; 0.5 s is 30 ticks (%d)" % a.effect_manager.get_ticks_left(slow))
	_ai(a).move_in_direction(Vector3(1, 0, 0))
	await _ticks(20)
	var slowed_speed := Vector2(a.velocity.x, a.velocity.z).length()
	_check(slowed_speed < 3.05 and slowed_speed > 2.5, "and the pawn walks slower (%.2f m/s)" % slowed_speed)
	await _ticks(15)
	_check(not a.effect_manager.has_effect(slow) and a.stat_manager.get_value(&"MoveSpeed") == 5.0, "it ends at its deadline, and MoveSpeed goes back to its base (%.2f)" % a.stat_manager.get_value(&"MoveSpeed"))
	_ai(a).stop()
	# Max Health lowered below what the pawn has: what it has falls too.
	var frailty := _effect(&"test less health", true, 0.2, [_modifier(&"Health", -40.0, 1.0)])
	a.effect_manager.apply_effect(frailty, null)
	await _ticks(1)
	_check(a.stat_manager.get_value(&"Health") == 60.0 and a.get_health() == 60.0, "a lower most Health brings what it has down with it (%d of %d)" % [a.get_health(), a.stat_manager.get_value(&"Health")])
	await _ticks(20)
	_check(a.stat_manager.get_value(&"Health") == 100.0 and a.get_health() == 60.0, "and when it ends, the most goes back, and what it has stays (%d of %d)" % [a.get_health(), a.stat_manager.get_value(&"Health")])
	a.free()


func _test_poison() -> void:
	var a := _pawn(Vector3(0, 0.1, 0))
	var b := _pawn(Vector3(3, 0.1, 0))
	await _ticks(3)
	var poison := _effect(&"test poison", true, 0.5, [_change(&"Health", -5.0)])
	poison.period_seconds = 0.1
	poison.tags = [EffectTags.DAMAGE_POISON]
	a.effect_manager.apply_effect(poison, b)
	_check(a.get_health() == 95.0, "a poison runs once when first applied (%d)" % a.get_health())
	await _ticks(40)
	_check(a.get_health() == 75.0 and not a.effect_manager.has_effect(poison), "then every period while it lasts: 0.5 s at 0.1 s is 5 times, 25 Health (%d)" % a.get_health())
	var source: Array = []
	a.effect_manager.apply_effect(poison, b)
	source.append(a.effect_manager.get_active_effects()[0]["source"])
	_check(source[0] == b, "the active list remembers who applied it")
	a.effect_manager.remove_all()
	a.stat_manager.change_current(&"Health", -62.0) # 8 left
	a.effect_manager.apply_effect(poison, b)
	await _ticks(10)
	_check(a.is_dead() and a.effect_manager.get_active_effects().is_empty(), "a poison's tick can kill, and dying ends every effect")
	a.free()
	b.free()


func _test_stacking_and_removing() -> void:
	var a := _pawn(Vector3(0, 0.1, 0))
	await _ticks(3)
	var refresh := _effect(&"test refresh", true, 0.5, [_modifier(&"MoveSpeed", -1.0, 1.0)])
	a.effect_manager.apply_effect(refresh, null)
	await _ticks(10)
	a.effect_manager.apply_effect(refresh, null)
	_check(a.effect_manager.get_ticks_left(refresh) == 30 and a.effect_manager.get_stacks(refresh) == 1 and a.stat_manager.get_value(&"MoveSpeed") == 4.0, "REFRESH: its time starts again, still one stack")
	var stacking := _effect(&"test stacks", true, 0.5, [_modifier(&"MoveSpeed", 0.0, 0.5)])
	stacking.stacking = Effect.Stacking.ADD_STACK
	stacking.max_stacks = 2
	for i in 3:
		a.effect_manager.apply_effect(stacking, null)
	_check(a.effect_manager.get_stacks(stacking) == 2 and is_equal_approx(a.stat_manager.get_value(&"MoveSpeed"), 1.0), "ADD_STACK: up to max_stacks, each stack counting again ((5 - 1) x0.5 x0.5 = %.2f)" % a.stat_manager.get_value(&"MoveSpeed"))
	var ignore := _effect(&"test ignore", true, 0.5, [])
	ignore.stacking = Effect.Stacking.IGNORE
	_check(a.effect_manager.apply_effect(ignore, null) and not a.effect_manager.apply_effect(ignore, null), "IGNORE: the second application is refused")
	stacking.tags = [EffectTags.DEBUFF_SLOW]
	stacking._mask = -1
	a.effect_manager.remove_with_tag(EffectTags.DEBUFF)
	_check(not a.effect_manager.has_effect(stacking) and a.effect_manager.has_effect(refresh) and a.stat_manager.get_value(&"MoveSpeed") == 4.0, "remove_with_tag(debuff) removes what's tagged debuff.slow and leaves the rest")
	a.effect_manager.max_active_effects = 3
	var extra := _effect(&"test extra", true, 0.5, [])
	var another := _effect(&"test another", true, 0.5, [])
	_check(a.effect_manager.apply_effect(extra, null) and not a.effect_manager.apply_effect(another, null), "a full list refuses a new effect")
	a.effect_manager.remove_all()
	await _ticks(1)
	_check(a.effect_manager.can_rest() and a.stat_manager.get_value(&"MoveSpeed") == 5.0, "remove_all empties the list, and the stats go back")
	a.free()


func _test_ability_numbers() -> void:
	var a := _pawn(Vector3(0, 0.1, 0))
	await _ticks(3)
	var manager := a.ability_manager
	var melee: MeleeAttackAbility = manager.get_node("MeleeAttack")
	var sprint: AbilityBase = manager.get_node("Sprint")
	var frail := _effect(&"test easy to interrupt", true, 3.0, [_number(Tags.COMBAT, AbilityPriorityPart.Number.INTERRUPT_THRESHOLD, -10)])
	a.effect_manager.apply_effect(frail, null)
	_check(manager.interrupt_threshold_now(melee) == 5 and manager.interrupt_threshold_now(sprint) == sprint.interrupt_threshold, "an interrupt threshold change reaches the group it names and nothing else (swing 15 - 10 = %d)" % manager.interrupt_threshold_now(melee))
	_ai(a).press(&"primary")
	await _ticks(2)
	_ai(a).hold(&"sprint")
	await _ticks(2)
	_check(not melee.is_running_timed() and sprint.is_running_timed(), "so sprinting (10) now cancels a swing (threshold 5)")
	_ai(a).hold(&"sprint", false)
	await _ticks(70)
	var rows := manager.get_interrupt_table()
	var swing_row: Dictionary = rows.filter(func(row): return row["running"] == &"MeleeAttack")[0]
	_check(swing_row["threshold"] == 5 and swing_row["cells"][&"Sprint"]["result"] == "cancels", "and the interrupt table shows it")
	var strong := _effect(&"test strong dash", false, 1.0, [_number(Tags.MOVEMENT_DASH, AbilityPriorityPart.Number.INTERRUPT_PRIORITY, 5)])
	a.effect_manager.apply_effect(strong, null)
	var dash: AbilityBase = manager.get_node("Dash")
	_check(manager.interrupt_priority_now(dash) == dash.interrupt_priority + 5 and manager.press_priority_now(dash) == dash.priority, "an interrupt priority change is kept apart from press priority")
	a.free()


# A rollback loads an older active list through its setter: the held parts are worked out again from it.
func _test_rollback_load() -> void:
	var a := _pawn(Vector3(0, 0.1, 0))
	await _ticks(3)
	var before := a.effect_manager.active_effects.duplicate()
	var slow := _effect(&"test rollback slow", true, 1.0, [_modifier(&"MoveSpeed", 0.0, 0.5)])
	a.effect_manager.apply_effect(slow, null)
	var during := a.effect_manager.active_effects.duplicate()
	await _ticks(1)
	_check(a.stat_manager.get_value(&"MoveSpeed") == 2.5, "(slowed)")
	a.effect_manager.active_effects = before
	await _ticks(1)
	_check(a.stat_manager.get_value(&"MoveSpeed") == 5.0 and not a.effect_manager.has_effect(slow), "loading the list from before the slow removes it and its change")
	a.effect_manager.active_effects = during
	await _ticks(1)
	_check(a.stat_manager.get_value(&"MoveSpeed") == 2.5 and a.effect_manager.has_effect(slow), "loading it back puts them back")
	var tick_state: TickStateComponent = null
	for child in a.get_children():
		if child is TickStateComponent:
			tick_state = child
	_check(tick_state != null and Array(tick_state.state_properties).any(func(entry): return String(entry).begins_with("EffectManager:active_effects")), "the active list is in the pawn's rolled-back state")
	a.free()


# --- Helpers ---


func _pawn(at: Vector3) -> Pawn:
	var pawn: Pawn = load(PAWN_SCENE).instantiate()
	pawn.skip_default_parts = NO_AI
	pawn.position = at
	add_child(pawn)
	return pawn


func _effect(effect_name: StringName, harmful: bool, seconds: float, parts: Array[EffectPart]) -> Effect:
	var effect := Effect.new()
	effect.effect_name = effect_name
	effect.is_harmful = harmful
	effect.duration_seconds = seconds
	effect.parts = parts
	return effect


func _change(stat: StringName, amount: float) -> StatChangePart:
	var part := StatChangePart.new()
	part.stat = stat
	part.amount = amount
	return part


func _lifesteal(fraction: float) -> LifestealPart:
	var part := LifestealPart.new()
	part.fraction = fraction
	return part


func _modifier(stat: StringName, add: float, multiply: float) -> StatModifierPart:
	var part := StatModifierPart.new()
	part.stat = stat
	part.add = add
	part.multiply = multiply
	return part


func _number(tag: StringName, number: AbilityPriorityPart.Number, amount: int) -> AbilityPriorityPart:
	var part := AbilityPriorityPart.new()
	part.ability_tag = tag
	part.number = number
	part.amount = amount
	return part


func _ai(pawn: Pawn) -> AIController:
	return pawn.controller_manager.ai_controller as AIController


func _ticks(count: int) -> void:
	for i in count:
		await get_tree().physics_frame


func _check(passed: bool, what: String) -> void:
	print("  %s %s" % ["ok  " if passed else "FAIL", what])
	if not passed:
		_failures += 1
