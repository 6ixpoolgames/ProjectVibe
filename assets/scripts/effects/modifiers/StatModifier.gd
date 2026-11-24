# Written by Claude (claude-opus-5-5), 2026-11-10. History: effects/CHANGELOG.md.
## Changes a stat's value while its effect lasts, such as MoveSpeed x0.7 for a slow. A modifier ([EffectModifier]).
##
## The stat becomes base_value x every multiply + every add, over all modifiers on the pawn (multiply, then add, for everything), or
## an override's value when one overrides (the last applied wins); it returns to base_value when they end.
## Per stack, add counts once and multiply applies once (x0.7 twice is x0.49). Worked out on every machine, so a client's predicted
## movement agrees with the server.
## Design: pawn spec 8.11 and 16.8.
class_name StatModifier
extends EffectModifier

## The stat, by name, such as &"MoveSpeed".
@export var stat: StringName = &"MoveSpeed"
## Added after the multiplies. 0: nothing.
@export var add := 0.0
## The stat's base value is multiplied by this, before the adds. 1: nothing. 0.7 is 30% less.
@export_range(0.0, 10.0, 0.01, "or_greater") var multiply := 1.0
## On: the stat takes [member override_value], whatever its base and the other modifiers (a freeze sets MoveSpeed to 0).
@export var overrides := false
## With [member overrides], the stat's value.
@export var override_value := 0.0


# Its share of the pawn's totals: an add and a multiply for its stat.
func add_held(totals: ModifierTotals, stacks: int) -> void:
	if overrides:
		totals.override_stat(stat, override_value)
	else:
		totals.change_stat(stat, add, multiply, stacks)
