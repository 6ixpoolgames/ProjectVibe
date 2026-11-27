# Written by Claude (claude-opus-5-5), 2026-11-25. History: ai/CHANGELOG.md.
@tool
## The settings of a Investigate behaviour ([AIInvestigateBehaviour]), shared by every pawn whose Investigate uses it.
##
## Its kind's own settings below; the ones every behaviour has come from [AIBehaviourDefinition]. A new one starts with the
## defaults Investigate runs with when it has no definition.
class_name AIInvestigateDefinition
extends AIBehaviourDefinition

## How far, in metres, the last known position must move before it heads for the new one.
@export_range(0.1, 50.0, 0.1, "or_greater") var repath_distance := 2.0:
	set(value):
		repath_distance = value
		_changed(&"repath_distance", value)
## How close, in metres, counts as arrived.
@export_range(0.1, 10.0, 0.1, "or_greater") var arrive_distance := 1.0:
	set(value):
		arrive_distance = value
		_changed(&"arrive_distance", value)
## How long after being hit by an unknown attacker it may still go to where the hit came from, in ticks.
@export_range(0, 36000, 1, "or_greater") var hit_memory_ticks := 300:
	set(value):
		hit_memory_ticks = value
		_changed(&"hit_memory_ticks", value)


func _init() -> void:
	super()
	tag_requirements = TagQuery.shared([Tags.AI.STATE_ALERT])
	base_score = 50.0
	cooldown_ticks = 120 # after it finishes, Look Toward gets its turn again, even while Look Toward's own step aside holds it back
	tick_interval_ticks = 5 # it only needs to notice arriving, or the position moving
