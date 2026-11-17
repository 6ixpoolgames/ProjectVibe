# Written by Claude (claude-opus-5-5), 2026-11-17. History: ai/CHANGELOG.md.
## The base for a condition: one check a behaviour needs to pass before it may run, made of plain data.
##
## Scaling spec 6.2. A behaviour runs only while all of its conditions pass ([method AIBehaviourBase.all_conditions]). A condition
## reads named numbers from the pawn's [AIInputs], never game objects, so the same check can be made in C++ for a whole crowd at
## once (AIBatchDecider). Utility AI calls these "considerations".
## [br]
## The kinds, each a Resource made in the inspector:
## [br]- [AICompareCondition]: an input against a number, or against another input
## [br]- [AIChanceCondition]: a random roll that replays the same
## [br]- [AIAnyCondition]: passes if any one of its conditions does
## [br]
## A new kind needs the same check in C++ too (native/src/ai_batch_decider.cpp), and [method describe] giving what C++ reads.
## Most needs are met by an input instead: a game writes its own input ([method AIInputs.set_input]), and a compare condition reads it.
class_name AICondition
extends Resource

## The input names the inspector suggests. Any other name works too: it's a kept input that game code writes.
const INPUT_SUGGESTIONS := "target_distance,most_aware_certain,most_aware_uncertain,ticks_since_unknown_hit,incoming_attack,incoming_attack_tick,incoming_attacker,group_distance/rally_point,group_found/rally_point,action_ready/primary"


## True if the condition passes for this pawn now. inputs holds the values worked out for this decision; behaviour_salt is the
## behaviour's own number for random rolls, so two behaviours' rolls differ.
func passes(_inputs: AIInputs, _context: AIContextComponent, _behaviour_salt: int) -> bool:
	return true


## The condition as plain data, for the C++ decider: "kind" and its numbers, with input slots ([method AIInputs.slot_of]) rather than
## names, and times already converted to the match's tick rate.
func describe() -> Dictionary:
	return {"kind": "always"}


## Adds the slots of every input this condition reads to slots (as keys), so the behaviour manager works out only those.
func add_input_slots(_slots: Dictionary) -> void:
	pass


## A value written for 60 ticks a second, at the match's rate, if the input is a time in ticks; otherwise the value as it is.
static func at_rate_for(slot: int, number: float) -> float:
	if AIInputs.is_ticks(slot):
		return float(TickDriver.ticks_at_rate(roundi(number)))
	return number
