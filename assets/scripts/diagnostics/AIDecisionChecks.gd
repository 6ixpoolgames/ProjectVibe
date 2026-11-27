# Written by Claude (claude-opus-5-5), 2026-11-26. History: diagnostics/CHANGELOG.md.
## Checks on the AI's C++ decisions, for finding faults and for tests: shadow mode, the sampled fact check, and the switch that has
## every pawn decide in GDScript (F10).
##
## Shadow mode ([method set_check_against_gdscript]): every pawn that decides in C++ decides in GDScript, C++ decides beside it, and
## the two are compared ([method get_counts]); after a disagreement C++'s copy of the state is put right. In debug builds a sampled
## check compares the facts written into a pawn's C++ row with the live ones, most often when the tick has time to spare; a
## difference means a version counter wasn't raised somewhere. All static: one set of switches and counts for every pawn.
## Design: pawn spec 16.5, scaling spec 6.2.
class_name AIDecisionChecks
extends RefCounted

## The sampled fact check's pace (debug builds), in C++ decisions between checks: with time to spare (load under half the tick's
## budget), normally, and near the budget (above 90%). It checks most when it costs least.
const FACT_CHECK_EVERY_IDLE := 20
const FACT_CHECK_EVERY := 100
const FACT_CHECK_EVERY_BUSY := 1000

## How many disagreements and out-of-date facts are logged as warnings. The rest are only counted.
static var warnings_kept := 5
## Shadow mode is on. Set it with [method set_check_against_gdscript].
static var check_against_gdscript := false
## Every pawn decides in GDScript, the backup. Set it with [method set_all_in_gdscript] (F10 in debug builds).
static var all_in_gdscript := false
## True when a C++ decision runs a check first: shadow mode, or the sampled check (debug builds).
static var active := OS.is_debug_build()

static var _counts := {"checked": 0, "agreed": 0, "differs": 0, "stale_facts": 0}
static var _decisions_since_check := 0
static var _check_every := FACT_CHECK_EVERY # set again after each check, from how busy the tick is


## Turns shadow mode on or off. Every pawn settles where it decides again at its next decision.
static func set_check_against_gdscript(on: bool) -> void:
	check_against_gdscript = on
	active = on or OS.is_debug_build()
	AIDeciderBridge.placement_changed()


## Has every pawn decide in GDScript (on), or each where its settings say (off).
static func set_all_in_gdscript(on: bool) -> void:
	all_in_gdscript = on
	AIDeciderBridge.placement_changed()


## Switches every pawn to GDScript and back (F10). Returns true if they decide in GDScript now.
static func toggle_all_in_gdscript() -> bool:
	set_all_in_gdscript(not all_in_gdscript)
	print("AIDecisionChecks: AI decisions %s (F10)." % ("all in GDScript" if all_in_gdscript else "back to C++"))
	return all_in_gdscript


## The counts so far: cpp (decisions made in C++), checked, agreed and differs (shadow mode), stale_facts, and gdscript_answers
## (answers GDScript gave for behaviours C++ can't judge).
static func get_counts() -> Dictionary:
	var counts := _counts.duplicate()
	counts["cpp"] = AIDeciderBridge.decisions
	counts["gdscript_answers"] = AIDeciderBridge.gdscript_answers
	return counts


## Starts the counts afresh.
static func reset_counts() -> void:
	for key: String in _counts:
		_counts[key] = 0
	AIDeciderBridge.decisions = 0
	AIDeciderBridge.gdscript_answers = 0


## Called before each C++ decision while [member active]: the fact check, at every decision in shadow mode and sampled otherwise.
static func before_cpp_decision(bridge: AIDeciderBridge) -> void:
	if check_against_gdscript:
		_check_facts(bridge)
		return
	_decisions_since_check += 1
	if _decisions_since_check >= _check_every:
		_decisions_since_check = 0
		_check_facts(bridge)
		var busy := TickDriver.load_average
		_check_every = FACT_CHECK_EVERY_IDLE if busy < 0.5 else (FACT_CHECK_EVERY if busy < 0.9 else FACT_CHECK_EVERY_BUSY)


## Called after each C++ decision in shadow mode: every input C++ just worked out against GDScript's own, slot by slot (the hit and
## swing facts, a game's inputs, the group points and the memory-based ones all show up here). Counted with the stale facts.
static func after_cpp_decision(bridge: AIDeciderBridge) -> void:
	var manager := bridge.manager
	var inputs := manager.pawn.ai.inputs
	var slots := manager.worked_out_inputs()
	inputs.fill(slots)
	var used := bridge.last_inputs()
	for slot in slots:
		var mine := inputs.value(slot)
		var theirs := used[slot] if slot < used.size() else 0.0
		if mine != theirs:
			_counts["stale_facts"] += 1
			if _counts["stale_facts"] <= warnings_kept:
				push_warning("AIDecisionChecks: C++ worked out %s as %s for %s, GDScript as %s." % [AIInputs.name_of(slot), theirs, manager.pawn.name, mine])
			return


## Shadow mode: compares C++'s choice with GDScript's (what runs now), counts it, and puts C++'s copy of the state right after a
## disagreement.
static func compare(manager: AIBehaviourManager, cpp_choice: int, tick: int) -> void:
	var running := manager.get_running_behaviour()
	var gd_choice := running.decision_index if running else -1
	_counts["checked"] += 1
	if cpp_choice == gd_choice:
		_counts["agreed"] += 1
		return
	_counts["differs"] += 1
	if _counts["differs"] <= warnings_kept:
		var names := manager.get_behaviour_list()
		push_warning("AIDecisionChecks: C++ disagreed at tick %d on %s: GDScript chose %s, C++ chose %s." % [tick, manager.pawn.name,
			String(running.name) if running else "nothing", String(names[cpp_choice].name) if cpp_choice >= 0 else "nothing"])
	if manager.cpp_decider:
		manager.cpp_decider.copy_state()


# The facts written into the row against the live ones; a difference means a write was missed somewhere.
static func _check_facts(bridge: AIDeciderBridge) -> void:
	var manager := bridge.manager
	var facts := bridge.written_facts()
	var context := manager.pawn.ai
	var target_id: int = facts["target_id"]
	var live_target := context.current_target.get_instance_id() if context.has_target() else 0
	var written_target := target_id if target_id != 0 and is_instance_valid(instance_from_id(target_id)) else 0
	var owned := manager.pawn.owned_tags
	var live_words := owned.get_words() if owned else PackedInt64Array()
	var disabled := 0
	for behaviour in manager.get_behaviour_list():
		if not behaviour.enabled:
			disabled |= 1 << behaviour.decision_index
	var stale: bool = facts["owned"] != live_words or written_target != live_target or facts["disabled"] != disabled
	if stale:
		_counts["stale_facts"] += 1
		if _counts["stale_facts"] <= warnings_kept:
			push_warning("AIDecisionChecks: a fact written for %s is out of date: %s." % [manager.pawn.name, str(facts)])
