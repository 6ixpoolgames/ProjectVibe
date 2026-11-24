# Written by Claude (claude-opus-5-5), 2026-11-10. History: effects/CHANGELOG.md.
## Changes one of a group of abilities' priority numbers while its effect lasts. A modifier ([EffectModifier]).
##
## Such as boosting abilities tagged ability.combo.second so the next press picks the second swing. [member ability_tag] picks the group (every
## ability whose category or extra_categories is that tag or inside it); [member number] picks which of three numbers changes.
## The AbilityManager adds the totals when it compares numbers, on every machine, so a client's prediction agrees.
## Design: pawn spec 8.11.
class_name AbilityModifier
extends EffectModifier

## PRESS_PRIORITY: which ability a press picks among those on one action. INTERRUPT_PRIORITY: how hard it cancels running abilities
## when it starts. INTERRUPT_THRESHOLD: how hard it is to cancel while running (below 0: easier to interrupt).
enum Number { PRESS_PRIORITY, INTERRUPT_PRIORITY, INTERRUPT_THRESHOLD }

## Which abilities, by ability tag ([TagRegistry]).
@export var ability_tag: StringName = &""
## Which of their numbers changes.
@export var number := Number.PRESS_PRIORITY
## How much is added to it, once per stack. Negative takes away.
@export var amount := 20


# Its share of the pawn's totals: [tag bit, amount] in the list for its number.
func add_held(totals: ModifierTotals, stacks: int) -> void:
	if ability_tag != &"":
		totals.ability_bonuses[number].append([TagRegistry.own_bit(ability_tag), amount * stacks])
