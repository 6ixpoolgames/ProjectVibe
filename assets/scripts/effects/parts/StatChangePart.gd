# Written by Claude (claude-opus-5-5), 2026-11-10. History: effects/CHANGELOG.md.
## Changes how much of a stat a pawn has, once: Health -20 is damage, Health +15 a heal. A do-once part ([EffectPart]).
##
## Kept between 0 and the stat's value; a stat the pawn doesn't have is ignored. The amount is multiplied by the stacks, and a harmful
## negative amount is reduced by the pawn's resistance. Health taken is added to the application's damage_dealt.
## Design: pawn spec 8.11.
class_name StatChangePart
extends EffectPart

## The stat, by name, such as &"Health".
@export var stat: StringName = StatusManager.HEALTH
## How much to add. Negative takes away.
@export var amount := -10.0


func apply_once(application: EffectApplication) -> void:
	var stats := application.target.status_manager
	if stats == null or not stats.has_stat(stat):
		return
	var change := amount * application.stacks
	if change < 0.0 and application.effect.is_harmful:
		change *= 1.0 - application.resistance
	var before := stats.get_current(stat)
	var after := stats.change_current(stat, change, application.source, application.hit)
	if stat == StatusManager.HEALTH and after < before:
		application.damage_dealt += before - after
