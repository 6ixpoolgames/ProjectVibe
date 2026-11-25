# Written by Claude (claude-opus-5-5), 2026-11-25. History: ai/CHANGELOG.md.
@tool
## The settings of a Parry behaviour ([AIParryBehaviour]), shared by every pawn whose Parry uses it.
##
## Its kind's own settings below; the ones every behaviour has come from [AIBehaviourDefinition]. A new one starts with the
## defaults Parry runs with when it has no definition.
class_name AIParryDefinition
extends AIBehaviourDefinition

## How often it parries a swing coming at it, from 0 (never) to 1 (every one it can).
@export_range(0.0, 1.0, 0.01) var parry_chance := 0.3:
	set(value):
		parry_chance = value
		_changed(&"parry_chance", value)


func _init() -> void:
	super()
	# Above the samples' attacks (the heavy attack is 0.95), because a parry has to happen now or never. Shoot scores the same, 0.97, so
	# a pawn with both breaks the tie by name order.
	max_score = 0.97
	min_score = 0.97
	presses_action = &"parry"
	tick_interval_ticks = 60 # the safety net: it wakes two ticks after the press (wake_at)
