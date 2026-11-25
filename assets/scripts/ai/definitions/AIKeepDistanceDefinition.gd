# Written by Claude (claude-opus-5-5), 2026-11-25. History: ai/CHANGELOG.md.
@tool
## The settings of a Keep Distance behaviour ([AIKeepDistanceBehaviour]), shared by every pawn whose Keep Distance uses it.
##
## Its kind's own settings below; the ones every behaviour has come from [AIBehaviourDefinition]. A new one starts with the
## defaults Keep Distance runs with when it has no definition.
class_name AIKeepDistanceDefinition
extends AIBehaviourDefinition

## The group of ability it keeps distance for: any ability tagged with it that has a reach. Ranged combat by default.
@export var ranged_tag: StringName = Tags.ABILITY.COMBAT_RANGED:
	set(value):
		ranged_tag = value
		_changed(&"ranged_tag", value)
## Where it stands, as a fraction of the ranged attack's reach from the target: 0.7 of a 14 m bolt is 9.8 m.
@export_range(0.1, 1.0, 0.05) var reach_fraction := 0.7:
	set(value):
		reach_fraction = value
		_changed(&"reach_fraction", value)
## How far, in metres, from that distance it may drift before it walks again. It walks until within half of this.
@export_range(0.1, 20.0, 0.1, "or_greater") var band := 1.5:
	set(value):
		band = value
		_changed(&"band", value)
## Closer than this, in metres, it gives up keeping distance and the melee behaviours take over.
@export_range(0.0, 50.0, 0.1, "or_greater") var melee_distance := 4.0:
	set(value):
		melee_distance = value
		_changed(&"melee_distance", value)
## On: it sprints while the target is beyond the ranged attack's reach. Sprint's own cooldown decides when it actually sprints.
@export var sprint_to_close := true:
	set(value):
		sprint_to_close = value
		_changed(&"sprint_to_close", value)
## Ticks since the target was last seen after which it keeps its distance from where it was last seen (at 60 a second).
@export_range(0, 600, 1, "or_greater") var lost_after_ticks := 30:
	set(value):
		lost_after_ticks = value
		_changed(&"lost_after_ticks", value)
## Ticks between new paths while it walks.
@export_range(1, 600, 1, "or_greater") var repath_ticks := 20:
	set(value):
		repath_ticks = value
		_changed(&"repath_ticks", value)
## How far, in metres, the spot it walks to must move before a new path is found early.
@export_range(0.1, 50.0, 0.1, "or_greater") var repath_distance := 1.5:
	set(value):
		repath_distance = value
		_changed(&"repath_distance", value)


func _init() -> void:
	super()
	# Only in Combat, and only while a ranged attack has shots left (its has_charges_tag): out of shots, Chase takes over.
	tag_requirements = TagQuery.shared([Tags.AI.STATE_COMBAT, Tags.STATUS.HAS_AMMO_RANGED])
	tags = [Tags.AI.STANCE_RANGED]
	needs_target = true
	max_score = 0.85
	min_score = 0.85
	tick_interval_ticks = 5 # the AI controller follows the path every tick; this only re-aims
