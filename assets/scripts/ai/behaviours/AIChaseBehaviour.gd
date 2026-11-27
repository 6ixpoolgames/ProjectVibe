# Written by Claude (claude-opus-5-5), 2026-11-09. History: ai/CHANGELOG.md.
## Runs after a target it can see, and stops within reach for Attack to take over.
##
## Allowed in Combat, while the target was seen within [member AIChaseDefinition.lost_after_ticks]; after that [AIGoToLastKnownBehaviour]
## walks to where it was last seen. Its steps: a Follow that closes in on the target, finding a new path every
## [member AIChaseDefinition.repath_ticks] or when the target moves [member AIChaseDefinition.repath_distance], and stopping within
## [member AIChaseDefinition.stop_distance]; a LookAt on the target, for Attack; the Sprint hold throughout; and with
## [member AIChaseDefinition.dash_to_close] on, a Dash press to close the last few metres. Its steps are started again only when the
## target changes, so an order stream carries a few orders per chase, not one a tick (netcode spec 19.10). Design: pawn spec 10.7.
class_name AIChaseBehaviour
extends AIBehaviourBase

# Its settings, typed: [member AIBehaviourBase.settings] as its kind's definition.
var _kind_settings: AIChaseDefinition = null
var _memory: AIMemory = null
var _following: Node3D = null # the target its Follow and LookAt steps were given


func make_default_definition() -> AIBehaviourDefinition:
	return AIChaseDefinition.new()


func _settings_changed() -> void:
	_kind_settings = settings as AIChaseDefinition


## Only while the target was seen recently: within [member AIChaseDefinition.lost_after_ticks].
func own_conditions() -> Array[AICondition]:
	var list: Array[AICondition] = [AICompareCondition.make(AIInputs.TICKS_SINCE_TARGET_SEEN, AICompareCondition.Comparison.AT_MOST,
		_kind_settings.lost_after_ticks)]
	return list


func make_steps() -> Array[Step]:
	return [made_step(FollowStep, &"Follow"), made_step(LookAtStep, &"LookAt"), made_sprint_step(), made_step(PressStep, &"Dash")]


func enter(context: AIManager) -> void:
	_memory = context.memory
	_following = null
	if _kind_settings.sprint:
		start_step(SPRINT_STEP)


func tick(context: AIManager) -> Status:
	var index := context.current_target_index()
	if index < 0:
		return Status.FAILED # the target is gone
	var target := context.current_target
	var seen := is_instance_valid(target) and _memory.ticks_since_seen_at(index, context.current_tick) <= TickDriver.ticks_at_rate(_kind_settings.lost_after_ticks)
	if not seen:
		return Status.FAILED # lost: a decision at once, and Go To Last Known takes over
	if _following != target:
		_following = target
		start_step(&"Follow", {"target": target, "stop_distance": _kind_settings.stop_distance, "band": 0.3,
			"repath_ticks": _kind_settings.repath_ticks, "repath_distance": _kind_settings.repath_distance})
		start_step(&"LookAt", {"target": target, "offset": Vector3(0.0, 1.0, 0.0)})
	# A dash to close in: whatever ability in close_in_tag's group can start. Pressed only when it can, so a press never waits in Dash's buffer.
	if _kind_settings.dash_to_close and pawn.ability_manager and not is_step_running(&"Dash"):
		var offset := target.global_position - pawn.global_position
		offset.y = 0.0
		var distance_squared := offset.length_squared()
		if distance_squared <= _kind_settings.dash_from_distance * _kind_settings.dash_from_distance and distance_squared >= _kind_settings.dash_to_distance * _kind_settings.dash_to_distance:
			var action := pawn.ability_manager.action_for_tag(_kind_settings.close_in_tag)
			if action != &"":
				start_step(&"Dash", {"action": action})
	return Status.RUNNING
