# Written by Claude (claude-opus-5-5), 2026-11-09. History: ai/CHANGELOG.md.
## Runs after the current target, and stops within reach for Attack to take over.
##
## Allowed in Combat. While the target is seen it gives one persistent order, [method AIController.follow]: the controller closes in on
## the target, repathing every [member AIChaseDefinition.repath_ticks] or when the target moves [member AIChaseDefinition.repath_distance], stops within
## [member AIChaseDefinition.stop_distance] and faces it for Attack. Once the target hasn't been seen for [member AIChaseDefinition.lost_after_ticks] it walks to where it
## was last seen instead. It holds sprint throughout; with [member AIChaseDefinition.dash_to_close] on it also dashes to close the last few metres. It
## never finishes on its own: when the target is out of sight long enough, Combat's prerequisites fail and the state change replaces it.
## Orders only when one of those changes, so an order stream carries a few per chase, not one a tick (netcode spec 19.10).
## Design: pawn spec 10.7.
# REFACTOR: the sprint action's name, &"sprint", is written into Chase, Search and Investigate. A setting (or a tag, as close_in_tag
# is) would let a game with another name for sprinting use them without code (designer friendly). See CHANGELOG.md.
class_name AIChaseBehaviour
extends AIBehaviourBase

# Its settings, typed: [member AIBehaviourBase.settings] as its kind's definition.
var _kind_settings: AIChaseDefinition = null
var _goal := Vector3.ZERO
# Looked up once in enter(), and what it last ordered, so a tick gives an order only when something changed.
var _hands: AIController = null
var _memory: AIMemory = null
var _following: Node3D = null # the target it told the controller to follow; null while it walks to the last known position


func make_default_definition() -> AIBehaviourDefinition:
	return AIChaseDefinition.new()


func _settings_changed() -> void:
	_kind_settings = settings as AIChaseDefinition


func enter(context: AIManager) -> void:
	_hands = context.controller
	_memory = context.memory
	_following = null
	_goal = Vector3.INF
	_hands.hold(&"sprint", _kind_settings.sprint)


func tick(context: AIManager) -> Status:
	var index := context.current_target_index()
	if index < 0:
		return Status.FAILED # the target is gone
	var target := context.current_target
	var seen := is_instance_valid(target) and _memory.ticks_since_seen_at(index, context.current_tick) <= TickDriver.ticks_at_rate(_kind_settings.lost_after_ticks)
	var there := target.global_position if seen else _memory.last_known_position_at(index)
	if seen:
		if _following != target:
			_following = target
			_hands.follow(target, _kind_settings.stop_distance, Vector3(0.0, 1.0, 0.0), 0.3, _kind_settings.repath_ticks, _kind_settings.repath_distance)
	elif _following != null or there.distance_to(_goal) > _kind_settings.repath_distance:
		# Out of sight: one walk to where it was last seen, given again only if that spot moves (memory heard of it again).
		_following = null
		_goal = there
		_hands.move_to(there)
		_hands.look_at_point(there + Vector3(0.0, 1.0, 0.0))
	var offset := there - pawn.global_position
	offset.y = 0.0
	# A dash to close in: whatever ability in close_in_tag's group can start. Pressed only when it can, so a press never waits in Dash's buffer.
	if _kind_settings.dash_to_close and pawn.ability_manager:
		var distance_squared := offset.length_squared()
		if distance_squared <= _kind_settings.dash_from_distance * _kind_settings.dash_from_distance and distance_squared >= _kind_settings.dash_to_distance * _kind_settings.dash_to_distance:
			var action := pawn.ability_manager.action_for_tag(_kind_settings.close_in_tag)
			if action != &"":
				_hands.press(action)
	return Status.RUNNING


func exit(context: AIManager, _reason: String) -> void:
	if context.controller:
		context.controller.hold(&"sprint", false)
		context.controller.stop()
		context.controller.stop_looking()
