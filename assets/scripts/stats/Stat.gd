## Written by Claude (claude-opus-5-5), 2026-11-07: one number about a pawn, such as how fast it walks. A child of the pawn's
## StatManager. Pawn spec section 9.
##
## The stat's name is this node's name, such as MoveSpeed or JumpVelocity. Abilities and behaviours ask the StatManager for a stat by
## that name, and use a fallback of their own if there's none, so a missing stat is never a crash.
##
## For now a stat is a plain value. Later: modifiers (buffs and debuffs), and stats that change during play, such as Health, will
## need to roll back.
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


func _init() -> void:
	set_process(false)
	set_physics_process(false)
