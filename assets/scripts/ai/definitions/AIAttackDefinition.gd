# Written by Claude (claude-opus-5-5), 2026-11-25. History: ai/CHANGELOG.md.
@tool
## The settings of a Attack behaviour ([AIAttackBehaviour]), shared by every pawn whose Attack uses it.
##
## Its kind's own settings below; the ones every behaviour has come from [AIBehaviourDefinition]. A new one starts with the
## defaults Attack runs with when it has no definition.
class_name AIAttackDefinition
extends AIBehaviourDefinition

## How much closer than the attack's range the AI steps before attacking, in metres.
@export_range(0.0, 5.0, 0.05, "or_greater") var approach_margin := 0.3:
	set(value):
		approach_margin = value
		_changed(&"approach_margin", value)
## The nearest the target may be for this attack, in metres; 0: no limit. For a ranged attack, set it to the Keep Distance behaviour's
## melee_distance, so a target that close is met with melee instead.
@export_range(0.0, 50.0, 0.1, "or_greater") var min_distance := 0.0:
	set(value):
		min_distance = value
		_changed(&"min_distance", value)


func _init() -> void:
	super()
	tag_requirements = TagQuery.shared([Tags.AI.STATE_COMBAT])
	needs_target = true
	presses_action = &"primary"
	max_score = 0.9
	min_score = 0.9
	interrupt_threshold = 15
	tick_interval_ticks = 60 # the safety net: it wakes for the press and when the swing ends
