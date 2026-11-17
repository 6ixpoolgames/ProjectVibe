# Written by Claude (claude-opus-5-5), 2026-11-16. History: abilities/CHANGELOG.md.
## The wait before an attack's hit, turning toward the look first if it needs to.
##
## When it starts it starts its [member turn_step] (a [TurnToFaceStep]). Its timer (length_ticks) only counts while the pawn is within
## [member start_within_degrees] of where it looks, or once the turn has stopped, so a swing started facing roughly right is as quick
## as a plain timer and one started facing away turns first. When done it starts the steps in starts_when_finished: the sweep.
## For visuals, the weapon waits at the start of that sweep.
## Design: pawn spec 8.20.
class_name WindupStep
extends AbilityStep

## The turn is close enough for the timer to count, in degrees between where the pawn faces and where it looks.
@export_range(0.0, 180.0, 1.0) var start_within_degrees := 90.0
## The TurnToFaceStep it starts. Empty: it starts none, and its timer always counts.
@export var turn_step: NodePath

var _turn: AbilityStep = null # found once, in setup()


func setup() -> void:
	_turn = get_node_or_null(turn_step) as AbilityStep if turn_step != NodePath("") else null


func enter() -> void:
	if _turn:
		ability.start_step(_turn)


func counts_this_tick() -> bool:
	if _turn == null or not ability.is_step_running(_turn):
		return true
	return absf(angle_difference(pawn.yaw, ability.look_yaw())) <= deg_to_rad(start_within_degrees)


func weapon_point(facing: float) -> Variant:
	for next in next_steps:
		var sweep := next as MeleeSweepStep
		if sweep:
			return sweep.offset_at(0.0, facing)
	return null
