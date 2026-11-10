## Written by Claude (claude-opus-5-5), 2026-11-09: what one hit was, handed from the attacking ability to the target's
## Pawn.receive_hit(). Pawn spec section 8.6, step 9.
##
## Plain data. Made on the server only, where hits are decided. Claude 2026-11-09: damage added, step 10.
## Claude 2026-11-10 (pawn spec 8.11): a hit carries effects now, not numbers. damage, knockback_speed, knockback_ticks and
## knockback_hop are gone: the attacking ability's on-hit effects (EffectApplier children) say what the hit does, and the target's
## EffectManager applies them. A hit made in code gives its own, such as [Effect.make_damage(20)].
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
## Claude 2026-11-10: the effects that go on the target, in order.
var effects: Array[Effect] = []
## Claude 2026-11-10: the effects that go on the attacker once the hit lands (an EffectApplier on hit that applies to itself).
var attacker_effects: Array[Effect] = []
## Claude 2026-11-10: filled in when the hit lands: how much Health it took, after resistances. 0 before then.
var damage_dealt := 0.0


## Claude 2026-11-10: how much Health this hit's effects take before resistances, from their StatChangeParts. For readouts that show a
## hit before it lands, such as the swing's debug label.
func planned_damage() -> float:
	var total := 0.0
	for effect in effects:
		if effect:
			total -= effect.planned_change(&"Health")
	return maxf(total, 0.0)
