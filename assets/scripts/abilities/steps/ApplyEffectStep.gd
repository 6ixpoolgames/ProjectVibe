# Written by Claude (claude-opus-5-5), 2026-11-16. History: abilities/CHANGELOG.md.
## Applies effects to its own pawn when it starts, then is done on its next tick.
##
## For effects that belong to a moment in an ability, such as after its hit, rather than to its start. Like on-start effects they're
## applied on every machine that runs the ability (replays too), and their do-once parts only run on the authority.
## Design: pawn spec 8.20.
class_name ApplyEffectStep
extends AbilityStep

## The effects it applies to its own pawn.
@export var effects: Array[Effect] = []


func setup() -> void:
	# Registering gives each effect an id every machine agrees on, so one in the pawn's active list is recognised.
	for effect in effects:
		if effect:
			effect.register()


func enter() -> void:
	if pawn.effect_manager and not effects.is_empty():
		pawn.effect_manager.apply_effects(effects, pawn, ability)


func tick(_dt: float) -> Status:
	return Status.DONE
