# Written by Claude (claude-opus-5-5), 2026-11-15. History: abilities/CHANGELOG.md.
## A parry stance: while it runs, a hit from the front does nothing to this pawn, and the attacker is pushed back instead.
##
## The owner's request (pawn spec 8.15, 8.23). Hits from the sides and back land as usual. Turning hits away is its ParryInterceptor
## child's job (a HitInterceptor, with the front's width), and what the attacker gets is that interceptor's ON_INTERCEPT EffectApplier
## children. With no interceptor of its own, it makes a ParryInterceptor with the default front. This ability is the stance: it runs
## for duration, turns the pawn toward where it looks, and holds it still.
## [br]
## How it works:
## [br]- The parry action starts it (F in the arenas). It runs for duration (0.35 s), then can't be used again for cooldown (1.5 s).
## [br]- While it runs it turns the pawn toward where it looks, at up to [member turn_degrees_per_second], like a swing's windup, and
##   holds the pawn still: it locks out movement and combat.
## [br]- Its ParryInterceptor turns away hits from the front, and the attacker gets a hit of its own carrying the push-back (in the
##   samples, parry_knockback.tres). AbilityManager.hit_intercepted goes out for each.
## [br]
## Odd cases:
## [br]- It can't cancel the pawn's own swing (interrupt_priority 10 against a swing's 15), and a knockback (30) or a dash (40)
##   cancels it (interrupt_threshold 20). So a hit from behind that knocks the pawn back ends the parry.
## [br]- Hits are decided on the server, so a client sees its own parry stance at once (it runs the ability), and the parried hit's
##   result arrives in snapshots. The interceptor's own odd cases are in ParryInterceptor.gd.
class_name ParryAbility
extends AbilityBase

# A parried hit is AbilityManager.hit_intercepted; the front's width is the ParryInterceptor's front_degrees.
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
	# yaw rolls back and look_yaw is input, so a replay turns the same way (as a swing's TurnToFaceStep).
	if turn_degrees_per_second > 0.0:
		pawn.yaw = rotate_toward(pawn.yaw, look_yaw(), deg_to_rad(turn_degrees_per_second) * dt)


## Its ParryInterceptor, or null: the debug drawing reads the front's width from it.
func guard() -> ParryInterceptor:
	for interceptor in interceptors:
		if interceptor is ParryInterceptor:
			return interceptor
	return null


## With no interceptor of its own, a ParryInterceptor with the default front (120 degrees).
func make_default_interceptors() -> void:
	var front := ParryInterceptor.new()
	front.name = "Front"
	add_child(front)
