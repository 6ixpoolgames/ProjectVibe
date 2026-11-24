# Written by Claude (claude-opus-5-5), 2026-11-24. History: effects/CHANGELOG.md.
## Parrying: while its effect lasts, hits from the front are blocked and the attacker gets a reply. An [EffectModifier].
##
## Put it in an effect that grants status.parrying, such as a parry's running effect ([member AbilityDefinition.running_effects]). The
## hit ability ([ReceiveHitAbility]) asks it whether the attacker is within [member front_degrees] of where the pawn faces; if so the
## hit is blocked, and [member reply_effects] go to the attacker in a hit of their own on the next tick (a push-back), which can be
## parried in turn. A hit with no attacker (a trap) or from the pawn itself isn't parried. Pawn spec 16.7.
class_name ParryModifier
extends EffectModifier

## How wide the front is, in degrees, centred on where the pawn faces. 120: an attacker up to 60 degrees to either side is parried.
@export_range(0.0, 360.0, 1.0) var front_degrees := 120.0
## What the attacker gets when a hit is parried, in a hit from this pawn (a push-back). Empty: the hit is only blocked.
@export var reply_effects: Array[Effect] = []


func add_held(totals: ModifierTotals, _stacks: int) -> void:
	totals.parries.append(self)


## True if a point is in front of the pawn, within the front. A point right on top of the pawn counts as in front.
func faces(pawn: Pawn, point: Vector3) -> bool:
	var to := point - pawn.global_position
	to.y = 0.0
	if to.length_squared() < 0.0001:
		return true
	var facing := Vector3(-sin(pawn.yaw), 0.0, -cos(pawn.yaw)) # the way the pawn faces: -Z turned by its yaw
	return facing.angle_to(to.normalized()) <= deg_to_rad(front_degrees * 0.5)
