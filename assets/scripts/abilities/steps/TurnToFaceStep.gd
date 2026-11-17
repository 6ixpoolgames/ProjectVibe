# Written by Claude (claude-opus-5-5), 2026-11-16. History: abilities/CHANGELOG.md.
## Turns the pawn toward where it looks, following the look as it moves, at the pawn's TurnRate stat.
##
## Pawn spec 8.20, the owner's design. The look is the crosshair for a player, look_at_point() for the AI.
## [br]
## It runs only while its ability's action is held (the owner's call), through the base's ends_when_released, which it turns on: let
## go, and it stops with "released"; held, it keeps turning through the swing. But it always turns at least
## [member min_turn_degrees] first, however short the press, unless it faces the look sooner (the owner's call). It doesn't keep its
## ability running (keeps_ability_running is off), so when the swing's other steps are done, the ability ends and this stops with it.
## A WindupStep usually starts it.
## [br]
## The pawn's yaw rolls back and its look and held actions are input, so a rollback replay turns the same way. The minimum is counted
## from step_ticks, which rolls back, so it needs no state of its own.
class_name TurnToFaceStep
extends AbilityStep

## The stat that says how fast it turns, in degrees a second. TurnRate is the one Walk and Sprint turn the body with.
@export var turn_speed_stat: StringName = &"TurnRate"
## How fast it turns, in degrees a second. -1 (the default): the pawn's turn_speed_stat, or 540 without one. 0: it doesn't turn.
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
		# GDScript note: rotate_toward() turns an angle toward another by at most the step, the short way round.
		pawn.yaw = rotate_toward(pawn.yaw, ability.look_yaw(), deg_to_rad(speed) * dt)
	return Status.RUNNING
