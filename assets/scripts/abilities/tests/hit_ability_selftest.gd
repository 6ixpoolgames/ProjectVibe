## Written by Claude (claude-opus-5-5), 2026-11-24 (pawn spec 16.7, 16.10 step 4b): the hit ability and abilities started by events.
##   - a pawn without a hit ability gets one; a hit arrives, lands, and event.hit.taken starts it with the hit as its trigger data
##   - ignored: a pawn owning status.hit_immune doesn't even notice (no hit_arrived)
##   - blocked: dead, invulnerable, or parrying from the front: hit_arrived and hit_blocked go out, no effects land
##   - a parry's reply goes to the attacker on the next tick, and can be parried in turn; a hit from behind lands
##   - a parry's stance is a running effect: the pawn owns status.parrying while it runs, not after
##   - an ability with a trigger_event starts from it, reading its payload; Knockback starts from a KnockbackEffector's event
##   - charges refill on event.revived, and charges_version moves when they change
## Exits 0 on success, 1 on failure. Run from the project folder:
##   bash tools/run_tests.sh hit_ability
extends SelfTest

const PAWN_SCENE := "res://assets/scenes/pawn/pawn.tscn"


## A test-only ability started by event.damage.taken, which notes the damage its event carried.
class Flinch extends AbilityBase:
	var seen := -1.0

	func _init() -> void:
		super()
		kind = Kind.ACTION
		self.category = &"ability.utility.interact"
		self.trigger_event = Tags.EVENT.DAMAGE_TAKEN
		self.duration_ticks = 10

	func start() -> void:
		seen = trigger_data.magnitude if trigger_data else -1.0


## A test-only ability with two charges that only a refill gives back.
class TwoShots extends AbilityBase:
	func _init() -> void:
		super()
		kind = Kind.ACTION
		self.category = &"ability.utility.interact"
		self.max_charges = 2


func _ready() -> void:
	print("--- Hit ability self-test ---")
	TickDriver.tick_rate = TickDriver.REFERENCE_RATE # these checks count ticks at 60
	var floor_body := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(300, 1, 300)
	shape.shape = box
	shape.position.y = -0.5
	floor_body.add_child(shape)
	add_child(floor_body)
	await _test_lands_and_default()
	await _test_ignored_and_blocked()
	await _test_parry()
	await _test_reply_parried()
	await _test_events_and_charges()
	_finish()


func _test_lands_and_default() -> void:
	var walk := WalkAbility.new()
	walk.name = "Walk"
	var target := _make_pawn(Vector3(0, 0.1, 0), [walk])
	var attacker := _make_pawn(Vector3(0, 0.1, -2), [])
	await _ticks(5)
	var receive := target.ability_manager.get_node_or_null("ReceiveHit")
	_check(receive is ReceiveHitAbility, "a pawn whose abilities have no hit ability gets one")
	var log := _listen(target)
	target.ability_manager.receive_hit(_hit(attacker, target, 20))
	_check(log["arrived"] == 1 and log["received"] == 1 and log["blocked"].is_empty() and target.status_manager.get_health() == 80.0,
		"a hit arrives and lands (arrived %d, received %d, Health %d)" % [log["arrived"], log["received"], target.status_manager.get_health()])
	await _free(target, attacker)


func _test_ignored_and_blocked() -> void:
	var target := _make_pawn(Vector3(20, 0.1, 0), [])
	var attacker := _make_pawn(Vector3(20, 0.1, -2), [])
	await _ticks(5)
	var log := _listen(target)
	# Ignored: not even noticed.
	target.owned_tags.add(Tags.STATUS.HIT_IMMUNE)
	target.ability_manager.receive_hit(_hit(attacker, target, 20))
	_check(log["arrived"] == 0 and target.status_manager.get_health() == 100.0, "a pawn owning status.hit_immune ignores a hit: no hit_arrived, no damage")
	target.owned_tags.remove(Tags.STATUS.HIT_IMMUNE)
	# Invulnerable: noticed, blocked.
	target.status_manager.apply_effect(Effect.make_invulnerable(30), target)
	_check(target.ability_manager.is_invulnerable(), "an effect granting status.invulnerable makes it invulnerable")
	target.ability_manager.receive_hit(_hit(attacker, target, 20))
	_check(log["arrived"] == 1 and log["blocked"] == [ReceiveHitAbility.BLOCKED_INVULNERABLE] and target.status_manager.get_health() == 100.0,
		"an invulnerable pawn's hit arrives (the AI notes it) and is blocked: %s" % [log["blocked"]])
	await _ticks(35)
	_check(not target.ability_manager.is_invulnerable(), "and not once the effect ends")
	# Dead: blocked too.
	target.ability_manager.health_ran_out(null)
	_check(target.is_dead(), "(it's dead)")
	target.ability_manager.receive_hit(_hit(attacker, target, 20))
	_check(log["arrived"] == 2 and log["blocked"].back() == ReceiveHitAbility.BLOCKED_DEAD, "a dead pawn's hit is blocked: %s" % [log["blocked"]])
	await _free(target, attacker)


# The defender faces -Z (yaw 0); an attacker at -Z is in front of it, one at +Z behind.
func _test_parry() -> void:
	var defender := _make_pawn(Vector3(40, 0.1, 0), [])
	var front := _make_pawn(Vector3(40, 0.1, -1.5), [])
	var behind := _make_pawn(Vector3(40, 0.1, 1.5), [])
	await _ticks(5)
	var parry := ParryAbility.new()
	parry.name = "Parry"
	defender.ability_manager.add_child(parry)
	defender.ability_manager.settings_changed()
	_check(parry.guard() != null and is_equal_approx(parry.guard().front_degrees, 120.0) and parry.guard().reply_effects.is_empty(),
		"a Parry with no running effects of its own parries 120 degrees wide, with nothing back")
	# A stance of its own: parrying with a push back.
	var push: Array[Effect] = [Effect.make_knockback(10.0, 15)]
	var stance := Effect.make_parrying(90.0, push)
	stance.effect_name = &"test parry stance"
	var running: Array[Effect] = [stance]
	parry.use_definition(_parry_definition(running))
	_check(defender.ability_manager.start_ability(parry) and defender.owned_tags.has(Tags.STATUS.PARRYING), "while it runs, the pawn owns status.parrying")
	var log := _listen(defender)
	var knockback: KnockbackAbility = front.ability_manager.get_knockback()
	defender.ability_manager.receive_hit(_hit(front, defender, 20))
	_check(log["blocked"] == [ReceiveHitAbility.BLOCKED_PARRIED] and defender.status_manager.get_health() == 100.0 and log["arrived"] == 1,
		"a hit from the front arrives and is parried: no damage (%s, Health %d)" % [log["blocked"], defender.status_manager.get_health()])
	_check(not knockback.is_running_timed(), "the reply isn't delivered in the same tick")
	await _ticks(2)
	_check(knockback.is_running_timed(), "it lands on the attacker on the next tick, and its push starts Knockback (an event)")
	defender.ability_manager.receive_hit(_hit(behind, defender, 20))
	_check(defender.status_manager.get_health() == 80.0, "a hit from behind lands (Health %d)" % defender.status_manager.get_health())
	await _ticks(30)
	_check(not parry.is_running_timed() and not defender.owned_tags.has(Tags.STATUS.PARRYING), "once the stance ends, status.parrying goes with it")
	await _free(defender, front, behind)


# Two pawns parrying, facing each other: the reply to a parried hit is parried back, and so on, a tick at a time, until a stance ends.
func _test_reply_parried() -> void:
	var one := _make_pawn(Vector3(60, 0.1, 0), [])
	var two := _make_pawn(Vector3(60, 0.1, -1.5), [])
	await _ticks(5)
	two.yaw = PI
	var push: Array[Effect] = [Effect.make_knockback(10.0, 15)]
	var stance := Effect.make_parrying(120.0, push)
	stance.effect_name = &"test parry back stance"
	stance.lasts_until_removed = false
	stance.duration_ticks = 6
	stance.register()
	one.status_manager.apply_effect(stance, one)
	two.status_manager.apply_effect(stance, two)
	var log_one := _listen(one)
	var log_two := _listen(two)
	one.ability_manager.receive_hit(_hit(two, one, 20))
	await _ticks(2)
	_check(log_two["blocked"] == [ReceiveHitAbility.BLOCKED_PARRIED], "the reply is parried by the attacker in turn: %s" % [log_two["blocked"]])
	await _ticks(10)
	var pushed: bool = one.ability_manager.get_knockback().is_running_timed() or two.ability_manager.get_knockback().is_running_timed() \
		or log_one["received"] + log_two["received"] > 0
	_check(pushed and one.status_manager.get_health() == 100.0, "once a stance ends, the next reply lands (%d and %d parried)" % [log_one["blocked"].size(), log_two["blocked"].size()])
	await _free(one, two)


func _test_events_and_charges() -> void:
	var flinch := Flinch.new()
	flinch.name = "Flinch"
	var shots := TwoShots.new()
	shots.name = "TwoShots"
	var target := _make_pawn(Vector3(80, 0.1, 0), [flinch, shots])
	var attacker := _make_pawn(Vector3(80, 0.1, -2), [])
	await _ticks(5)
	target.ability_manager.receive_hit(_hit(attacker, target, 25))
	_check(flinch.is_running_timed() and is_equal_approx(flinch.seen, 25.0), "an ability with trigger_event event.damage.taken starts from it, reading its payload (%.0f)" % flinch.seen)
	_check(flinch.trigger_data == null, "and trigger_data is cleared once it has started")
	var version := shots.charges_version
	target.ability_manager.start_ability(shots)
	target.ability_manager.start_ability(shots)
	_check(shots.charges_left() == 0 and shots.charges_version >= version + 2, "charges_version moves as charges are spent (%d to %d)" % [version, shots.charges_version])
	target.ability_manager.health_ran_out(null)
	target.ability_manager.revive()
	_check(shots.charges_left() == 2, "a revive sends event.revived, which refills charges (%d)" % shots.charges_left())
	await _free(target, attacker)


# --- Helpers ---


func _parry_definition(running: Array[Effect]) -> ParryDefinition:
	var definition := ParryDefinition.new()
	definition.running_effects = running
	return definition


# Counts what the manager says about hits on this pawn.
func _listen(pawn: Pawn) -> Dictionary:
	var log := {"arrived": 0, "received": 0, "blocked": []}
	pawn.ability_manager.hit_arrived.connect(func(_hit: HitInfo) -> void: log["arrived"] += 1)
	pawn.ability_manager.hit_received.connect(func(_hit: HitInfo) -> void: log["received"] += 1)
	pawn.ability_manager.hit_blocked.connect(func(_hit: HitInfo, reason: StringName) -> void: log["blocked"].append(reason))
	return log


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


# The default pawn, or one whose AbilityManager holds only these abilities (no hit ability: the manager adds it).
func _make_pawn(at: Vector3, abilities: Array) -> Pawn:
	var pawn: Pawn = load(PAWN_SCENE).instantiate()
	pawn.position = at
	if not abilities.is_empty():
		var manager := AbilityManager.new()
		manager.name = "AbilityManager" # the same name as the default, so PawnInitializer leaves this one alone
		for ability: AbilityBase in abilities:
			manager.add_child(ability)
		var death := DeathAbility.new()
		death.name = "Death"
		manager.add_child(death)
		pawn.add_child(manager)
	add_child(pawn)
	return pawn


func _free(a: Pawn, b: Pawn, c: Pawn = null) -> void:
	for pawn in [a, b, c]:
		if pawn:
			pawn.queue_free()
	await _ticks(2)


func _ticks(count: int) -> void:
	for i in count:
		await get_tree().physics_frame
