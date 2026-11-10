## Written by Claude (claude-opus-5-5), 2026-11-10: changes a stat's value while its effect lasts, such as MoveSpeed x0.7 for a slow. A
## held part (EffectPart). Pawn spec 8.11.
##
## The stat's value becomes (base_value + every add) x every multiply, from all the held parts on the pawn for that stat, and goes
## back to its base_value when they've all ended. With stacks, add counts once per stack and multiply is applied once per stack
## (x0.7 twice is x0.49). The pawn's EffectManager works it out whenever its active list changes, on every machine, so movement a
## client predicts agrees with the server.
## For a stat that changes during play (Health), this changes its most; if that falls below what it has now, what it has falls too.
## While effects change a stat, set its base_value rather than its value: its value is worked out again whenever the list changes.
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
