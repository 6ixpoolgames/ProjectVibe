## Written by Claude (claude-opus-5-5), 2026-11-15: a parry, the owner's request. While it runs, a hit from the front does nothing to
## this pawn, and the attacker is pushed back hard instead. Hits from the sides and back land as usual.
##
## Claude 2026-11-15: FLAGGED AS A SHORTCUT, the owner's call: this works, but it's hacky and needs a proper implementation pass later
## (pawn spec 14, "Shortcuts to redo"). AbilityManager keeps a list of ParryAbility nodes by type, AbilityBase carries parry-only
## effect lists that every ability has, EffectApplier has a parry-only trigger, and Pawn._take_hit asks for parries by name. The
## proper version is general: abilities that can inspect an incoming hit and change or stop it (hit interceptors), switched on by
## state tags, so blocks, shields and armour don't each need the same special cases.
##
## How it works:
##   - The parry action starts it (F in the arenas). It runs for duration (0.35 s), then can't be used again for cooldown (1.5 s).
##   - While it runs it turns the pawn toward where it looks, at up to turn_degrees_per_second, like a swing's windup, and holds the
##     pawn still: it locks out movement and combat.
##   - Every hit is delivered through Pawn._take_hit, on the server. That asks AbilityManager.parry_hit(), which asks this. A hit
##     whose attacker is within front_degrees of where the pawn faces (centred on it, so 120 is 60 either side) is turned away: none
##     of its effects land.
##   - The attacker then gets a hit of its own, from this pawn, carrying this ability's ON_PARRY effects (EffectApplier children with
##     the ON_PARRY trigger). In the samples that's parry_knockback.tres, a knockback twice a swing's, with a hop. It goes through
##     the attacker's usual hit path (Pawn.receive_hit), so its AI notices, and the knockback cancels its swing like any knockback.
##     ON_PARRY effects with applies_to SELF go on this pawn.
##   - parried goes out for each hit turned away, for debug drawing and game rules.
##
## Odd cases:
##   - A parry's own hit can't be parried back, so two pawns parrying each other don't bounce hits forever.
##   - A hit with no attacker (a trap, a poison's tick) can't be parried: there's no "front" to come from.
##   - It can't cancel the pawn's own swing (interrupt_priority 10 against a swing's 15), and a knockback (30) or a dash (25) cancels
##     it (interrupt_threshold 20). So a hit from behind that knocks the pawn back ends the parry.
##   - Hits are decided on the server, so a client sees its own parry stance at once (it runs the ability), and the parried hit's
##     result arrives in snapshots.
class_name ParryAbility
extends AbilityBase

## Sent on the server (or offline) for each hit this parry turned away, after the attacker got the parry's effects.
signal parried(hit: HitInfo)

## How wide the front is, in degrees, centred on where the pawn faces. 120: an attacker up to 60 degrees to either side is parried.
@export_range(0.0, 360.0, 1.0) var front_degrees := 120.0
## How fast it turns toward where the pawn looks while it runs, in degrees per second. 0: it doesn't turn.
@export_range(0.0, 3600.0, 10.0, "or_greater") var turn_degrees_per_second := 900.0


func _init() -> void:
	super()
	kind = Kind.ACTION
	trigger_action = &"parry"
	category = Tags.COMBAT_PARRY
	duration = 0.35
	cooldown = 1.5
	locks_out = [Tags.MOVEMENT, Tags.COMBAT]
	interrupt_priority = 10
	interrupt_threshold = 20


func tick(dt: float) -> void:
	# yaw rolls back and look_yaw is input, so a replay turns the same way (as MeleeAttackAbility's windup).
	if turn_degrees_per_second > 0.0:
		pawn.yaw = rotate_toward(pawn.yaw, pawn.look_yaw, deg_to_rad(turn_degrees_per_second) * dt)


## True if this parry turns the hit away. It then sends the attacker the parry's effects. Called by AbilityManager.parry_hit().
func try_parry(hit: HitInfo) -> bool:
	if ticks_left <= 0 or hit == null or hit.ability is ParryAbility:
		return false
	var attacker := hit.attacker
	if attacker == null or not is_instance_valid(attacker) or attacker == pawn:
		return false
	if not faces(attacker.global_position):
		return false
	_push_back(hit, attacker)
	parried.emit(hit)
	return true


## True if a point is in front of the pawn, within front_degrees. A point right on top of the pawn counts as in front.
func faces(point: Vector3) -> bool:
	var to := point - pawn.global_position
	to.y = 0.0
	if to.length_squared() < 0.0001:
		return true
	var facing := Vector3(-sin(pawn.yaw), 0.0, -cos(pawn.yaw)) # the way the pawn faces: -Z turned by its yaw
	return facing.angle_to(to.normalized()) <= deg_to_rad(front_degrees * 0.5)


# The parry's own hit, on the attacker, pushing away from this pawn; and its SELF effects on this pawn.
func _push_back(parried_hit: HitInfo, attacker: Pawn) -> void:
	var back := HitInfo.new()
	back.attacker = pawn
	back.target = attacker
	back.ability = self
	back.tick = parried_hit.tick
	var away := attacker.global_position - pawn.global_position
	away.y = 0.0
	back.direction = away.normalized() if away.length_squared() > 0.0001 else Vector3(-sin(pawn.yaw), 0.0, -cos(pawn.yaw))
	back.effects = on_parry_effects
	if not on_parry_effects.is_empty():
		attacker.receive_hit(back)
	if not on_parry_self_effects.is_empty() and pawn.effect_manager:
		pawn.effect_manager.apply_effects(on_parry_self_effects, pawn, self, parried_hit)
