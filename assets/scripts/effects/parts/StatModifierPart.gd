# Written by Claude (claude-opus-5-5), 2026-11-10. History: effects/CHANGELOG.md.
## Changes a stat's value while its effect lasts, such as MoveSpeed x0.7 for a slow. A held part ([EffectPart]).
##
## The stat becomes (base_value + every add) x every multiply over all held parts on the pawn, and returns to base_value when they end.
## Per stack, add counts once and multiply applies once (x0.7 twice is x0.49). Worked out on every machine, so a client's predicted
## movement agrees with the server.
## Design: pawn spec 8.11.
class_name StatModifierPart
extends EffectPart

## The stat, by name, such as &"MoveSpeed".
@export var stat: StringName = &"MoveSpeed"
## Added to the stat's base value. 0: nothing.
@export var add := 0.0
## Then the stat is multiplied by this. 1: nothing. 0.7 is 30% less.
@export_range(0.0, 10.0, 0.01, "or_greater") var multiply := 1.0


func is_held() -> bool:
	return true


# Its share of the pawn's totals: an add and a multiply for its stat.
func add_held(totals: EffectHeldTotals, stacks: int) -> void:
	totals.change_stat(stat, add, multiply, stacks)
