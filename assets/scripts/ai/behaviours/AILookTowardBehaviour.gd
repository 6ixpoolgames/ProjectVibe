# Written by Claude (claude-opus-5-5), 2026-11-09. History: ai/CHANGELOG.md.
## Stops and looks toward something half-noticed: the first reaction to a glimpse.
##
## Allowed in Alert. Available while the most aware memory entry isn't certain yet, or an unknown attacker hit the pawn within
## [member AILookTowardDefinition.hit_memory_ticks] (then it looks where the hit came from). It stops the pawn and looks at that position for [member AILookTowardDefinition.look_ticks];
## looking turns the AI's eyes, so a target still in view keeps filling awareness. It scores 0.6, above Investigate (0.5), because
## turning to look is the cheaper way to become certain; as it starts it gives itself -0.3 for 15 s ([member AIBehaviourDefinition.modifier_on_start]),
## dropping it to 0.3, so Investigate wins and Look Toward doesn't catch again while it walks over. It runs again only when
## Investigate is cooling down.
## Design: pawn spec 10.7.
class_name AILookTowardBehaviour
extends AIBehaviourBase

# Its settings, typed: [member AIBehaviourBase.settings] as its kind's definition.
var _kind_settings: AILookTowardDefinition = null


func make_default_definition() -> AIBehaviourDefinition:
	return AILookTowardDefinition.new()


func _settings_changed() -> void:
	_kind_settings = settings as AILookTowardDefinition


## Only for something half-noticed: an uncertain most aware entry, or a recent hit from an attacker it doesn't remember. Either will do.
func own_conditions() -> Array[AICondition]:
	return AIInputs.half_noticed_conditions(_kind_settings.hit_memory_ticks)


func enter(context: AIManager) -> void:
	context.controller.stop()
	_look(context)


func tick(context: AIManager) -> Status:
	_look(context) # follow it if it moves while still in view
	# Time since it started, in ticks, so it lasts the same at any tick_interval_ticks.
	return Status.SUCCEEDED if context.current_tick - started_tick >= TickDriver.ticks_at_rate(_kind_settings.look_ticks) else Status.RUNNING


func exit(context: AIManager, _reason: String) -> void:
	if context.controller:
		context.controller.stop_looking()


func _look(context: AIManager) -> void:
	var point: Variant = context.point_of_interest(_kind_settings.hit_memory_ticks)
	if point != null:
		context.controller.look_at_point(point + Vector3(0.0, 1.0, 0.0))
