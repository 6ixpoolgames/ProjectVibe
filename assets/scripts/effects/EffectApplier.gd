# Written by Claude (claude-opus-5-5), 2026-11-10. History: effects/CHANGELOG.md.
## What a [HitInterceptor] does when it stops a hit: a child node of the interceptor, on the ON_INTERCEPT trigger.
##
## Effects an ability applies on start or on a hit live in its definition ([member AbilityDefinition.start_effects], its hit's
## [member HitDefinition.target_effects] and [member HitDefinition.attacker_effects]); one left directly under an ability does nothing.
## Design: pawn spec 8.23, 16.7.
# REFACTOR: goes with the interceptors, when parrying becomes an effect whose reply is part of the effect (pawn spec 16.10, step 4).
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
