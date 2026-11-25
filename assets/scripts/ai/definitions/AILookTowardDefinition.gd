# Written by Claude (claude-opus-5-5), 2026-11-25. History: ai/CHANGELOG.md.
@tool
## The settings of a Look Toward behaviour ([AILookTowardBehaviour]), shared by every pawn whose Look Toward uses it.
##
## Its kind's own settings below; the ones every behaviour has come from [AIBehaviourDefinition]. A new one starts with the
## defaults Look Toward runs with when it has no definition.
class_name AILookTowardDefinition
extends AIBehaviourDefinition

## How long it looks, in ticks.
@export_range(1, 36000, 1, "or_greater") var look_ticks := 60:
	set(value):
		look_ticks = value
		_changed(&"look_ticks", value)
## How long after being hit by an unknown attacker it may still turn toward where the hit came from, in ticks.
@export_range(0, 36000, 1, "or_greater") var hit_memory_ticks := 300:
	set(value):
		hit_memory_ticks = value
		_changed(&"hit_memory_ticks", value)


func _init() -> void:
	super()
	tag_requirements = TagQuery.shared([Tags.AI.STATE_ALERT])
	max_score = 0.6
	min_score = max_score # a fixed score, so it can help skip others
	tick_interval_ticks = 5 # re-aiming 12 times a second is plenty, and each tick searches memory
	min_run_ticks = look_ticks # an ordinary decision doesn't cut its look short, whatever its score
	# Once it has looked, Investigate goes first: -0.3 takes it from 0.6 to 0.3, below Investigate's 0.5, for 15 s from when it starts
	# (written for 60 ticks a second).
	var step_aside := AIBehaviourModifier.new()
	step_aside.add = -0.3
	step_aside.duration_ticks = 900
	modifier_on_start = step_aside
