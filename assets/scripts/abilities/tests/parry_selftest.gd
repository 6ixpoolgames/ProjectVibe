## Written by Claude (claude-opus-5-5), 2026-11-15: headless self-test for ParryAbility, the owner's request: while it runs, a hit from
## the front does nothing and pushes the attacker back; hits from behind still land; it ends, then cools down; a real swing into a
## parry is turned away and its swing cancelled; and a parry's own push can't be parried back. Also the AI's parry (AIParryBehaviour):
## told a swing is coming, it parries as often as its parry_chance says.
## Exits 0 on success, 1 on failure. Run from the project folder:
##   "C:\Git\Test 2\Godot_v4.7.2-stable_win64_console.exe" --headless --path . "res://assets/scripts/abilities/tests/parry_selftest.tscn"
extends SelfTest # Claude 2026-11-16 (wider audit): _check and _failures come from tests/SelfTest.gd now

# The faction samples' pawn: its abilities (faction_abilities.tscn) include Parry, with parry_knockback.tres on its ParryInterceptor's ON_INTERCEPT applier (Claude 2026-11-17, pawn spec 8.23).
const PAWN_SCENE := "res://assets/scenes/samples/faction_player.tscn"
const GOBLIN_SCENE := "res://assets/scenes/samples/faction_goblin.tscn" # with AI, including AIParryBehaviour
const NO_AI: Array[StringName] = [&"AISensingManager", &"AIMemory", &"AITargetSelector", &"AIStateManager", &"AIBehaviourManager"]


func _ready() -> void:
	print("--- Parry self-test ---")
	TickDriver.tick_rate = TickDriver.REFERENCE_RATE
	var floor_body := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(200, 1, 200)
	shape.shape = box
	shape.position.y = -0.5
	floor_body.add_child(shape)
	add_child(floor_body)
	await _test_front_and_back()
	await _test_real_swing()
	await _test_no_parry_back()
	await _test_ai_parries(1.0)
	await _test_ai_parries(0.0)
	print("--- ALL PASSED ---" if _failures == 0 else "--- %d FAILED ---" % _failures)
	get_tree().quit(0 if _failures == 0 else 1)


# The defender faces -Z (yaw 0); an attacker at -Z is in front of it, one at +Z behind.
func _test_front_and_back() -> void:
	var defender := _make_pawn(Vector3(0, 0.1, 0), 0)
	var front := _make_pawn(Vector3(0, 0.1, -1.5), 1)
	var behind := _make_pawn(Vector3(0, 0.1, 1.5), 1)
	await _ticks(10)
	var parry := _parry_of(defender)
	_check(parry != null and parry.trigger_action == &"parry" and parry.guard() != null and parry.guard().on_intercept_effects.size() == 1,
		"the faction pawns have Parry, on the parry action, with a ParryInterceptor carrying its push-back effect")
	var parried := []
	defender.ability_manager.hit_intercepted.connect(func(hit: HitInfo, _by: HitInterceptor) -> void: parried.append(hit))
	_check(defender.ability_manager.start_ability(parry), "it starts")
	await _ticks(1)
	var before := front.global_position.distance_to(defender.global_position)
	defender.ability_manager.receive_hit(_hit(front, defender, 20))
	var knockback: AbilityBase = front.ability_manager.get_node("Knockback")
	_check(defender.stat_manager.get_health() == 100.0 and parried.size() == 1, "a hit from the front does nothing to it (Health %d), and hit_intercepted goes out" % defender.stat_manager.get_health())
	_check(knockback.is_running_timed(), "the attacker is knocked back")
	await _ticks(10)
	var after := front.global_position.distance_to(defender.global_position)
	_check(after > before + 1.0, "pushed away, a long way (%.1f m to %.1f m)" % [before, after])
	defender.ability_manager.receive_hit(_hit(behind, defender, 20))
	_check(defender.stat_manager.get_health() == 80.0, "a hit from behind still lands (Health %d)" % defender.stat_manager.get_health())
	await _ticks(30)
	_check(not parry.is_running_timed(), "it ends after its duration (0.35 s)")
	defender.ability_manager.receive_hit(_hit(front, defender, 20))
	_check(defender.stat_manager.get_health() == 60.0, "then a hit from the front lands again (Health %d)" % defender.stat_manager.get_health())
	_check(not defender.ability_manager.can_start(&"parry"), "and it's cooling down")
	for pawn in [defender, front, behind]:
		pawn.queue_free()
	await _ticks(2)


# A real swing into a parry: no damage, and the knockback cancels the attacker's swing.
func _test_real_swing() -> void:
	var defender := _make_pawn(Vector3(20, 0.1, 0), 0)
	var attacker := _make_pawn(Vector3(20, 0.1, -1.4), 1)
	await _ticks(10)
	attacker.yaw = PI # facing +Z, toward the defender
	attacker.controller_manager.look_yaw = PI
	var swing: AbilityBase = attacker.ability_manager.get_node("MeleeAttack")
	attacker.ability_manager.start_ability(swing)
	await _ticks(3)
	defender.ability_manager.start_ability(_parry_of(defender))
	for i in 30:
		await get_tree().physics_frame
	_check(defender.stat_manager.get_health() == 100.0, "a swing into a parry does no damage (Health %d)" % defender.stat_manager.get_health())
	_check(not swing.is_running_timed() and attacker.global_position.distance_to(defender.global_position) > 3.0, "and the attacker's swing is cut short as it's pushed away (%.1f m)" % attacker.global_position.distance_to(defender.global_position))
	defender.queue_free()
	attacker.queue_free()
	await _ticks(2)


# Two pawns parrying, facing each other: the first parry's push lands on the other, rather than being parried back.
func _test_no_parry_back() -> void:
	var one := _make_pawn(Vector3(-20, 0.1, 0), 0)
	var two := _make_pawn(Vector3(-20, 0.1, -1.5), 1)
	await _ticks(10)
	two.yaw = PI
	two.controller_manager.look_yaw = PI
	one.ability_manager.start_ability(_parry_of(one))
	two.ability_manager.start_ability(_parry_of(two))
	await _ticks(1)
	one.ability_manager.receive_hit(_hit(two, one, 20))
	var knockback: AbilityBase = two.ability_manager.get_node("Knockback")
	_check(one.stat_manager.get_health() == 100.0 and knockback.is_running_timed(), "a parry's push can't be parried back: it lands on the parrying attacker")
	one.queue_free()
	two.queue_free()
	await _ticks(2)


# An AI goblin with only its Parry behaviour, and a pawn with no AI swinging at it every 130 ticks: a parry is ready again 111 ticks
# after it starts (it runs 21, then cools down for 90).
func _test_ai_parries(chance: float) -> void:
	var goblin: Pawn = load(GOBLIN_SCENE).instantiate()
	goblin.team = 2
	goblin.position = Vector3(40, 0.1, 0)
	var behaviours := goblin.get_node("AIBehaviourManager")
	for child in behaviours.get_children():
		if child.name != &"Parry":
			behaviours.remove_child(child)
			child.free()
	(behaviours.get_node("Parry") as AIParryBehaviour).parry_chance = chance
	add_child(goblin)
	var attacker := _make_pawn(Vector3(40, 0.1, -1.4), 1)
	await _ticks(10)
	var parries := []
	goblin.ability_manager.hit_intercepted.connect(func(hit: HitInfo, _by: HitInterceptor) -> void: parries.append(hit))
	var swing: AbilityBase = attacker.ability_manager.get_node("MeleeAttack")
	for i in 4:
		attacker.global_position = Vector3(40, 0.1, -1.4)
		attacker.velocity = Vector3.ZERO
		attacker.yaw = PI # facing +Z, toward the goblin
		attacker.controller_manager.look_yaw = PI
		attacker.ability_manager.start_ability(swing)
		await _ticks(130)
	if chance >= 1.0:
		_check(parries.size() == 4 and goblin.stat_manager.get_health() == 100.0, "the AI, told a swing is coming, parries it (%d of 4, Health %d)" % [parries.size(), goblin.stat_manager.get_health()])
	else:
		_check(parries.is_empty() and goblin.stat_manager.get_health() < 100.0, "and with parry_chance 0 it never does (%d parried, Health %d)" % [parries.size(), goblin.stat_manager.get_health()])
	goblin.queue_free()
	attacker.queue_free()
	await _ticks(2)


func _parry_of(pawn: Pawn) -> ParryAbility:
	for ability in pawn.ability_manager.get_abilities():
		if ability is ParryAbility:
			return ability
	return null


func _hit(attacker: Pawn, target: Pawn, damage: int) -> HitInfo:
	var hit := HitInfo.new()
	hit.attacker = attacker
	hit.target = target
	hit.tick = TickDriver.tick
	hit.effects = [Effect.make_damage(damage)]
	var away := target.global_position - attacker.global_position
	away.y = 0.0
	hit.direction = away.normalized()
	return hit


func _make_pawn(at: Vector3, team: int) -> Pawn:
	var pawn: Pawn = load(PAWN_SCENE).instantiate()
	pawn.skip_default_parts = NO_AI
	pawn.team = team
	pawn.position = at
	add_child(pawn)
	return pawn


func _ticks(count: int) -> void:
	for i in count:
		await get_tree().physics_frame
