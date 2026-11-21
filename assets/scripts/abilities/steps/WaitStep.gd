# Written by Claude (claude-opus-5-5), 2026-11-16. History: abilities/CHANGELOG.md.
## A timed pause, such as an attack's recovery: it does nothing but take its length_ticks.
##
## For visuals, the weapon stays at the end of the sweep that started this step, if one did.
## Design: pawn spec 8.20.
class_name WaitStep
extends AbilityStep

var _after_sweep: MeleeSweepStep = null # the sweep whose end starts this one, found once in setup()


func setup() -> void:
	_after_sweep = ability.step_before(self) as MeleeSweepStep


func weapon_point(facing: float) -> Variant:
	# An if, not a ternary, which wants both answers to be the same type.
	if _after_sweep:
		return _after_sweep.offset_at(1.0, facing)
	return null
