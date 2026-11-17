# Written by Claude (claude-opus-5-5), 2026-11-16. History: abilities/CHANGELOG.md.
## Turns the pawn toward where it looks, following the look as it moves, at the pawn's TurnRate stat.
##
## The look is the crosshair for a player, [code]look_at_point()[/code] for the AI. It runs only while its ability's action is held
## (ends_when_released is on): let go and it stops with "released", unless it hasn't yet turned [member min_turn_degrees] or faced the
## look. It doesn't keep its ability running, so it ends with the swing. A [WindupStep] usually starts it.
## [br][br]Rollback: yaw rolls back, and look and held actions are input, so a replay turns the same way; the minimum counts from step_ticks.
## Design: pawn spec 8.20.
class_name TurnToFaceStep
extends AbilityStep

## The stat that says how fast it turns, in degrees a second. TurnRate is the one Walk and Sprint turn the body with.
@export var turn_speed_stat: StringName = &"TurnRate"
## How fast it turns, in degrees a second. -1: the pawn's turn_speed_stat, or 540 without one. 0: it doesn't turn.
@export_range(-1.0, 3600.0, 1.0, "or_greater") var degrees_per_second := -1.0
## It turns at least this far before a release can stop it, in degrees, unless it faces the look sooner.
@export_range(0.0, 360.0, 1.0) var min_turn_degrees := 45.0


func _init() -> void:
	super()
	keeps_ability_running = false
	ends_when_released = true


## How fast it turns now, in degrees a second.
func current_speed() -> float:
	if degrees_per_second >= 0.0:
		return degrees_per_second
	return ability.read_stat(turn_speed_stat, 540.0)


func can_end_on_release() -> bool:
	var speed := current_speed()
	if speed <= 0.0 or absf(angle_difference(pawn.yaw, ability.look_yaw())) < 0.01:
		return true # nothing to turn, or already facing the look
	var per_tick := speed / float(TickDriver.get_tick_rate())
	return step_ticks >= ceili(min_turn_degrees / per_tick)


func tick(dt: float) -> Status:
	var speed := current_speed()
	if speed > 0.0:
		pawn.yaw = rotate_toward(pawn.yaw, ability.look_yaw(), deg_to_rad(speed) * dt)
	return Status.RUNNING
