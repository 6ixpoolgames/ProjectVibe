## Written by Claude (claude-opus-5-5), 2026-11-09: stops and looks toward something half-noticed. Pawn spec section 10.7. Allowed in
## Alert by default.
##
## The first reaction to a glimpse: "huh, what was that?". It scores high while the most aware entry in memory isn't certain
## yet, stops the pawn, and looks at that entry's last known position for look_ticks. Looking turns the AI's eyes (SightSense
## sees where the AI looks), so a target that stays in view keeps filling awareness. Then it finishes, and its cooldown lets
## Investigate take over.
##
## It's only available while something uncertain is remembered, so it never runs for an enemy it's already certain of.
class_name AILookTowardBehaviour
extends AIBehaviourBase

## How long it looks, in ticks.
@export_range(1, 36000, 1, "or_greater") var look_ticks := 60

func _init() -> void:
	super()
	allowed_states = [&"Alert"]
	max_score = 0.6
	min_score = max_score # a fixed score, so it can help skip others
	cooldown_ticks = 180
	tick_interval_ticks = 5 # Claude 2026-11-09: re-aiming 12 times a second is plenty, and each tick searches memory


# Only for something half-noticed: the most aware entry in memory exists and isn't certain yet. Its score is always
# max_score, so it doesn't need a score() of its own.
func is_available(context: AIContextComponent) -> bool:
	var index := context.most_aware_index()
	return index >= 0 and not context.memory.is_certain_at(index)


func enter(context: AIContextComponent) -> void:
	context.controller.stop()
	_look(context)


func tick(context: AIContextComponent) -> Status:
	_look(context) # follow it if it moves while still in view
	# Claude 2026-11-09: time since it started, in ticks, so it lasts the same at any tick_interval_ticks.
	return Status.SUCCEEDED if context.current_tick - started_tick >= look_ticks else Status.RUNNING


func exit(context: AIContextComponent, _reason: String) -> void:
	if context.controller:
		context.controller.stop_looking()


func _look(context: AIContextComponent) -> void:
	var index := context.most_aware_index()
	if index >= 0:
		context.controller.look_at_point(context.memory.last_known_position_at(index) + Vector3(0.0, 1.0, 0.0))
