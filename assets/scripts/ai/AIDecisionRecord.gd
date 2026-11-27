# Written by Claude (claude-opus-5-5), 2026-11-17. History: ai/CHANGELOG.md.
## What one AI decision was made from, and what it chose: a plain record for diagnostics and for checking another decider.
##
## The [AIBehaviourManager] fills one in after each decision, only while [member AIBehaviourManager.decision_listener] is set; the
## [AIDecisionRecorder] keeps and saves them. It holds the reasons, the situation, each behaviour's hard rule, range, availability and
## score in the fixed order, and the choice. Behaviours the early stop skipped show [code]available = -1[/code]. Nothing in the game
## reads records.
## [codeblock]
## record.chosen                              # &"Chase", or &"" for nothing
## record.behaviours[0]["name"]               # each entry is a Dictionary, see add_behaviour()
## record.to_dict()                           # everything as plain values, for saving as JSON
## [/codeblock]
## Design: scaling spec 6.2.
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
## Its tag requirements failed for the pawn's owned tags (the AI's state is one of them).
const RULE_TAGS := &"tags"
## Switched off ([member AIBehaviourBase.enabled]).
const RULE_OFF := &"off"
## A behaviour modifier blocks it.
const RULE_BLOCKED := &"blocked"
## Cooling down.
const RULE_COOLDOWN := &"cooldown"
## Needs a target, and there's none.
const RULE_NO_TARGET := &"no_target"
## Its action couldn't start (AbilityManager.can_start). Asked on the walk, after its availability, so it's still a candidate.
const RULE_ACTION := &"action"
## Passed the hard rules, but C++ made the decision, so GDScript's range, availability and score weren't worked out.
const RULE_NOT_WORKED_OUT := &"cpp"
## The running behaviour the interrupt rule kept: only its numbers, which the rule read (its threshold and minimum run).
const RULE_KEPT := &"kept"

## The tick of the decision.
var tick := 0
## The pawn's own number ([method AIManager.pawn_number]), which also goes into its random numbers.
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
## The tags the pawn owned when the behaviours were judged (without their parents), sorted.
var owned_tags: Array[StringName] = []
## True if there was a target when the behaviours were judged.
var has_target := false
## The behaviour running before the decision (&"": none), and the tick it started (-1: none).
var running_before: StringName = &""
var running_started_tick := -1
## True when the running behaviour couldn't be replaced for this reason (step 0), so no behaviour was looked at.
var kept_by_interrupt := false
## One Dictionary per behaviour, in the manager's fixed order; only the running one's ([constant RULE_KEPT]) when
## [member kept_by_interrupt]. See [method add_behaviour].
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


## One behaviour's entry, from the manager's scratch values; rule: what ruled it out, or [constant RULE_NONE]. Keys: name, rule, and its
## numbers with modifiers (score_multiply and score_add: what its score gets; jitter_amount, interrupt_threshold, min_run at the
## match's rate); a candidate's also jitter (this decision's offset), key (its result, null for a score() of its own), available
## (1, 0, -1 never asked) and score (before modifiers; null: not reached). A behaviour whose action couldn't start
## ([constant RULE_ACTION]) was still a candidate, asked on the walk, so its entry has them too.
func add_behaviour(behaviour: AIBehaviourBase, rule: StringName) -> void:
	behaviour.work_out_change(AIBehaviourModifier.Number.SCORE)
	var entry := {"name": behaviour.name, "rule": rule, "score_multiply": behaviour.change_multiply, "score_add": behaviour.change_add,
		"jitter_amount": behaviour.current_jitter(), "interrupt_threshold": behaviour.current_interrupt_threshold(),
		"min_run": behaviour.current_min_run_ticks()}
	if rule == RULE_NONE or rule == RULE_ACTION:
		entry["jitter"] = behaviour.decision_jitter
		entry["key"] = null if behaviour.decision_key == INF else behaviour.decision_key # JSON has no infinity
		entry["available"] = (1 if behaviour.decision_available else 0) if behaviour.availability_checked else -1
		entry["score"] = null
		if behaviour.decision_scored:
			entry["score"] = behaviour.decision_score
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
		"state": String(state), "owned_tags": _names(owned_tags), "has_target": has_target,
		"running_before": String(running_before), "running_started_tick": running_started_tick,
		"kept_by_interrupt": kept_by_interrupt, "behaviours": entries, "chosen": String(chosen),
		"inputs": Array(inputs),
	}


static func _names(tags: Array[StringName]) -> Array:
	var out: Array = []
	for tag in tags:
		out.append(String(tag))
	return out
