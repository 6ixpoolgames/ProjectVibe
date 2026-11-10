## Written by Claude (claude-opus-5-5), 2026-11-10: applies effects when its ability does something. A child node of an ability; the
## owner's design ("ability modifier nodes"): the ability itself carries no damage or knockback, its EffectApplier children say what
## it does to whom. Pawn spec 8.11.
##
## Two triggers:
##   ON_START  when the ability starts, to its own pawn. Every machine that runs the ability does it, rollback replays included, so
##             an over-time effect from it (a combo boost) is predicted. applies_to is ignored: there's no target yet.
##   ON_HIT    when the ability hits a pawn (MeleeAttackAbility), on the server: TARGET puts the effects on the pawn hit, SELF on the
##             attacker (gaining a combo boost only when a swing connects, say).
## An ability can have any number of these. The AbilityManager collects them when it starts up (AbilityBase.on_start_effects and
## the on-hit lists), so nothing searches for them while playing. Effects are usually saved .tres files, so one file tunes every
## ability that uses it.
class_name EffectApplier
extends Node

enum Trigger { ON_START, ON_HIT }
enum AppliesTo { TARGET, SELF }

@export var trigger := Trigger.ON_HIT
## With ON_HIT: who gets the effects.
@export var applies_to := AppliesTo.TARGET
## The effects, applied in this order.
@export var effects: Array[Effect] = []


func _init() -> void:
	set_process(false)
	set_physics_process(false)
