# Written by Claude (claude-opus-5-5), 2026-11-22. History: abilities/CHANGELOG.md.
@tool
## Who a hit may hit and what it does, for a swing and a projectile alike (ability spec 13.2).
##
## An ability's definition holds one ([member AbilityDefinition.hit]); a sweep step or a ranged attack's projectile can name another, and
## an ability can swap it while playing ([method AbilityBase.use_hit_definition]). Variants come from [Definition]. It matters only where
## hits are decided, so it needs no id on the wire.
class_name HitDefinition
extends Definition

## Which way a hit pushes its target.
enum Push {
	FROM_ATTACKER, ## away from the attacking pawn (a swing)
	ALONG_MOTION, ## the way the hit volume was moving (a projectile's flight)
}

## On: it can hit its own pawn (a projectile once it has left the shooter's body).
@export var hits_self: bool = false:
	set(value):
		hits_self = value
		_changed(&"hits_self", value)
## On: it can hit pawns on the attacker's team.
@export var hits_allies: bool = false:
	set(value):
		hits_allies = value
		_changed(&"hits_allies", value)
## On: it can hit pawns on other teams.
@export var hits_enemies: bool = true:
	set(value):
		hits_enemies = value
		_changed(&"hits_enemies", value)
## Effects on a pawn it hits, as well as the ability's own on-hit EffectApplier children.
@export var target_effects: Array[Effect] = []:
	set(value):
		target_effects = value
		_changed(&"target_effects", value)
## Effects on the attacker when it lands, as well as the ability's own.
@export var attacker_effects: Array[Effect] = []:
	set(value):
		attacker_effects = value
		_changed(&"attacker_effects", value)
## Which way a hit pushes its target.
@export var push := Push.FROM_ATTACKER:
	set(value):
		push = value
		_changed(&"push", value)
## The most pawns one run of it hits (a swing's run, or one projectile): a projectile stops there, a swing hits no one else. 0: no
## limit.
@export_range(0, 100, 1, "or_greater") var max_hits: int = 0:
	set(value):
		max_hits = value
		_changed(&"max_hits", value)
## On: the world can block a hit (ability spec 13.8). It's checked along the weapon's reach, not from the chest: from the attacker's
## axis at the height the hit met the target, out to that point, then on to the target's body. So a swing doesn't hit through a wall,
## but a low crate in front of the attacker doesn't block a swing passing over it. Two short rays per pawn hit. A projectile's flight
## already stops at the world.
@export var blocked_by_world: bool = true:
	set(value):
		blocked_by_world = value
		_changed(&"blocked_by_world", value)
## The physics layers that block it. Leave a layer out to let hits through what's on it (a thin wooden wall).
@export_flags_3d_physics var world_mask: int = 1:
	set(value):
		world_mask = value
		_changed(&"world_mask", value)
## On: a hit still lands when its source is gone (a removed shooter's fireball), with the effects it had when it set off and credit to
## the attacker's id. Off: a source that's gone lands nothing. A removed pawn usually lingers until its projectiles end anyway
## ([member NetworkEntity.linger_until_tick]), so this is for a source that can't.
@export var lands_without_source: bool = false:
	set(value):
		lands_without_source = value
		_changed(&"lands_without_source", value)
## Ends it after this many intersects of any kind (pawns it may or may not hit, the world). 0: no limit.
@export_range(0, 100, 1, "or_greater") var max_intersects: int = 0:
	set(value):
		max_intersects = value
		_changed(&"max_intersects", value)


## True if the whitelist lets it hit this pawn, attacked by that one (null: no attacker, so only the team rules apply).
func allows(attacker: Pawn, target: Pawn, attacker_team: int) -> bool:
	if target == attacker:
		return hits_self
	return hits_allies if target.team == attacker_team else hits_enemies


## The direction a hit pushes: away from the attacker's position, or along the motion.
func push_direction(from: Vector3, target_position: Vector3, motion: Vector3) -> Vector3:
	var along := motion if push == Push.ALONG_MOTION else target_position - from
	along.y = 0.0
	return along.normalized() if along.length_squared() > 0.000001 else Vector3.FORWARD
