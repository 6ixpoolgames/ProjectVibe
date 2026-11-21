# Written by Claude (claude-opus-5-5), 2026-11-16. History: abilities/CHANGELOG.md.
## The wait before an attack's hit, turning toward the look first if it needs to.
##
## Its timer (length_ticks) only counts while the pawn is within [member start_within_degrees] of where it looks, or while no
## [TurnToFaceStep] of its ability runs, so a swing started facing roughly right is as quick as a plain timer and one started facing
## away turns first. The timeline starts the turn alongside it, and the sweep when it's done. For visuals, the weapon waits at the
## start of the sweep that follows it.
## Design: pawn spec 8.20.
class_name WindupStep
extends AbilityStep

## The turn is close enough for the timer to count, in degrees between where the pawn faces and where it looks.
@export_range(0.0, 180.0, 1.0) var start_within_degrees := 90.0
var _turns: Array[TurnToFaceStep] = [] # its ability's turn steps, found once in setup()
var _sweep: MeleeSweepStep = null # the sweep that follows it, found once in setup()


func setup() -> void:
	_turns.clear()
	for step in ability.steps:
		if step is TurnToFaceStep:
			_turns.append(step)
	_sweep = null
	for next in ability.steps_after(self):
		if next is MeleeSweepStep:
			_sweep = next
			break


func counts_this_tick() -> bool:
	for turn in _turns:
		if turn.running:
			return absf(angle_difference(pawn.yaw, ability.look_yaw())) <= deg_to_rad(start_within_degrees)
	return true


func weapon_point(facing: float) -> Variant:
	# An if, not a ternary, which wants both answers to be the same type.
	if _sweep:
		return _sweep.offset_at(0.0, facing)
	return null
