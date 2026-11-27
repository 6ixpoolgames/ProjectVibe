# Written by Claude (claude-opus-5-5), 2026-11-09. History: ai/CHANGELOG.md.
## Hunts around where an enemy it became certain of was last seen: "I know you were here".
##
## Allowed in Alert. Available only when the most aware memory entry is certain but not fresh enough for Combat (Look Toward and
## Investigate handle half-noticed things). It goes to the last known position (holding sprint if [member AISearchDefinition.sprint_to_last_known] is on),
## then walks to [member AISearchDefinition.search_points] random points within [member AISearchDefinition.search_radius] of it, standing [member AISearchDefinition.pause_ticks] at each, and
## succeeds. While still Alert it's usually picked again, so it keeps searching until the entry fades (Idle) or the enemy is seen (Combat).
## Design: pawn spec 10.7.
class_name AISearchBehaviour
extends AIBehaviourBase

# Its settings, typed: [member AIBehaviourBase.settings] as its kind's definition.
var _kind_settings: AISearchDefinition = null
const POINT_ANGLE_SALT := 0x5EA1
const POINT_DISTANCE_SALT := 0x5EA2

var _centre := Vector3.ZERO
var _going_to_centre := false
var _points_left := 0
var _pause_until := -1 # the tick its current pause ends; -1: not pausing


func make_default_definition() -> AIBehaviourDefinition:
	return AISearchDefinition.new()


func _settings_changed() -> void:
	_kind_settings = settings as AISearchDefinition


## Only for an enemy it became certain of: the most aware entry in memory exists and is certain. Its score is its base_score.
func own_conditions() -> Array[AICondition]:
	var list: Array[AICondition] = [AICompareCondition.make(AIInputs.MOST_AWARE_CERTAIN, AICompareCondition.Comparison.EQUAL, 1.0)]
	return list


func enter(context: AIManager) -> void:
	var index := context.most_aware_index()
	_centre = context.memory.last_known_position_at(index) if index >= 0 else pawn.global_position
	_going_to_centre = true
	_points_left = _kind_settings.search_points
	_pause_until = -1
	context.controller.hold(&"sprint", _kind_settings.sprint_to_last_known)
	wake_on_path_end()
	if not context.controller.move_to(_centre):
		wake_at(context.current_tick + 1) # no walk to wake it: on to the next step


func tick(context: AIManager) -> Status:
	var hands := context.controller
	# Pauses end at a tick, not after a count of tick() calls, so they last the same at any tick_interval_ticks.
	if _pause_until >= 0:
		if context.current_tick < _pause_until:
			wake_at(_pause_until)
			return Status.RUNNING
		_pause_until = -1
		if _points_left <= 0:
			return Status.SUCCEEDED
		_points_left -= 1
		# sqrt spreads the points evenly over the circle rather than bunching them in the middle.
		var angle := context.random_unit(POINT_ANGLE_SALT) * TAU
		var distance := sqrt(context.random_unit(POINT_DISTANCE_SALT)) * _kind_settings.search_radius
		if not hands.move_to(_centre + Vector3(cos(angle), 0.0, sin(angle)) * distance):
			wake_at(context.current_tick + 1) # no walk to wake it: pause here and go on
		return Status.RUNNING
	if hands.is_following_order():
		return Status.RUNNING
	# A walk ended: it arrived, or there was no way there. Stand and look around before the next one.
	if _going_to_centre:
		_going_to_centre = false
		hands.hold(&"sprint", false)
	_pause_until = context.current_tick + maxi(TickDriver.ticks_at_rate(_kind_settings.pause_ticks), 1) # pause_ticks are at 60 a second
	wake_at(_pause_until)
	return Status.RUNNING


func exit(context: AIManager, _reason: String) -> void:
	if context.controller:
		context.controller.hold(&"sprint", false)
		context.controller.stop()
