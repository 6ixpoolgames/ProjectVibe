## Written by Claude (claude-opus-5-5), 2026-11-16 (pawn spec 8.20, the owner's design): the wait before an attack's hit.
##
## When it starts, it starts its turn_step (a TurnToFaceStep), which turns the pawn toward where it looks while the action is held. Its
## timer (length_ticks) only counts while the pawn is within start_within_degrees of where it looks, or once the turn has stopped (the
## action let go, so the attack goes where the pawn faces). So a swing started facing roughly the right way is as quick as ever, and one
## started facing away turns first. When its timer is done, it starts the steps in starts_when_finished: the sweep.
##
## For visuals, the weapon waits at the start of the sweep it leads to.
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
