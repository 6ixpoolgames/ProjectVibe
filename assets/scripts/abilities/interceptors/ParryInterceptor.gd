## Written by Claude (claude-opus-5-5), 2026-11-17 (pawn spec 8.23): turns away hits from the front. A TURN_AWAY HitInterceptor (see
## HitInterceptor.gd): the hit arrives, so the AI notices it, then none of its effects land if the attacker is within front_degrees
## of where the pawn faces. Its ON_INTERCEPT EffectApplier children say what happens next (in the samples, parry_knockback.tres
## pushes the attacker back). Replaces ParryAbility.try_parry, AbilityManager.parry_hit and the parry-only lists on every ability.
##
## Odd cases:
##   - A hit with no attacker (a trap, a poison's tick) isn't turned away: there's no "front" for it to come from.
##   - A pawn's own hit on itself isn't turned away.
##   - A reply to an interception can't be turned away (HitInterceptor's rule), so two pawns parrying each other don't bounce hits.
class_name ParryInterceptor
extends HitInterceptor

## How wide the front is, in degrees, centred on where the pawn faces. 120: an attacker up to 60 degrees to either side is turned away.
@export_range(0.0, 360.0, 1.0) var front_degrees := 120.0


func _init() -> void:
	super()
	stage = Stage.TURN_AWAY
	debug_label = "PARRIED"


func intercept(hit: HitInfo) -> Result:
	var attacker := hit.attacker
	if attacker == null or not is_instance_valid(attacker) or attacker == pawn:
		return Result.PASS
	return Result.STOP if faces(attacker.global_position) else Result.PASS


## The front's width now. One place to read it, so it can come from a stat later (see HitInterceptor, "Room for stats").
func front_degrees_now() -> float:
	return front_degrees


## True if a point is in front of the pawn, within the front. A point right on top of the pawn counts as in front.
func faces(point: Vector3) -> bool:
	var to := point - pawn.global_position
	to.y = 0.0
	if to.length_squared() < 0.0001:
		return true
	var facing := Vector3(-sin(pawn.yaw), 0.0, -cos(pawn.yaw)) # the way the pawn faces: -Z turned by its yaw
	return facing.angle_to(to.normalized()) <= deg_to_rad(front_degrees_now() * 0.5)
