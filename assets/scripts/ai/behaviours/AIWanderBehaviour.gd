# Written by Claude (claude-opus-5-5), 2026-11-09. History: ai/CHANGELOG.md.
## Walks to random nearby points, pausing between them: what a pawn does when nothing more interesting can run.
##
## Allowed in Idle, with a low fixed score. It picks a random point within [member AIWanderDefinition.wander_radius] of its home (where the pawn first
## started wandering), walks there with a MoveTo step, then stands for a random time between [member AIWanderDefinition.min_pause_ticks]
## and [member AIWanderDefinition.max_pause_ticks]. The points and pauses come from the context's replayable random numbers, so the same seed, pawn and
## ticks give the same walk. A point with no way there is skipped and another tried soon. It never finishes on its own.
## Design: pawn spec 10.7.
class_name AIWanderBehaviour
extends AIBehaviourBase

# Its settings, typed: [member AIBehaviourBase.settings] as its kind's definition.
var _kind_settings: AIWanderDefinition = null
const POINT_ANGLE_SALT := 0x51A1 # what each random number is for, so they differ from each other
const POINT_DISTANCE_SALT := 0x51A2
const PAUSE_SALT := 0x51A3

var _home := Vector3.ZERO
var _has_home := false
var _walking := false # a walk was started and hasn't been seen to end
var _pause_until := -1 # the tick its current pause ends; -1: not pausing


func make_default_definition() -> AIBehaviourDefinition:
	return AIWanderDefinition.new()


func _settings_changed() -> void:
	_kind_settings = settings as AIWanderDefinition


func make_steps() -> Array[Step]:
	return [made_step(MoveToStep, &"MoveTo")]


func enter(_context: AIManager) -> void:
	if not _has_home and pawn:
		_home = pawn.global_position
		_has_home = true
	_walking = false
	_pause_until = -1
	wake_on_step_end()


func tick(context: AIManager) -> Status:
	if pawn == null:
		return Status.FAILED
	# Pauses end at a tick, not after a count of tick() calls, so they last the same at any tick_interval_ticks.
	if _pause_until >= 0:
		if context.current_tick < _pause_until:
			wake_at(_pause_until)
			return Status.RUNNING
		_pause_until = -1
	if is_step_running(&"MoveTo"):
		return Status.RUNNING
	if _walking:
		# The walk ended: it arrived, or nav gave up on it. Stand for a while either way.
		_walking = false
		# Both written for 60 ticks a second.
		var shortest := TickDriver.ticks_at_rate(_kind_settings.min_pause_ticks)
		var longest := TickDriver.ticks_at_rate(_kind_settings.max_pause_ticks)
		_pause_until = context.current_tick + shortest + int(context.random_unit(PAUSE_SALT) * (maxi(longest - shortest, 0) + 1))
		wake_at(_pause_until)
		return Status.RUNNING
	# sqrt makes points spread evenly over the circle; without it they'd bunch up near the middle.
	var angle := context.random_unit(POINT_ANGLE_SALT) * TAU
	var distance := sqrt(context.random_unit(POINT_DISTANCE_SALT)) * _kind_settings.wander_radius
	var walk := start_step(&"MoveTo", {"goal": _home + Vector3(cos(angle), 0.0, sin(angle)) * distance}) as MoveToStep
	if walk and not walk.gave_up():
		_walking = true
	else:
		stop_step(&"MoveTo")
		wake_at(context.current_tick + TickDriver.ticks_at_rate(5)) # no walk to wake it: try another point soon
	return Status.RUNNING


func exit(_context: AIManager, _reason: String) -> void:
	_walking = false
	_pause_until = -1
