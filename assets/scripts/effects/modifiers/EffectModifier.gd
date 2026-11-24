# Written by Claude (claude-opus-5-5), 2026-11-10. History: effects/CHANGELOG.md.
## Something an [Effect] holds while it lasts, such as a slow: the base for the entries in [member Effect.modifiers] (pawn spec 16.8).
##
## A modifier overrides [method add_held], adding what it does to the pawn's [ModifierTotals], stacks times. Modifiers work on every
## machine, and take hold before the effect's effectors fire. One keeps no state while playing: it's shared by every pawn its effect
## lands on.
class_name EffectModifier
extends Resource


## Adds what it does to the pawn's totals, stacks times. Called whenever the pawn's list of effects changes, on every machine.
func add_held(_totals: ModifierTotals, _stacks: int) -> void:
	pass
