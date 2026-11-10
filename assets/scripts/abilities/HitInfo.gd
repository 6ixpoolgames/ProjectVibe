## Written by Claude (claude-opus-5-5), 2026-11-09: what one hit was, handed from the attacking ability to the target's
## Pawn.receive_hit(). Pawn spec section 8.6, step 9.
##
## Plain data. Made on the server only, where hits are decided. Claude 2026-11-09: damage added, step 10.
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
## Claude 2026-11-09, step 10: health points taken from the target.
var damage := 0
## How fast the target is pushed, in metres per second, at the start of its knockback. 0: no knockback.
var knockback_speed := 0.0
## How many ticks the knockback lasts.
var knockback_ticks := 0
## Claude 2026-11-10: how fast the knockback lifts the target, in metres per second upward, for a small hop. 0: it stays on the ground.
var knockback_hop := 0.0
