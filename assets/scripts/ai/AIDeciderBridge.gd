# Written by Claude (claude-opus-5-5), 2026-11-26. History: ai/CHANGELOG.md.
## Links one pawn's [AIBehaviourManager] to its C++ decider ([code]AIDecider[/code], the main path): keeps the decider's row up to date
## and asks it for each decision.
##
## The manager makes one ([method make_for]) when the pawn decides in C++, and drops it when it moves to GDScript. Before each decision
## it reads the version counters of the facts the row holds and copies only what changed: the owned tags (the AI's state among them),
## the behaviour modifiers, which behaviours are switched on, the AI's facts ([member AIManager.facts_version]: target, last hit, the
## swing coming) and a game's inputs ([member AIInputs.kept_version]). What only GDScript can answer, C++ asks as it reaches it,
## through one callback ([method answer]): whether a behaviour's action could start, a scripted behaviour's is_available() and score(),
## and the inputs GDScript works out (action_ready, a group's nearest point). Brains are compiled once per behaviour set and shared by
## every decider. Where pawns decide: [member AIBehaviourManager.decides_in], the project setting [constant ALL_IN_GDSCRIPT_SETTING],
## and diagnostics' switches ([AIDecisionChecks]). Timed as [code]ai.decide.cpp[/code]. Design: pawn spec 16.5, scaling spec 6.2.
class_name AIDeciderBridge
extends RefCounted

## The project setting that has every pawn decide in GDScript, the backup (false: each pawn's own decides_in).
const ALL_IN_GDSCRIPT_SETTING := "project_base/ai/all_decisions_in_gdscript"
## What C++ asks through [method answer]. The same numbers in ai_decider.h.
enum Ask {
	COULD_PRESS, ## could the behaviour's action start (1 or 0)
	AVAILABLE, ## its is_available() (1 or 0)
	SCORE, ## its score() (before modifiers)
	INPUT, ## an input GDScript works out, by slot
}

## The decisions made in C++ so far, by every pawn.
static var decisions := 0
## The answers GDScript gave so far to C++'s questions about behaviours (could its action start, is it available, its score).
static var gdscript_answers := 0

## The C++ AIDecider, holding this pawn's row. Typed Object so the game runs without the library.
var decider: Object = null
## The behaviour manager it decides for.
var manager: AIBehaviourManager = null

var _row := -1
var _tags_version := -1
var _modifiers_version := -1
var _enabled_version := -1
var _facts_version := -1
var _kept_version := -1

static var _library := ClassDB.class_exists(&"AIDecider")
static var _warned := {} # a reason -> true, so each is said once
static var _kinds_sent := -1 # how many input slots' kinds the decider has (shared by every decider, as in C++)
static var _setting_read := false
static var _setting_all_in_gdscript := false
static var _placement_version := 0
static var _tag_generation := -1
static var _tag_count := -1


## A bridge for this manager, or null if it decides in GDScript.
static func make_for(for_manager: AIBehaviourManager) -> AIDeciderBridge:
	if _gdscript_reason(for_manager) != "":
		return null
	var made := AIDeciderBridge.new(for_manager)
	return made if made._row >= 0 else null


## Where pawns decide changes when this does: diagnostics' switches, the tags the brains' masks were made with. A manager places
## itself again when it differs from what it last saw.
static func placement_version() -> int:
	# A tag added late (one nobody declared) or a registry reset can change the bits the brains' tag requirements were compiled to,
	# so every pawn compiles its brain again. Rare; declared tags never cause it.
	if TagRegistry.generation != _tag_generation or TagRegistry.get_tag_count() != _tag_count:
		_tag_generation = TagRegistry.generation
		_tag_count = TagRegistry.get_tag_count()
		_placement_version += 1
	return _placement_version


## Every pawn settles where it decides again at its next decision.
static func placement_changed() -> void:
	_placement_version += 1


## The brain's key: its description without what's the pawn's own (its name, number, seed, decision rate, which behaviours are
## switched on), as text. Not the definitions' ids alone: a behaviour's own conditions can come from the pawn's abilities (Attack's
## reach), so two pawns with the same definitions can need different brains.
static func brain_key(description: Dictionary) -> String:
	var shared := description.duplicate()
	for own: String in ["pawn", "pawn_number", "random_seed", "decision_interval_ticks"]:
		shared.erase(own)
	var behaviours: Array = []
	for entry: Dictionary in description.get("behaviours", []):
		var plain := entry.duplicate()
		plain.erase("enabled")
		behaviours.append(plain)
	shared["behaviours"] = behaviours
	return JSON.stringify(shared, "", true, true)


func _init(for_manager: AIBehaviourManager) -> void:
	manager = for_manager
	decider = ClassDB.instantiate(&"AIDecider")
	var description := manager.describe()
	var brain: int = decider.add_brain(description, brain_key(description)) # -1, with an error, past 64 behaviours
	if brain < 0:
		return
	var pawn := manager.pawn
	var context := pawn.ai
	_row = decider.add_pawn(manager.get_instance_id(), brain, pawn.entity_number(), context.effective_seed())
	if _row < 0:
		return
	copy_state()
	decider.set_body(_row, pawn.get_instance_id(), context.memory.native_store())
	decider.set_asker(_row, answer)


## One decision in C++: copies over the facts that changed, asks the decider, and returns the chosen behaviour's slot (-1 nothing).
## C++ applies the switch to its own copy of the state; the manager starts the behaviour.
func decide(tick: int, event_priority: int, event_normal: bool) -> int:
	var started := PerfScopes.begin()
	if AIInputs.input_count() != _kinds_sent:
		_kinds_sent = AIInputs.input_count()
		decider.set_input_kinds(AIInputs.kinds())
	var writing := PerfScopes.begin_detailed() # the parts timed on their own, in detail: copying facts, and C++ deciding
	_write_changed()
	PerfScopes.end(&"ai.decide.cpp.write", writing)
	if AIDecisionChecks.active:
		AIDecisionChecks.before_cpp_decision(self)
	var deciding := PerfScopes.begin_detailed() # includes the answers GDScript gives on the way
	var chosen: int = decider.decide_pawn(_row, tick, event_priority, event_normal)
	PerfScopes.end(&"ai.decide.cpp.native", deciding)
	if AIDecisionChecks.check_against_gdscript:
		AIDecisionChecks.after_cpp_decision(self)
	decisions += 1
	PerfScopes.end(&"ai.decide.cpp", started)
	return chosen


## C++'s questions during a decision, by [enum Ask] and the behaviour's slot (or, for an input, its slot). Only for behaviours still
## in the running, so a behaviour's code runs only when GDScript's own decider would run it.
func answer(what: int, slot: int) -> float:
	var context := manager.pawn.ai
	if what == Ask.INPUT:
		return context.inputs.value(slot)
	gdscript_answers += 1
	var behaviour: AIBehaviourBase = manager.get_behaviour_list()[slot]
	match what:
		Ask.COULD_PRESS:
			return 1.0 if context.inputs.action_ready(behaviour.settings.presses_action) else 0.0
		Ask.AVAILABLE:
			var started := PerfScopes.begin_detailed()
			var available := behaviour.is_available(context)
			PerfScopes.end(behaviour.perf_available_name, started)
			return 1.0 if available else 0.0
		Ask.SCORE:
			return behaviour.score(context)
	return 0.0


## Whether the interrupt rule kept the running behaviour at the last decision.
func was_kept() -> bool:
	return decider.was_kept()


## Copies the decision state from the behaviour nodes (running behaviour, its start, each one's last end) over C++'s: as it starts,
## and after shadow mode finds a disagreement.
func copy_state() -> void:
	var running := manager.get_running_behaviour()
	var ended := PackedInt64Array()
	for behaviour in manager.get_behaviour_list():
		ended.append(behaviour.ended_tick)
	decider.set_pawn_state(_row, running.decision_index if running else -1, running.started_tick if running else -1, ended)


## The running behaviour stopped without a decision (finished, died, removed): C++'s copy of the state follows.
func stopped(tick: int) -> void:
	decider.stop_running(_row, tick)


## The facts as written into the row (owned, target_id, blocked, disabled), for the checks.
func written_facts() -> Dictionary:
	return decider.get_facts(_row)


## The inputs the last decision read, as C++ worked them out, with the rest worked out now, for the checks.
func last_inputs() -> PackedFloat64Array:
	return decider.get_last_inputs()


# --- Internals ---


# Copies what changed since the last decision, read through each fact's version counter.
func _write_changed() -> void:
	var pawn := manager.pawn
	var context := pawn.ai
	var owned := pawn.owned_tags
	var tags_version := owned.version if owned else 0
	if tags_version != _tags_version:
		_tags_version = tags_version
		decider.set_owned_tags(_row, owned.get_words() if owned else PackedInt64Array())
	if manager.modifiers_version != _modifiers_version:
		_write_modifiers()
	if manager.enabled_version != _enabled_version:
		_enabled_version = manager.enabled_version
		var disabled := 0
		for behaviour in manager.get_behaviour_list():
			if not behaviour.enabled:
				disabled |= 1 << behaviour.decision_index
		decider.set_disabled(_row, disabled)
	if context.facts_version != _facts_version:
		_facts_version = context.facts_version
		_write_facts(context)
	var inputs := context.inputs
	if inputs.kept_version != _kept_version:
		_kept_version = inputs.kept_version
		for slot in mini(AIInputs.input_count(), inputs.values.size()):
			if AIInputs.kind_of(slot) == AIInputs.Kind.KEPT:
				decider.set_input(_row, slot, inputs.values[slot])


# The target, the last hit and the swing coming at it: what C++ works the built-in inputs out from.
func _write_facts(context: AIManager) -> void:
	var target := context.current_target
	decider.set_target(_row, target.get_instance_id() if is_instance_valid(target) else 0)
	decider.note_hit(_row, context.last_hit_tick,
		context.last_attacker.get_instance_id() if is_instance_valid(context.last_attacker) else 0)
	var attacker := context.incoming_attacker
	var valid := is_instance_valid(attacker)
	decider.note_incoming(_row, attacker.get_instance_id() if valid else 0, EntityNumber.of(attacker) if valid else EntityNumber.NONE,
		context.incoming_start_tick, context.incoming_hit_tick)


# What the behaviour modifiers do, as the decider reads it: each behaviour's fixed changes (multiply, add, override value or NaN, for
# each number), the live curves in the order added (each with a mask of the behaviours it counts for), and the blocks.
func _write_modifiers() -> void:
	_modifiers_version = manager.modifiers_version
	var behaviours := manager.get_behaviour_list()
	var changes := PackedFloat64Array()
	var blocked := 0
	var any_change := false
	for behaviour in behaviours:
		if not behaviour.modifier_changes.is_empty():
			any_change = true
		if behaviour.decision_blocked:
			blocked |= 1 << behaviour.decision_index
	# The live curves in the order added (each behaviour's own list keeps that order, so C++ multiplies in the same order), each with
	# the behaviours it counts for. By identity: two modifiers alike are still two.
	var described: Array = []
	for modifier_entry in manager.get_modifiers():
		var curved: Variant = modifier_entry["curved"]
		if curved == null:
			continue
		var mask := 0
		for behaviour in behaviours:
			for entry in behaviour.curved_modifiers:
				if is_same(entry, curved):
					mask |= 1 << behaviour.decision_index
					break
		if mask != 0:
			var entry: Dictionary = curved.duplicate()
			entry["mask"] = mask
			described.append(entry)
	if any_change:
		for behaviour in behaviours:
			for number in AIBehaviourModifier.Number.size():
				if behaviour.modifier_changes.is_empty():
					changes.append_array([1.0, 0.0, NAN])
				else:
					var change := behaviour.modifier_changes[number]
					changes.append_array([change[0], change[1], change[3] if change[2] != 0.0 else NAN])
	decider.set_modifiers(_row, changes, described, blocked)


# Why this pawn decides in GDScript, or "" if it can decide in C++.
static func _gdscript_reason(for_manager: AIBehaviourManager) -> String:
	if for_manager.pawn == null or for_manager.pawn.ai == null or for_manager.get_behaviour_list().is_empty():
		return "no AI"
	if not _library:
		if not _warned.has("library"):
			_warned["library"] = true
			push_warning("AIDeciderBridge: the navcore library has no AIDecider, so every pawn decides in GDScript.")
		return "no C++ library"
	if AIDecisionChecks.all_in_gdscript:
		return "diagnostics' switch (F10)"
	if not _setting_read:
		_setting_read = true
		_setting_all_in_gdscript = bool(ProjectSettings.get_setting(ALL_IN_GDSCRIPT_SETTING, false))
	if _setting_all_in_gdscript:
		return "the project setting"
	if for_manager.decides_in == AIBehaviourManager.DecidesIn.GDSCRIPT:
		return "its own setting"
	var memory := for_manager.pawn.ai.memory
	if memory == null or memory.native_store() == null:
		return "the GDScript memory store" # a fade with its own value_at()
	return ""
