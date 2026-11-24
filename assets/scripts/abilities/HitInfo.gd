# Written by Claude (claude-opus-5-5), 2026-11-09. History: abilities/CHANGELOG.md.
## What one hit was, handed from the attacker to the target's [method AbilityManager.receive_hit].
##
## Plain data, made on the server only, where hits are decided. A hit carries effects, not numbers: the attacking ability's on-hit
## effects say what it does, and the target's StatusManager applies them. A hit made in code gives its own, such as
## [code]Effect.make_damage(20)[/code].
## Design: pawn spec 8.6, 8.11.
class_name HitInfo
extends RefCounted

## Who hit.
var attacker: Pawn = null
## The attacker's entity id, the same on every machine (instance id for a pawn not spawned through the session); -1 with none.
## For records and the network, which name pawns by entity id; nothing in the base reads it yet.
var attacker_id := -1
## Who was hit.
var target: Pawn = null
## The ability that hit, such as a MeleeAttackAbility.
var ability: AbilityBase = null
## The tick the hit happened on.
var tick := 0
## Flat, length 1: from the attacker toward the target. Knockback pushes this way.
var direction := Vector3.ZERO
## The effects that go on the target, in order.
var effects: Array[Effect] = []
## The effects that go on the attacker once the hit lands (an on-hit EffectApplier that applies to itself).
var attacker_effects: Array[Effect] = []
## Filled in when the hit lands: how much Health it took, after resistances. 0 before then.
var damage_dealt := 0.0
## True for a hit an interceptor sends back after stopping one (a parry's push-back); it can't be turned away in turn (pawn spec 8.23).
var from_interception := false


## A hit by this ability on this target, carrying the ability's on-hit effects (or those given): what a swing and a projectile both
## make. attacker can be null (a projectile whose shooter is gone).
static func make(attacker_pawn: Pawn, by: AbilityBase, target_pawn: Pawn, push_direction: Vector3, on_tick: int,
		target_effects: Array[Effect], self_effects: Array[Effect]) -> HitInfo:
	var hit := HitInfo.new()
	hit.attacker = attacker_pawn
	hit.attacker_id = attacker_pawn.entity_number() if attacker_pawn else EntityNumber.NONE
	hit.ability = by
	hit.target = target_pawn
	hit.tick = on_tick
	var flat := Vector3(push_direction.x, 0.0, push_direction.z)
	hit.direction = flat.normalized() if flat.length_squared() > 0.0001 else Vector3.FORWARD
	hit.effects = target_effects
	hit.attacker_effects = self_effects
	return hit


## Hands the hit to its target's AbilityManager (a pawn with no abilities can't be hit) and tells the ability it landed.
func deliver() -> void:
	if target and target.ability_manager:
		target.ability_manager.receive_hit(self)
	if ability and is_instance_valid(ability):
		ability.hit_landed.emit(self)


## The Health this hit's effects take before resistances, from their StatChangeParts. For readouts that show a hit before it lands.
func planned_damage() -> float:
	var total := 0.0
	for effect in effects:
		if effect:
			total -= effect.planned_change(StatusManager.HEALTH)
	return maxf(total, 0.0)
