# Written by Claude (claude-opus-5-5), 2026-11-09. History: ai/CHANGELOG.md.
## Stops and looks toward something half-noticed: the first reaction to a glimpse.
##
## Allowed in Alert. Available while the most aware memory entry isn't certain yet, or an unknown attacker hit the pawn within
## [member hit_memory_ticks] (then it looks where the hit came from). It stops the pawn and looks at that position for [member look_ticks];
## looking turns the AI's eyes, so a target still in view keeps filling awareness. It scores 0.6, above Investigate (0.5), because
## turning to look is the cheaper way to become certain; once it has looked, a negative persistence (-0.3) drops it to 0.3, so
## Investigate wins and Look Toward doesn't catch again while it walks over. It runs again only when Investigate is cooling down.
## Design: pawn spec 10.7.
class_name AILookTowardBehaviour
extends AIBehaviourBase

## How long it looks, in ticks.
@export_range(1, 36000, 1, "or_greater") var look_ticks := 60
## How long after being hit by an unknown attacker it may still turn toward where the hit came from, in ticks.
@export_range(0, 36000, 1, "or_greater") var hit_memory_ticks := 300


func _init() -> void:
	super()
	tag_requirements = TagQuery.shared([Tags.AI.STATE_ALERT])
	max_score = 0.6
	min_score = max_score # a fixed score, so it can help skip others
	tick_interval_ticks = 5 # re-aiming 12 times a second is plenty, and each tick searches memory
	min_run_ticks = look_ticks # an ordinary decision doesn't cut its look short, whatever its persistence
	# Once it has looked, Investigate goes first: -0.3 takes it from 0.6 to 0.3, below Investigate's 0.5, for about 10 s, fading over
	# the next 5 (written for 60 ticks a second).
	persistence = -0.3
	var penalty := FadeProfile.new()
	penalty.mode = FadeProfile.Mode.LINEAR
	penalty.hold_ticks = 600
	penalty.fade_ticks = 300
	persistence_fade = penalty


## Only for something half-noticed: an uncertain most aware entry, or a recent hit from an attacker it doesn't remember. Either will do.
func own_conditions() -> Array[AICondition]:
	return AIInputs.half_noticed_conditions(hit_memory_ticks)


func enter(context: AIManager) -> void:
	context.controller.stop()
	_look(context)


func tick(context: AIManager) -> Status:
	_look(context) # follow it if it moves while still in view
	# Time since it started, in ticks, so it lasts the same at any tick_interval_ticks.
	return Status.SUCCEEDED if context.current_tick - started_tick >= TickDriver.ticks_at_rate(look_ticks) else Status.RUNNING


func exit(context: AIManager, _reason: String) -> void:
	if context.controller:
		context.controller.stop_looking()


func _look(context: AIManager) -> void:
	var point: Variant = context.point_of_interest(hit_memory_ticks)
	if point != null:
		context.controller.look_at_point(point + Vector3(0.0, 1.0, 0.0))
