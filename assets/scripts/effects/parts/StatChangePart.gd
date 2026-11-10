## Written by Claude (claude-opus-5-5), 2026-11-10: changes how much of a stat a pawn has, once: Health -20 is damage, Health +15 a heal.
## A do-once part (EffectPart). Pawn spec 8.11.
##
## For a stat that changes during play (Stat.changes_during_play, such as Health), kept between 0 and the stat's value. A stat the
## pawn doesn't have: nothing happens.
## On a harmful effect, a negative amount is reduced by the pawn's resistance (EffectApplication.resistance): 25% resistance takes a
## quarter off, and a weakness (below 0) adds to it. A positive amount (a heal) is never changed.
## With stacks, the amount is multiplied by them: a poison with 3 stacks takes three times as much each period.
## Health taken is added to the application's damage_dealt, for LifestealPart and the AI's threat.
class_name StatChangePart
extends EffectPart

## The stat, by name, such as &"Health".
@export var stat: StringName = &"Health"
## How much to add. Negative takes away.
@export var amount := -10.0


func apply_once(application: EffectApplication) -> void:
	var stats := application.target.stat_manager
	if stats == null or not stats.has_stat(stat):
		return
	var change := amount * application.stacks
	if change < 0.0 and application.effect.is_harmful:
		change *= 1.0 - application.resistance
	var before := stats.get_current(stat)
	var after := stats.change_current(stat, change)
	if stat == &"Health" and after < before:
		application.damage_dealt += before - after
