# Written by Claude (claude-opus-5-5), 2026-11-25. History: ai/CHANGELOG.md.
@tool
## The settings of a Wander behaviour ([AIWanderBehaviour]), shared by every pawn whose Wander uses it.
##
## Its kind's own settings below; the ones every behaviour has come from [AIBehaviourDefinition]. A new one starts with the
## defaults Wander runs with when it has no definition.
class_name AIWanderDefinition
extends AIBehaviourDefinition

## How far from home it wanders, in metres.
@export_range(0.5, 200.0, 0.5, "or_greater") var wander_radius := 8.0:
	set(value):
		wander_radius = value
		_changed(&"wander_radius", value)
## The shortest stand between walks, in ticks.
@export_range(0, 36000, 1, "or_greater") var min_pause_ticks := 30:
	set(value):
		min_pause_ticks = value
		_changed(&"min_pause_ticks", value)
## The longest stand between walks, in ticks.
@export_range(0, 36000, 1, "or_greater") var max_pause_ticks := 120:
	set(value):
		max_pause_ticks = value
		_changed(&"max_pause_ticks", value)


func _init() -> void:
	super()
	tag_requirements = TagQuery.shared([Tags.AI.STATE_IDLE])
	# A low, fixed score: Wander is what a pawn does when nothing more interesting can run.
	base_score = 10.0
	tick_interval_ticks = 60 # the safety net: it wakes when a walk ends (wake_on_step_end) and when a pause ends (wake_at)
