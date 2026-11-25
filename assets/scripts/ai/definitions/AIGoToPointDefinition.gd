# Written by Claude (claude-opus-5-5), 2026-11-25. History: ai/CHANGELOG.md.
@tool
## The settings of a Go To Point behaviour ([AIGoToPointBehaviour]), shared by every pawn whose Go To Point uses it.
##
## Its kind's own settings below; the ones every behaviour has come from [AIBehaviourDefinition]. A new one starts with the
## defaults Go To Point runs with when it has no definition.
class_name AIGoToPointDefinition
extends AIBehaviourDefinition

## The Godot group the point is in. The nearest node in it is the point.
@export var point_group: StringName = &"rally_point":
	set(value):
		point_group = value
		_changed(&"point_group", value)
## Close enough, in metres. Inside this the behaviour isn't available, so Wander takes over.
@export_range(0.5, 500.0, 0.5, "or_greater") var arrive_radius := 15.0:
	set(value):
		arrive_radius = value
		_changed(&"arrive_radius", value)
## The longest leg it walks at once, in metres.
@export_range(2.0, 200.0, 0.5, "or_greater") var leg_metres := 30.0:
	set(value):
		leg_metres = value
		_changed(&"leg_metres", value)
## How far to one side of the straight line this pawn walks, at most, in metres.
@export_range(0.0, 100.0, 0.5, "or_greater") var spread_metres := 6.0:
	set(value):
		spread_metres = value
		_changed(&"spread_metres", value)


func _init() -> void:
	super()
	tag_requirements = TagQuery.shared([Tags.AI.STATE_IDLE])
	max_score = 0.15
	min_score = 0.15
	tick_interval_ticks = 60 # the safety net: it wakes when a leg ends (wake_on_path_end)
