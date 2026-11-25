# Written by Claude (claude-opus-5-5), 2026-11-23. History: ai/CHANGELOG.md.
@tool
## A change to some behaviours while it lasts: "Charge!" raising melee, fear lowering fighting, confusion's extra jitter, a block.
##
## The generic modifier (pawn spec 16.5, 16.9) aimed at behaviours by their tags: it changes one of their numbers ([member number]),
## multiplying, then adding, or overriding it (the last added wins). A designer-made [Definition] (with variants), given to a pawn's
## behaviour manager by whatever causes it and kept under that source:
## [codeblock]
## pawn.ai.behaviour_manager.add_modifier(charge_shout, self)
## pawn.ai.behaviour_manager.remove_modifiers(self)
## [/codeblock]
## A behaviour can also apply one to itself as it starts or ends ([member AIBehaviourBase.modifier_on_start]). The C++ decider gets
## the numbers they leave, not the modifiers. Only on the server, where the AI runs.
class_name AIBehaviourModifier
extends Definition

## Which of a behaviour's numbers it changes.
enum Number {
	SCORE_BONUS, ## added to its score, in the units of max_score (0 with no modifier)
	SCORE_JITTER, ## the ± random offset on its score (AIBehaviourBase.score_jitter, or the manager's default)
	INTERRUPT_THRESHOLD, ## how strong an event must be to replace it while it runs
	COOLDOWN_TICKS, ## ticks after it ends before it can be chosen again, at 60 a second
	MIN_RUN_TICKS, ## ticks an ordinary decision can't replace it once chosen, at 60 a second
}

## Which behaviours it changes: a query over each behaviour's own tags ([member AIBehaviourBase.tags]), such as any of
## ai.stance.melee. Empty: every behaviour, or, given by a behaviour to itself as it starts or ends, only that behaviour.
@export var applies_to: TagQuery:
	set(value):
		applies_to = value
		_changed(&"applies_to", value)
## Which number it changes.
@export var number := Number.SCORE_BONUS:
	set(value):
		number = value
		_changed(&"number", value)
## The number is multiplied by this, before the adds. 1: nothing. Multiplies from several modifiers combine.
@export var multiply := 1.0:
	set(value):
		multiply = value
		_changed(&"multiply", value)
## Added after the multiplies. Negative takes away. A score bonus of -0.3 drops a behaviour that scores 0.6 to 0.3.
@export var add := 0.0:
	set(value):
		add = value
		_changed(&"add", value)
## On: the number takes [member override_value], whatever the others do (the last one added wins). A berserk state's threshold.
@export var overrides := false:
	set(value):
		overrides = value
		_changed(&"overrides", value)
## With [member overrides], the number's value.
@export var override_value := 0.0:
	set(value):
		override_value = value
		_changed(&"override_value", value)
## On: the behaviours it applies to can't be chosen while it counts, and a running one is replaced; its number change is ignored.
@export var blocks := false:
	set(value):
		blocks = value
		_changed(&"blocks", value)
## How long it lasts once added, in ticks at 60 a second; the manager keeps the tick it ends. 0: until its source removes it.
@export_range(0, 36000, 1, "or_greater") var duration_ticks := 0:
	set(value):
		duration_ticks = value
		_changed(&"duration_ticks", value)
## It counts only while the pawn's owned tags pass this, such as none of status.has_ammo. Empty: always.
@export var ongoing_requirements: TagQuery:
	set(value):
		ongoing_requirements = value
		_changed(&"ongoing_requirements", value)
## Tags the pawn owns while it's added, so other queries can see it (an "ai.stance.melee" order, say).
@export var granted_tags: Array[StringName] = []:
	set(value):
		granted_tags = value
		_changed(&"granted_tags", value)
## On: adding or removing it asks for a decision at once. Off by default: hundreds of pawns deciding on one tick is a spike.
@export var wakes_decision := false:
	set(value):
		wakes_decision = value
		_changed(&"wakes_decision", value)


## True if it applies to this behaviour. only: the behaviour that gave it to itself (null: none), which an empty applies_to means.
func applies_to_behaviour(behaviour: AIBehaviourBase, only: AIBehaviourBase = null) -> bool:
	if applies_to == null or applies_to.is_empty():
		return only == null or only == behaviour
	return applies_to.matches_words(behaviour.tag_words())


## True if it counts for owned tags given as words (its ongoing requirements pass).
func counts_for(owned_words: PackedInt64Array) -> bool:
	return ongoing_requirements == null or ongoing_requirements.matches_words(owned_words)
