# Written by Claude (claude-opus-5-5), 2026-11-18. History: ai/CHANGELOG.md.
## Hangs back at shooting distance from a target it can see: a ranged pawn's way of moving in a fight, in place of Chase.
##
## Allowed in Combat while a ranged attack has shots left (the status.has_ammo.ranged tag). Available only to a pawn with a ranged attack
## (an ability in [member AIKeepDistanceDefinition.ranged_tag]'s group with a reach, [method AbilityBase.attack_reach]), only while the
## target is at least [member AIKeepDistanceDefinition.melee_distance] away, and only while it was seen within
## [member AIKeepDistanceDefinition.lost_after_ticks]; after that [AIGoToLastKnownBehaviour] walks to that distance from where it was
## last seen. Its steps: a KeepAwayFrom that keeps [member AIKeepDistanceDefinition.reach_fraction] of that attack's reach from the
## target, closing in or backing away, and stands facing it; a LookAt on the target; and the Sprint hold while it's beyond the attack's
## reach. Scored 85, above Chase (80), so a ranged pawn hangs back instead of running in; the Shoot behaviour (an [AIAttackBehaviour] on
## the ranged attack's action, scored higher) fires whenever the shot is ready. Once the target closes within melee_distance it isn't
## available, so Chase and the melee attacks take over; give Shoot the same distance as its [member AIAttackDefinition.min_distance]
## so the pawn melees rather than shooting at point blank. Design: pawn spec 8.24.
class_name AIKeepDistanceBehaviour
extends AIBehaviourBase

# Its settings, typed: [member AIBehaviourBase.settings] as its kind's definition.
var _kind_settings: AIKeepDistanceDefinition = null
var _ranged: AbilityBase = null
var _memory: AIMemory = null
var _keeping_from: Node3D = null # the target its KeepAwayFrom and LookAt steps were given


func make_default_definition() -> AIBehaviourDefinition:
	return AIKeepDistanceDefinition.new()


func _settings_changed() -> void:
	_kind_settings = settings as AIKeepDistanceDefinition


## Has a ranged attack, the target is at least [member AIKeepDistanceDefinition.melee_distance] away, and it was seen within
## [member AIKeepDistanceDefinition.lost_after_ticks]. With no ranged attack the first can never pass. If its abilities change during
## play, call [method AIBehaviourBase.rebuild_conditions].
func own_conditions() -> Array[AICondition]:
	var least := _kind_settings.melee_distance if find_ranged_attack() else AIInputs.FAR * 2.0
	var list: Array[AICondition] = [
		AICompareCondition.make(AIInputs.TARGET_DISTANCE, AICompareCondition.Comparison.AT_LEAST, least),
		AICompareCondition.make(AIInputs.TICKS_SINCE_TARGET_SEEN, AICompareCondition.Comparison.AT_MOST, _kind_settings.lost_after_ticks),
	]
	return list


## The metres from the target it stands at: [member AIKeepDistanceDefinition.reach_fraction] of its ranged attack's reach; 0 without one.
func preferred_distance() -> float:
	var ranged := find_ranged_attack()
	return ranged.attack_reach() * _kind_settings.reach_fraction if ranged else 0.0


## The pawn's ranged attack: the first ability in [member AIKeepDistanceDefinition.ranged_tag]'s group with a reach, found once. Null if it has none.
func find_ranged_attack() -> AbilityBase:
	if _ranged == null and pawn and pawn.ability_manager:
		for ability in pawn.ability_manager.get_abilities():
			if TagRegistry.matches(ability.category_mask, _kind_settings.ranged_tag) and ability.attack_reach() > 0.0:
				_ranged = ability
				break
	return _ranged


func make_steps() -> Array[Step]:
	return [made_step(KeepAwayFromStep, &"KeepAwayFrom"), made_step(LookAtStep, &"LookAt"), made_sprint_step()]


func enter(context: AIManager) -> void:
	_memory = context.memory
	_keeping_from = null


func tick(context: AIManager) -> Status:
	var index := context.current_target_index()
	if index < 0:
		return Status.FAILED # the target is gone
	var target := context.current_target
	var seen := is_instance_valid(target) and _memory.ticks_since_seen_at(index, context.current_tick) <= TickDriver.ticks_at_rate(_kind_settings.lost_after_ticks)
	if not seen:
		return Status.FAILED # lost: a decision at once, and Go To Last Known takes over
	var preferred := preferred_distance()
	if _keeping_from != target:
		_keeping_from = target
		start_step(&"KeepAwayFrom", {"target": target, "stop_distance": preferred, "band": _kind_settings.band,
			"repath_ticks": _kind_settings.repath_ticks, "repath_distance": _kind_settings.repath_distance})
		start_step(&"LookAt", {"target": target, "offset": Vector3(0.0, 1.0, 0.0)})
	var away := pawn.global_position - target.global_position
	away.y = 0.0
	# Sprints to close in while beyond the attack's reach; standing by, never.
	var keeping := get_step(&"KeepAwayFrom") as KeepAwayFromStep
	var standing := keeping != null and keeping.running and keeping.is_standing()
	var sprint := _kind_settings.sprint_to_close and not standing and away.length() > preferred / maxf(_kind_settings.reach_fraction, 0.01)
	if sprint != is_step_running(SPRINT_STEP):
		if sprint:
			start_step(SPRINT_STEP)
		else:
			stop_step(SPRINT_STEP)
	return Status.RUNNING
