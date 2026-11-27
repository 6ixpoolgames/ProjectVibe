# Written by Claude (claude-opus-5-5), 2026-11-27. History: ai/CHANGELOG.md.
@tool
## The settings of a Go To Last Known behaviour ([AIGoToLastKnownBehaviour]), shared by every pawn whose Go To Last Known uses it.
##
## Its kind's own settings below; the ones every behaviour has come from [AIBehaviourDefinition]. A new one starts with the
## defaults Go To Last Known runs with when it has no definition.
class_name AIGoToLastKnownDefinition
extends AIBehaviourDefinition

## Ticks since the target was last seen after which it walks to where it was last seen (at 60 a second). Match Chase's and Keep
## Distance's lost_after_ticks, so one takes over as the other stops.
@export_range(0, 600, 1, "or_greater") var lost_after_ticks := 30:
	set(value):
		lost_after_ticks = value
		_changed(&"lost_after_ticks", value)
## How far, in metres, the last known position must move (memory heard of it again) before it walks to the new one.
@export_range(0.1, 50.0, 0.1, "or_greater") var repath_distance := 1.5:
	set(value):
		repath_distance = value
		_changed(&"repath_distance", value)
## On: it holds its Sprint step while it walks.
@export var sprint := true:
	set(value):
		sprint = value
		_changed(&"sprint", value)
## Stops this many metres short of the spot, on the line from the pawn.
@export_range(0.0, 50.0, 0.1, "or_greater") var stop_short_metres := 0.0:
	set(value):
		stop_short_metres = value
		_changed(&"stop_short_metres", value)
## With a ranged attack (an ability in [member ranged_tag]'s group with a reach) it also stops this fraction of that reach short, as
## Keep Distance hangs back. 0: not for a ranged attack.
@export_range(0.0, 1.0, 0.05) var ranged_reach_fraction := 0.7:
	set(value):
		ranged_reach_fraction = value
		_changed(&"ranged_reach_fraction", value)
## The group of ability [member ranged_reach_fraction] looks for. Ranged combat by default.
@export var ranged_tag: StringName = Tags.ABILITY.COMBAT_RANGED:
	set(value):
		ranged_tag = value
		_changed(&"ranged_tag", value)


func _init() -> void:
	super()
	tag_requirements = TagQuery.shared([Tags.AI.STATE_COMBAT])
	needs_target = true
	base_score = 80.0
	tick_interval_ticks = 5 # its MoveTo step follows the path every tick; this only checks where the spot is
