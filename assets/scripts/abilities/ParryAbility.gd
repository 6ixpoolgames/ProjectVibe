# Written by Claude (claude-opus-5-5), 2026-11-15. History: abilities/CHANGELOG.md.
## A parry stance: while it runs, a hit from the front does nothing to this pawn, and the attacker is pushed back instead.
##
## This ability is the stance: it runs for duration (0.35 s, then a 1.5 s cooldown), turns the pawn toward where it looks and holds it
## still. Turning hits away is its [ParryInterceptor] child's job (made by default with the 120 degree front), and what the attacker
## gets is that interceptor's ON_INTERCEPT EffectApplier children. Hits from the sides and back land as usual, and a knockback or a dash
## cancels the stance. A client sees its own stance at once; the parried hit's result arrives in snapshots.
## Design: pawn spec 8.15, 8.23.
class_name ParryAbility
extends AbilityBase

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
	# yaw rolls back and look_yaw is input, so a replay turns the same way.
	if turn_degrees_per_second > 0.0:
		pawn.yaw = rotate_toward(pawn.yaw, look_yaw(), deg_to_rad(turn_degrees_per_second) * dt)


## Its [ParryInterceptor], or null. The debug drawing reads the front's width from it.
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
