# Written by Claude (claude-opus-5-5), 2026-11-09. History: ai/CHANGELOG.md.
## Walks over to see what something half-noticed was.
##
## Allowed in Alert. Available while the most aware memory entry isn't certain yet (Search handles certain ones), or while an unknown
## attacker hit the pawn within [member AIInvestigateDefinition.hit_memory_ticks], when it walks to where the hit came from. It walks, without sprinting, to the
## entry's last known position and heads for a new one if that moves more than [member AIInvestigateDefinition.repath_distance]. It succeeds on arriving and
## fails if there's no way there; its cooldown stops it walking to the same spot over and over.
## Design: pawn spec 10.7.
class_name AIInvestigateBehaviour
extends AIBehaviourBase

# Its settings, typed: [member AIBehaviourBase.settings] as its kind's definition.
var _kind_settings: AIInvestigateDefinition = null
var _goal := Vector3.ZERO


func make_default_definition() -> AIBehaviourDefinition:
	return AIInvestigateDefinition.new()


func _settings_changed() -> void:
	_kind_settings = settings as AIInvestigateDefinition


## Only for something half-noticed: an uncertain most aware entry, or a recent hit from an attacker it doesn't remember. Either will do.
func own_conditions() -> Array[AICondition]:
	return AIInputs.half_noticed_conditions(_kind_settings.hit_memory_ticks)


func enter(context: AIManager) -> void:
	context.controller.hold(&"sprint", false)
	var point: Variant = context.point_of_interest(_kind_settings.hit_memory_ticks)
	if point != null:
		_go(context, point)


func tick(context: AIManager) -> Status:
	var point: Variant = context.point_of_interest(_kind_settings.hit_memory_ticks)
	if point == null:
		return Status.FAILED # forgotten
	if point.distance_to(_goal) > _kind_settings.repath_distance:
		_go(context, point)
	if context.controller.is_following_order():
		return Status.RUNNING
	var offset := _goal - pawn.global_position
	offset.y = 0.0
	return Status.SUCCEEDED if offset.length() <= _kind_settings.arrive_distance else Status.FAILED


func exit(context: AIManager, _reason: String) -> void:
	if context.controller:
		context.controller.stop()


func _go(context: AIManager, point: Vector3) -> void:
	_goal = point
	context.controller.move_to(point)
