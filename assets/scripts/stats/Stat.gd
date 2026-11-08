## Written by Claude (claude-opus-5-5), 2026-11-07: one number about a pawn, such as how fast it walks. A child of the pawn's
## StatManager. Pawn spec section 9.
##
## The stat's name is this node's name, such as MoveSpeed or JumpVelocity. Abilities and behaviours ask the StatManager for a stat by
## that name, and use a fallback of their own if there's none, so a missing stat is never a crash.
##
## For now a stat is a plain value. Later: modifiers (buffs and debuffs).
##
## Claude 2026-11-09, step 10: a stat that changes during play, such as Health, has changes_during_play on. Then it also has a
## current value, from 0 up to its value, which starts full, rolls back (the StatManager lists it with the pawn's TickStateComponent)
## and reaches clients in snapshots. Only the server changes it: StatManager.change_current().
class_name Stat
extends Node

## The value it starts with. Setting it sets value too.
# GDScript note: "set(new_value):" under a variable runs every time it's assigned, including when the scene loads it.
@export var base_value := 0.0:
	set(new_value):
		base_value = new_value
		value = new_value

## The value right now. Starts as base_value.
var value := 0.0

## Claude 2026-11-09: on, this stat also has a current value that goes up and down during play, such as Health. value is then its
## most.
@export var changes_during_play := false
## Claude 2026-11-09: with changes_during_play, how much there is now, from 0 to value. Starts full. Rolls back.
var current := 0.0


func _init() -> void:
	set_process(false)
	set_physics_process(false)
