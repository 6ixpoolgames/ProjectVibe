# Written by Claude (claude-opus-5-5), 2026-11-10. History: effects/CHANGELOG.md.
## Applies effects when its ability does something: a child node of an ability, or of a HitInterceptor.
##
## The owner's design ("ability modifier nodes"): the ability itself carries no damage or knockback; its EffectApplier children say
## what it does to whom. Pawn spec 8.11.
## [br]
## Three triggers:
## [br]- [b]ON_START[/b]: when the ability starts, to its own pawn. Every machine that runs the ability does it, rollback replays
##   included, so an over-time effect from it (a combo boost) is predicted. [member applies_to] is ignored: there's no target yet.
## [br]- [b]ON_HIT[/b]: when the ability hits a pawn (its MeleeSweepStep), on the server. TARGET puts the effects on the pawn hit,
##   SELF on the attacker (gaining a combo boost only when a swing connects, say).
## [br]- [b]ON_INTERCEPT[/b]: under a [HitInterceptor], when it stops a hit, on the server (pawn spec 8.23). TARGET puts the effects on
##   the attacker, in a hit of their own (the parry's push-back), SELF on the pawn that stopped it (a reward for parrying, say).
## [br]
## An ability can have any number of these. The AbilityManager collects them when it starts up ([member AbilityBase.on_start_effects],
## the on-hit lists, and each interceptor's own), so nothing searches for them while playing. Effects are usually saved .tres files,
## so one file tunes every ability that uses it.
class_name EffectApplier
extends Node

# ON_INTERCEPT keeps the number 2, which scenes saved with the old parry trigger hold, so they keep working. Add new triggers at the end.
enum Trigger { ON_START, ON_HIT, ON_INTERCEPT }
enum AppliesTo { TARGET, SELF }

@export var trigger := Trigger.ON_HIT
## With ON_HIT or ON_INTERCEPT: who gets the effects.
@export var applies_to := AppliesTo.TARGET
## The effects, applied in this order.
@export var effects: Array[Effect] = []


func _init() -> void:
	set_process(false)
	set_physics_process(false)
