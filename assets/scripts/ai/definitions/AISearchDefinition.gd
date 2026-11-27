# Written by Claude (claude-opus-5-5), 2026-11-25. History: ai/CHANGELOG.md.
@tool
## The settings of a Search behaviour ([AISearchBehaviour]), shared by every pawn whose Search uses it.
##
## Its kind's own settings below; the ones every behaviour has come from [AIBehaviourDefinition]. A new one starts with the
## defaults Search runs with when it has no definition.
class_name AISearchDefinition
extends AIBehaviourDefinition

## How many points it looks at around the last known position, each round.
@export_range(0, 50, 1, "or_greater") var search_points := 3:
	set(value):
		search_points = value
		_changed(&"search_points", value)
## How far from the last known position those points are, in metres.
@export_range(0.5, 100.0, 0.5, "or_greater") var search_radius := 5.0:
	set(value):
		search_radius = value
		_changed(&"search_radius", value)
## How long it stands at each, in ticks.
@export_range(1, 36000, 1, "or_greater") var pause_ticks := 30:
	set(value):
		pause_ticks = value
		_changed(&"pause_ticks", value)
## On: it holds sprint on the way to the last known position.
@export var sprint_to_last_known := true:
	set(value):
		sprint_to_last_known = value
		_changed(&"sprint_to_last_known", value)


func _init() -> void:
	super()
	tag_requirements = TagQuery.shared([Tags.AI.STATE_ALERT])
	base_score = 70.0
	tick_interval_ticks = 60 # the safety net: it wakes when a walk ends (wake_on_path_end) and when a pause ends (wake_at)
