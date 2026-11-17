# Written by Claude (claude-opus-5-5), 2026-11-17. History: ai/CHANGELOG.md.
## What one AI decision was made from, and what it chose: a plain record for diagnostics and for checking another decider against
## this one.
##
## The [AIBehaviourManager] fills one in after a decision, only while [member AIBehaviourManager.decision_listener] is set, and
## hands it to the listener. The [AIDecisionRecorder] keeps them and saves them to a file. Nothing in the game reads them.
## [br]
## Why it exists: the plan to make decisions in C++ on the worker threads (scaling spec 6.2) starts with a "shadow" decider that
## decides beside this one without being used. To compare the two exactly, the C++ one needs the same inputs this decision had,
## and the answer this decision gave. A record holds both:
## [br]- the reasons for deciding: [member cause], [member event_priority], [member event_is_normal]
## [br]- the situation: [member state], [member has_target], the running behaviour and when it started
## [br]- for each behaviour, in the fixed order: which hard rule ruled it out, if any, and otherwise its persistence, jitter,
##   ceiling and floor, whether is_available() was asked and what it said, and its score if it was scored
## [br]- the answer: [member chosen]
## [br]
## Behaviours the early stop skipped show [code]available = -1[/code] (never asked). A decider that matches asks the same ones.
## [br]
## How to read one:
## [codeblock]
## record.chosen                              # &"Chase", or &"" for nothing
## record.behaviours[0]["name"]               # each entry is a Dictionary, see add_behaviour()
## record.to_dict()                           # everything as plain values, for saving as JSON
## [/codeblock]
class_name AIDecisionRecord
extends RefCounted

## Why the decision happened: the pawn's AI step (a decision tick, or an event such as a hit or a state change).
const CAUSE_AI_STEP := &"ai_step"
## Why: the running behaviour finished (SUCCEEDED or FAILED), which decides at once, with no target or state update first.
const CAUSE_BEHAVIOUR_ENDED := &"behaviour_ended"
## Why: something called [method AIBehaviourManager.decide] itself, such as a test.
const CAUSE_DIRECT := &"direct"

## A hard rule that ruled a behaviour out before any of its own code ran (pawn spec 10.8 step 2). None: it was a candidate.
const RULE_NONE := &""
## Not allowed in the current state.
const RULE_STATE := &"state"
## Cooling down.
const RULE_COOLDOWN := &"cooldown"
## Needs a target, and there's none.
const RULE_NO_TARGET := &"no_target"
## Its action couldn't start (AbilityManager.can_start).
const RULE_ACTION := &"action"

## The tick of the decision.
var tick := 0
## The pawn's own number ([method AIContextComponent.pawn_number]), which also goes into its random numbers.
var pawn_number := 0
## The pawn's node name, for reading.
var pawn_name: StringName = &""
## Why it decided: one of the CAUSE_ constants.
var cause: StringName = CAUSE_DIRECT
## The strongest reason's priority (pawn spec 10.7).
var event_priority := 0
## True when every reason was an ordinary decision tick, the one kind min_run_ticks holds off.
var event_is_normal := true

## The target before and after the target selector's update, as instance ids (0: none) and names. Only for [constant CAUSE_AI_STEP];
## otherwise both are what it was.
var target_before_id := 0
var target_before_name: StringName = &""
var target_after_id := 0
var target_after_name: StringName = &""
## The state before and after the state manager's update. Only for [constant CAUSE_AI_STEP].
var state_before: StringName = &""
var state_after: StringName = &""

## The state the behaviours were judged in.
var state: StringName = &""
## True if there was a target when the behaviours were judged.
var has_target := false
## The behaviour running before the decision (&"": none), and the tick it started (-1: none).
var running_before: StringName = &""
var running_started_tick := -1
## True when the running behaviour couldn't be replaced for this reason (step 0), so no behaviour was looked at.
var kept_by_interrupt := false
## One Dictionary per behaviour, in the manager's fixed order. Empty when [member kept_by_interrupt]. See [method add_behaviour].
var behaviours: Array[Dictionary] = []
## The pawn's AI inputs as this decision worked them out ([member AIInputs.values]), by slot: what the behaviours' conditions read.
var inputs := PackedFloat64Array()
## What runs after the decision: a behaviour's name, or &"" for nothing.
var chosen: StringName = &""


## Notes the target before the selector's update.
func note_target_before(target: Node3D) -> void:
	target_before_id = target.get_instance_id() if is_instance_valid(target) else 0
	target_before_name = target.name if is_instance_valid(target) else &""
	target_after_id = target_before_id # the same until the update says otherwise
	target_after_name = target_before_name


## Notes the target after the selector's update.
func note_target_after(target: Node3D) -> void:
	target_after_id = target.get_instance_id() if is_instance_valid(target) else 0
	target_after_name = target.name if is_instance_valid(target) else &""


## True when the running behaviour changed.
func changed() -> bool:
	return chosen != running_before


## Adds one behaviour's entry, from the scratch values the manager left on it this decision. rule: the hard rule that ruled it out,
## or [constant RULE_NONE]. The entry's keys:
## [br]- [code]name[/code], [code]rule[/code]
## [br]- for a candidate (no rule): [code]persistence[/code], [code]jitter[/code], [code]ceiling[/code], [code]floor[/code]
##   (null for no floor), [code]available[/code] (1 yes, 0 no, -1 never asked), [code]score[/code] (null when not scored)
func add_behaviour(behaviour: AIBehaviourBase, rule: StringName) -> void:
	var entry := {"name": behaviour.name, "rule": rule}
	if rule == RULE_NONE:
		entry["persistence"] = behaviour.decision_persistence
		entry["jitter"] = behaviour.decision_jitter
		entry["ceiling"] = behaviour.decision_ceiling
		entry["floor"] = behaviour.decision_floor if behaviour.decision_floor > -INF else null # JSON has no infinity
		entry["available"] = (1 if behaviour.decision_available else 0) if behaviour.availability_checked else -1
		entry["score"] = behaviour.decision_score if behaviour.decision_scored else null
	behaviours.append(entry)


## The entry for this behaviour, or an empty Dictionary.
func entry_for(behaviour_name: StringName) -> Dictionary:
	for entry in behaviours:
		if entry["name"] == behaviour_name:
			return entry
	return {}


## Everything as plain values (text, numbers, arrays, dictionaries), ready for JSON.
func to_dict() -> Dictionary:
	var entries: Array = []
	for entry in behaviours:
		var plain := entry.duplicate()
		plain["name"] = String(entry["name"])
		plain["rule"] = String(entry["rule"])
		entries.append(plain)
	return {
		"tick": tick, "pawn_number": pawn_number, "pawn": String(pawn_name), "cause": String(cause),
		"event_priority": event_priority, "event_is_normal": event_is_normal,
		"target_before": target_before_id, "target_before_name": String(target_before_name),
		"target_after": target_after_id, "target_after_name": String(target_after_name),
		"state_before": String(state_before), "state_after": String(state_after),
		"state": String(state), "has_target": has_target,
		"running_before": String(running_before), "running_started_tick": running_started_tick,
		"kept_by_interrupt": kept_by_interrupt, "behaviours": entries, "chosen": String(chosen),
		"inputs": Array(inputs),
	}
