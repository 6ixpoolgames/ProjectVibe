# Written by Claude (claude-opus-5-5), 2026-11-27. History: ai/CHANGELOG.md.
## Walks to where the target was last seen, once it's out of sight: what Chase and Keep Distance did when they lost it.
##
## Allowed in Combat, while there's a target that hasn't been seen for [member AIGoToLastKnownDefinition.lost_after_ticks]. Its steps: a
## MoveTo to the last known position (stopping [member AIGoToLastKnownDefinition.stop_short_metres] short, and a share of a ranged
## attack's reach short, so a ranged pawn hangs back), a LookAt on that spot, and the Sprint hold. It walks again if the spot moves
## more than [member AIGoToLastKnownDefinition.repath_distance] (memory heard of it again), and once there it stands, looking. It
## succeeds as soon as the target is seen again, so Chase or Keep Distance take over at once; once the target is out of sight long
## enough, Combat's prerequisites fail and the state change replaces it. Design: pawn spec 10.7.
class_name AIGoToLastKnownBehaviour
extends AIBehaviourBase

# Its settings, typed: [member AIBehaviourBase.settings] as its kind's definition.
var _kind_settings: AIGoToLastKnownDefinition = null
var _goal := Vector3.INF # where its MoveTo step was sent
var _ranged: AbilityBase = null
var _looked_for_ranged := false


func make_default_definition() -> AIBehaviourDefinition:
	return AIGoToLastKnownDefinition.new()


func _settings_changed() -> void:
	_kind_settings = settings as AIGoToLastKnownDefinition
	_looked_for_ranged = false


## Only for a target it has lost sight of: one it knows of (a distance), not seen for lost_after_ticks.
func own_conditions() -> Array[AICondition]:
	var list: Array[AICondition] = [
		AICompareCondition.make(AIInputs.TARGET_DISTANCE, AICompareCondition.Comparison.LESS_THAN, AIInputs.FAR),
		AICompareCondition.make(AIInputs.TICKS_SINCE_TARGET_SEEN, AICompareCondition.Comparison.MORE_THAN, _kind_settings.lost_after_ticks),
	]
	return list


func make_steps() -> Array[Step]:
	return [made_step(MoveToStep, &"MoveTo"), made_step(LookAtStep, &"LookAt"), made_sprint_step()]


## How far short of the spot it stops: [member AIGoToLastKnownDefinition.stop_short_metres], plus the ranged share of its reach.
func stop_short() -> float:
	if not _looked_for_ranged:
		_looked_for_ranged = true
		_ranged = null
		if pawn and pawn.ability_manager and _kind_settings.ranged_reach_fraction > 0.0:
			for ability in pawn.ability_manager.get_abilities():
				if TagRegistry.matches(ability.category_mask, _kind_settings.ranged_tag) and ability.attack_reach() > 0.0:
					_ranged = ability
					break
	var short := _kind_settings.stop_short_metres
	if _ranged:
		short += _ranged.attack_reach() * _kind_settings.ranged_reach_fraction
	return short


func enter(_context: AIManager) -> void:
	_goal = Vector3.INF
	if _kind_settings.sprint:
		start_step(SPRINT_STEP)


func tick(context: AIManager) -> Status:
	var index := context.current_target_index()
	if index < 0:
		return Status.FAILED # the target is gone
	if context.memory.ticks_since_seen_at(index, context.current_tick) <= TickDriver.ticks_at_rate(_kind_settings.lost_after_ticks):
		return Status.SUCCEEDED # seen again: Chase or Keep Distance, at once
	var there := context.memory.last_known_position_at(index)
	var away := pawn.global_position - there
	away.y = 0.0
	var distance := away.length()
	var direction := away / distance if distance > 0.01 else pawn.global_basis.z
	var goal := there + direction * minf(stop_short(), distance)
	if goal.distance_to(_goal) > _kind_settings.repath_distance:
		# One walk to where it was last seen, given again only if that spot moves.
		_goal = goal
		start_step(&"MoveTo", {"goal": goal})
		start_step(&"LookAt", {"target": null, "point": there + Vector3(0.0, 1.0, 0.0)})
	return Status.RUNNING
