# Written by Claude (claude-opus-5-5), 2026-11-25. History: ai/CHANGELOG.md.
@tool
## The settings of a Chase behaviour ([AIChaseBehaviour]), shared by every pawn whose Chase uses it.
##
## Its kind's own settings below; the ones every behaviour has come from [AIBehaviourDefinition]. A new one starts with the
## defaults Chase runs with when it has no definition.
class_name AIChaseDefinition
extends AIBehaviourDefinition

## Ticks between new paths.
@export_range(1, 600, 1, "or_greater") var repath_ticks := 20:
	set(value):
		repath_ticks = value
		_changed(&"repath_ticks", value)
## How far, in metres, the target must move from where the path leads before a new path is found early.
@export_range(0.1, 50.0, 0.1, "or_greater") var repath_distance := 1.5:
	set(value):
		repath_distance = value
		_changed(&"repath_distance", value)
## Ticks since the target was last seen after which it's chased to where it was last seen, not where it is (at 60 a second).
@export_range(0, 600, 1, "or_greater") var lost_after_ticks := 30:
	set(value):
		lost_after_ticks = value
		_changed(&"lost_after_ticks", value)
## How close, in metres, it gets before stopping.
@export_range(0.0, 20.0, 0.1, "or_greater") var stop_distance := 1.2: # just inside MeleeAttack attack_range (1.8) minus Attack approach_margin (0.3)
	set(value):
		stop_distance = value
		_changed(&"stop_distance", value)
## On: it holds sprint while chasing. Sprint's own cooldown decides when it actually sprints.
@export var sprint := true:
	set(value):
		sprint = value
		_changed(&"sprint", value)
## On: it presses dash to close in, when the target is between [member dash_to_distance] and [member dash_from_distance] away and the
## ability can start (in the air too, Dash's usable_in_air). Off by default. A dash goes the way the pawn is moving, along its path.
@export var dash_to_close := false:
	set(value):
		dash_to_close = value
		_changed(&"dash_to_close", value)
## The group of ability it uses to close in, not one ability by name: any ability tagged with it that can start
## ([method AbilityManager.action_for_tag]). Advanced movement by default.
@export var close_in_tag: StringName = Tags.ABILITY.MOVEMENT_ADVANCED:
	set(value):
		close_in_tag = value
		_changed(&"close_in_tag", value)
## The farthest the target can be for a dash, in metres.
@export_range(0.0, 50.0, 0.1, "or_greater") var dash_from_distance := 7.5:
	set(value):
		dash_from_distance = value
		_changed(&"dash_from_distance", value)
## The nearest the target can be for a dash, in metres. A dash from a sprint (9 m/s) covers about 4.2 m, so 5.5 lands it a little
## outside stop_distance.
@export_range(0.0, 50.0, 0.1, "or_greater") var dash_to_distance := 5.5:
	set(value):
		dash_to_distance = value
		_changed(&"dash_to_distance", value)


func _init() -> void:
	super()
	tag_requirements = TagQuery.shared([Tags.AI.STATE_COMBAT])
	tags = [Tags.AI.STANCE_MELEE]
	needs_target = true
	base_score = 80.0
	tick_interval_ticks = 5 # the AI controller follows the path every tick; Chase only re-aims
