## Written by Claude (claude-opus-5-5), 2026-11-10: changes one of a group of abilities' priority numbers while its effect lasts. A held
## part (EffectPart). Pawn spec 8.11, the owner's design: a swing puts an over-time effect on its own pawn with one of these, boosting
## the abilities tagged combo.second, so the next press of the attack picks the second swing; that one boosts combo.finisher. Combos
## come from boosts and tags alone, with no gates.
##
## Which number (the owner's call: three kept apart):
##   PRESS_PRIORITY      which ability a press picks among those on one action (AbilityBase.priority). Locomotion ignores it.
##   INTERRUPT_PRIORITY  how hard the ability cancels running ones when it starts (interrupt_priority)
##   INTERRUPT_THRESHOLD how hard the ability is to cancel while it runs (interrupt_threshold); below 0 makes it easier, such as a
##                       mage who's easy to interrupt
## The group is an ability tag (TagRegistry), such as &"combo.second": every ability on the pawn whose category or extra_categories
## is that tag, or inside it. With stacks, the amount counts once per stack.
## The AbilityManager adds these when it compares numbers, on every machine, so a client's prediction agrees. The interrupt table
## (AbilityManager.get_interrupt_table) shows the numbers with them added.
class_name AbilityPriorityPart
extends EffectPart

enum Number { PRESS_PRIORITY, INTERRUPT_PRIORITY, INTERRUPT_THRESHOLD }

## Which abilities, by ability tag.
@export var ability_tag: StringName = &""
## Which of their numbers.
@export var number := Number.PRESS_PRIORITY
## How much is added to it. Negative takes away.
@export var amount := 20


func is_held() -> bool:
	return true
