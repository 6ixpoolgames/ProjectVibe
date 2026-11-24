# Written by Claude (claude-opus-5-5), 2026-11-10. History: effects/CHANGELOG.md.
## Adds to the pawn's resistance to a kind of effect while its effect lasts. A held part ([EffectPart]).
##
## Such as +0.5 against effect.damage.elemental.fire for a fire ward. Added to the pawn's [member StatusManager.resistances], which explains how
## they count.
## Design: pawn spec 8.11.
class_name ResistancePart
extends EffectPart

## The kind of effect, by effect tag ([code]Tags.EFFECT[/code]), such as &"effect.damage.elemental.fire".
@export var tag: StringName = &""
## How much resistance it adds: 0.25 takes a quarter off. Negative is a weakness.
@export_range(-10.0, 1.0, 0.01, "or_greater", "or_less") var amount := 0.25


func is_held() -> bool:
	return true


# Its share of the pawn's totals: [tag bit, amount] in the resistance list.
func add_held(totals: EffectHeldTotals, stacks: int) -> void:
	if tag != &"":
		totals.resistance_bits.append([TagRegistry.own_bit(tag), amount * stacks])
