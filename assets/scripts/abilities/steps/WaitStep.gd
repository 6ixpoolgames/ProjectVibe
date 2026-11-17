# Written by Claude (claude-opus-5-5), 2026-11-16. History: abilities/CHANGELOG.md.
## A timed pause, such as an attack's recovery: it does nothing but take its length_ticks.
##
## Pawn spec 8.20. For visuals, the weapon stays at the end of the sweep that started this step, if one did.
class_name WaitStep
extends AbilityStep

var _after_sweep: MeleeSweepStep = null # the sweep that starts this one, found once in setup()


func setup() -> void:
	_after_sweep = null
	for step in ability.steps:
		var sweep := step as MeleeSweepStep
		if sweep and sweep.starts_when_finished.any(func(path: NodePath) -> bool: return sweep.get_node_or_null(path) == self):
			_after_sweep = sweep
			break


func weapon_point(facing: float) -> Variant:
	# GDScript note: an if rather than "a if b else c", which wants both answers to be the same type (a Vector3 and null aren't).
	if _after_sweep:
		return _after_sweep.offset_at(1.0, facing)
	return null
