# Written by Claude (claude-opus-5-5), 2026-11-09. History: abilities/CHANGELOG.md.
## What one hit was, handed from the attacker to the target's [method AbilityManager.receive_hit].
##
## Pawn spec sections 8.6 and 8.11. Plain data, made on the server only, where hits are decided. A hit carries effects, not numbers:
## the attacking ability's on-hit effects (its EffectApplier children) say what the hit does, and the target's EffectManager applies
## them. A hit made in code gives its own, such as [code][Effect.make_damage(20)][/code].
class_name HitInfo
extends RefCounted

## Who hit.
var attacker: Pawn = null
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
## The effects that go on the attacker once the hit lands (an EffectApplier on hit that applies to itself).
var attacker_effects: Array[Effect] = []
## Filled in when the hit lands: how much Health it took, after resistances. 0 before then.
var damage_dealt := 0.0
## True for a hit a HitInterceptor sends back after stopping one (a parry's push-back). Such a hit can't be turned away in its turn
## (pawn spec 8.23).
var from_interception := false


## How much Health this hit's effects take before resistances, from their StatChangeParts. For readouts that show a hit before it
## lands, such as the swing's debug label.
func planned_damage() -> float:
	var total := 0.0
	for effect in effects:
		if effect:
			total -= effect.planned_change(StatManager.HEALTH)
	return maxf(total, 0.0)
