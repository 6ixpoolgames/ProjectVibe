# Written by Claude (claude-opus-5-5), 2026-11-23. History: ai/CHANGELOG.md.
@tool
## A change to how some behaviours compare while it lasts: "Charge!" raising melee, fear lowering fighting, a block (pawn spec 10.13).
##
## A designer-made [Definition] (with variants), given to a pawn's behaviour manager by whatever causes it, keyed by that source:
## [codeblock]
## pawn.ai.behaviour_manager.add_score_modifier(charge_shout, self)
## pawn.ai.behaviour_manager.remove_score_modifier(self)
## [/codeblock]
## Its [member amount] is added wherever persistence is added, so it reads in the same units as max_score. Modifiers from different
## sources stack. Only on the server, where the AI runs.
class_name AIScoreModifier
extends Definition

## Which behaviours it changes: a query over each behaviour's own tags ([member AIBehaviourBase.tags]), such as any of
## ai.stance.melee. Empty: every behaviour.
@export var applies_to: TagQuery:
	set(value):
		applies_to = value
		_changed(&"applies_to", value)
## Added to their scores while it counts. Negative lowers them.
@export var amount := 0.0:
	set(value):
		amount = value
		_changed(&"amount", value)
## On: the behaviours it applies to can't be chosen while it counts, and a running one is replaced, instead of adding amount.
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


## True if it applies to this behaviour.
func applies_to_behaviour(behaviour: AIBehaviourBase) -> bool:
	return applies_to == null or applies_to.is_empty() or applies_to.matches_words(behaviour.tag_words())


## True if it counts for owned tags given as words (its ongoing requirements pass).
func counts_for(owned_words: PackedInt64Array) -> bool:
	return ongoing_requirements == null or ongoing_requirements.matches_words(owned_words)
