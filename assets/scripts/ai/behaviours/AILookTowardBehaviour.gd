# Written by Claude (claude-opus-5-5), 2026-11-09. History: ai/CHANGELOG.md.
## Stops and looks toward something half-noticed: the first reaction to a glimpse.
##
## Pawn spec section 10.7. Allowed in Alert by default. "Huh, what was that?": it scores high while the most aware entry in memory
## isn't certain yet, stops the pawn, and looks at that entry's last known position for [member look_ticks]. Looking turns the AI's
## eyes (SightSense sees where the AI looks), so a target that stays in view keeps filling awareness.
## [br]
## Look first, then go and see (the owner's call): it scores above Investigate (0.6 against 0.5), because turning to look is the
## cheaper way to become certain. Once it has looked, its persistence is negative (-0.3, held about 10 s, then fading over 5 s), so
## Investigate (0.5) wins over it (0.3) and it doesn't catch again while Investigate walks over. It runs again only when Investigate
## can't: Investigate's cooldown after it finishes without finding anything, when Look Toward is the only thing left to do in Alert.
## [member min_run_ticks] is its look, so the penalty that starts with it doesn't cut the look short.
## [br]
## It's only available while something uncertain is remembered, so it never runs for an enemy it's already certain of, or while an
## unknown attacker hit the pawn within [member hit_memory_ticks]: then it looks where the hit came from. There's no memory entry for
## that attacker (no damage sense, the owner's call), only the context's note of the hit.
class_name AILookTowardBehaviour
extends AIBehaviourBase

## How long it looks, in ticks.
@export_range(1, 36000, 1, "or_greater") var look_ticks := 60
## How long after being hit by an unknown attacker it may still turn toward where the hit came from, in ticks.
@export_range(0, 36000, 1, "or_greater") var hit_memory_ticks := 300


func _init() -> void:
	super()
	allowed_states = [&"Alert"]
	max_score = 0.6
	min_score = max_score # a fixed score, so it can help skip others
	tick_interval_ticks = 5 # re-aiming 12 times a second is plenty, and each tick searches memory
	min_run_ticks = look_ticks # an ordinary decision doesn't cut its look short, now that its persistence is negative
	# Once it has looked, Investigate goes first: -0.3 takes it from 0.6 to 0.3, below Investigate's 0.5, for about 10 s, fading over
	# the next 5 (written for 60 ticks a second).
	persistence = -0.3
	var penalty := FadeProfile.new()
	penalty.mode = FadeProfile.Mode.LINEAR
	penalty.hold_ticks = 600
	penalty.fade_ticks = 300
	persistence_fade = penalty


## Only for something half-noticed: an uncertain most aware entry, or a hit within [member hit_memory_ticks] from an attacker it
## doesn't remember. Two conditions, either of which will do. Its score is always max_score.
func own_conditions() -> Array[AICondition]:
	return AIInputs.half_noticed_conditions(hit_memory_ticks)


func enter(context: AIContextComponent) -> void:
	context.controller.stop()
	_look(context)


func tick(context: AIContextComponent) -> Status:
	_look(context) # follow it if it moves while still in view
	# Time since it started, in ticks, so it lasts the same at any tick_interval_ticks.
	return Status.SUCCEEDED if context.current_tick - started_tick >= TickDriver.ticks_at_rate(look_ticks) else Status.RUNNING


func exit(context: AIContextComponent, _reason: String) -> void:
	if context.controller:
		context.controller.stop_looking()


func _look(context: AIContextComponent) -> void:
	var point: Variant = context.point_of_interest(hit_memory_ticks)
	if point != null:
		context.controller.look_at_point(point + Vector3(0.0, 1.0, 0.0))
