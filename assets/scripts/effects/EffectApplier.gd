# Written by Claude (claude-opus-5-5), 2026-11-10. History: effects/CHANGELOG.md.
## Applies effects when its ability does something: a child node of an ability, or of a [HitInterceptor].
##
## The ability itself carries no damage or knockback; its EffectApplier children say what it does to whom. An ability can have any
## number; the AbilityManager collects them at startup, so nothing searches for them while playing. See [enum Trigger] for when each runs.
## Design: pawn spec 8.11, 8.23.
class_name EffectApplier
extends Node

# ON_INTERCEPT keeps the number 2, which scenes saved with the old parry trigger hold. Add new triggers at the end.
## When the effects apply. ON_START: when the ability starts, to its own pawn, on every machine that runs it (rollback replays included).
## [br]ON_HIT: when the ability hits a pawn (its sweep or its projectile), on the server. ON_INTERCEPT: under a [HitInterceptor] that stops a hit, on the server.
enum Trigger { ON_START, ON_HIT, ON_INTERCEPT }
## Who gets the effects. TARGET: the pawn hit (with ON_INTERCEPT, the attacker, in a hit of their own). SELF: the applying pawn.
enum AppliesTo { TARGET, SELF }

## When it applies its effects.
@export var trigger := Trigger.ON_HIT
## With ON_HIT or ON_INTERCEPT: who gets the effects. Ignored with ON_START (there is no target yet).
@export var applies_to := AppliesTo.TARGET
## The effects, applied in this order.
@export var effects: Array[Effect] = []


func _init() -> void:
	set_process(false)
	set_physics_process(false)
