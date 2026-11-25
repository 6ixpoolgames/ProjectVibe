# Written by Claude (claude-opus-5-5), 2026-11-17. History: ai/CHANGELOG.md.
## Makes the AI's behaviour decisions in C++ (the main path) and decides which pawns use GDScript's decider (the backup).
##
## A GameMode module ([code]GameMode.get_module(AIDecisionModule)[/code]). It holds the C++ decider ([code]AIBatchDecider[/code]): one
## brain per behaviour set, and each pawn's row (its decision state and the facts a decision is made from). A pawn deciding in C++
## asks it for each decision ([method decide_in_cpp]) and its [AIBehaviourManager] starts the chosen behaviour. Without this module,
## or without the C++ library, every pawn decides in GDScript. Facts are written into the row when they change; at a decision only the actions
## that could start and a group's nearest point are written, and only when changed. [member check_against_gdscript] is shadow mode: GDScript decides, C++ decides beside it, and the two are compared
## ([method get_counts]). In debug builds F10 switches every pawn to GDScript and back, and a sampled check warns when a written fact
## is out of date. Timed as [code]ai.decide.cpp[/code] ([PerfScopes]).
## Design: scaling spec 6.2, steps 5c and 5d.
class_name AIDecisionModule
extends GameModeModule

## Where pawns decide, for every pawn at once.
enum Decider {
	PAWN_SETTING, ## each pawn's own decides_in (C++ by default)
	ALL_CPP, ## every pawn in C++ (special minds and a missing library still use GDScript)
	ALL_GDSCRIPT, ## every pawn in GDScript, the backup
}

## Where pawns decide. Changing it moves every pawn at once.
@export var decider := Decider.PAWN_SETTING:
	set(value):
		decider = value
		_place_all()
## Shadow mode: every pawn decides in GDScript, and C++ decides beside it and is checked. For tests and finding faults.
@export var check_against_gdscript := false:
	set(value):
		check_against_gdscript = value
		_place_all()
## How many disagreements (shadow mode) are logged as warnings. The rest are only counted.
@export_range(0, 100, 1, "or_greater") var warnings_kept := 5

const KNOWN_CONDITION_KINDS := ["always", "compare", "chance", "any"] # the kinds AIBatchDecider reads
## The sampled fact check's pace (debug builds), in C++ decisions between checks: with time to spare (load under half the tick's
## budget), normally, and near the budget (above 90%). It checks most when it costs least.
const FACT_CHECK_EVERY_IDLE := 20
const FACT_CHECK_EVERY := 100
const FACT_CHECK_EVERY_BUSY := 1000

var _decider: Object = null # the C++ AIBatchDecider, null without the library
var _warned_no_library := false
var _brain_of_manager := {} # behaviour manager instance id -> brain number
var _brain_by_text := {} # a brain's shared description as text -> brain number
var _managers := {} # instance id -> the behaviour managers it has placed, to move them when decider changes
var _warned_minds := {} # a special mind's reason -> true, so each is said once
var _previous_decider := Decider.PAWN_SETTING # what F10 goes back to
var _counts := {"cpp": 0, "checked": 0, "agreed": 0, "differs": 0, "special_minds": 0, "stale_facts": 0}
var _kinds_sent := 0 # how many input slots' kinds C++ has
var _tripwire := OS.is_debug_build() # the sampled fact check runs in debug builds only
var _decisions_since_check := 0
var _check_every := FACT_CHECK_EVERY # set again after each check, from how busy the tick is
var _tag_generation := -1 # TagRegistry's generation and tag count the brains' tag masks were made with
var _tag_count := -1
var _rows := {} # manager instance id -> {ready_version, ready_slots, groups, follows_body, tags_version, modifiers_version}: kept per pawn


func _init() -> void:
	name = "AIDecisionModule"
	set_process(false)
	set_physics_process(false)
	if ClassDB.class_exists(&"AIBatchDecider"):
		_decider = ClassDB.instantiate(&"AIBatchDecider")


func _on_module_added(_game_mode: GameModeSingleton) -> void:
	AIBehaviourManager.decision_module = self
	_place_all()


func _on_module_removed(_game_mode: GameModeSingleton) -> void:
	if AIBehaviourManager.decision_module == self:
		AIBehaviourManager.decision_module = null
	for id: int in _managers.keys():
		var manager := instance_from_id(id) as AIBehaviourManager
		if manager:
			manager.cpp_row = -1 # back to GDScript
	_managers.clear()


func get_match_options() -> PackedStringArray:
	return PackedStringArray(["decider"])


## The counts so far: cpp (decisions made in C++), checked, agreed and differs (shadow mode), special_minds (pawns kept in GDScript
## because C++ can't read them).
func get_counts() -> Dictionary:
	return _counts.duplicate()


## Starts the counts afresh.
func reset_counts() -> void:
	for key: String in _counts:
		_counts[key] = 0



# --- Called by the behaviour manager ---


## Settles where this pawn decides: a C++ row ([member AIBehaviourManager.cpp_row]), or -1 for GDScript. Called when it first decides
## and when something it depends on changes. A pawn moving into C++ brings its state from its behaviour nodes.
func place(manager: AIBehaviourManager) -> void:
	var id := manager.get_instance_id()
	_managers[id] = true
	var reason := _gdscript_reason(manager)
	if reason != "":
		_forget_row(manager)
		if reason.begins_with("special mind") and not _warned_minds.has(reason):
			_warned_minds[reason] = true
			_counts["special_minds"] += 1
			push_warning("AIDecisionModule: %s decides in GDScript: %s." % [String(manager.pawn.name) if manager.pawn else "a pawn", reason])
		return
	var brain := _brain_for(manager)
	if brain < 0:
		_forget_row(manager)
		return
	var context := manager.pawn.ai
	var row: int = _decider.add_pawn(id, brain, manager.pawn.entity_number(), context.effective_seed())
	if row < 0:
		_forget_row(manager)
		return
	# Its state as the behaviour nodes hold it, so moving in changes nothing.
	var running := manager.get_running_behaviour()
	var ended := PackedInt64Array()
	for behaviour in manager.get_behaviours():
		ended.append(behaviour.ended_tick)
	_decider.set_pawn_state(row, running.decision_index if running else -1, running.started_tick if running else -1, ended)
	manager.cpp_row = row
	# The facts, as they are now; from here on each is written when it changes.
	_decider.set_body(row, manager.pawn.get_instance_id(), context.memory.native_store())
	var groups: Array = [] # [group, distance slot, found slot] for each group the conditions read
	var ready_slots := PackedInt32Array() # action_ready slots the conditions read
	var by_group := {}
	for slot in manager.worked_out_inputs():
		var kind := AIInputs.kind_of(slot)
		if kind == AIInputs.Kind.GROUP_DISTANCE or kind == AIInputs.Kind.GROUP_FOUND:
			var group := AIInputs.parameter_of(slot)
			if not by_group.has(group):
				by_group[group] = [group, -1, -1]
				groups.append(by_group[group])
			by_group[group][1 if kind == AIInputs.Kind.GROUP_DISTANCE else 2] = slot
		elif kind == AIInputs.Kind.ACTION_READY:
			ready_slots.append(slot)
	var abilities := manager.pawn.ability_manager
	_rows[id] = {"ready_version": -1, "ready_slots": ready_slots, "groups": groups, "tags_version": -1, "modifiers_version": -1,
		"follows_body": abilities != null and _follows_body(manager, abilities)}
	_write_owned_tags(manager, _rows[id])
	_write_modifiers(manager, _rows[id])
	target_changed(manager)
	facts_changed(manager)
	for slot in AIInputs.input_count():
		if AIInputs.kind_of(slot) == AIInputs.Kind.KEPT and slot < context.inputs.values.size():
			_decider.set_input(row, slot, context.inputs.values[slot])


## The pawn's target changed (the context's current_target setter).
func target_changed(manager: AIBehaviourManager) -> void:
	if manager.cpp_row < 0:
		return
	var target := manager.pawn.ai.current_target
	_decider.set_target(manager.cpp_row, target.get_instance_id() if is_instance_valid(target) else 0)


## One of the pawn's own inputs changed (AIInputs.set_input).
func input_set(manager: AIBehaviourManager, slot: int, value: float) -> void:
	if manager.cpp_row >= 0:
		_decider.set_input(manager.cpp_row, slot, value)


## The facts C++ works the pawn's inputs out from (its last hit, the swing coming at it) changed: copies them over.
func facts_changed(manager: AIBehaviourManager) -> void:
	var context := manager.pawn.ai
	_decider.note_hit(manager.cpp_row, context.last_hit_tick,
		context.last_attacker.get_instance_id() if is_instance_valid(context.last_attacker) else 0)
	var attacker := context.incoming_attacker
	var valid := is_instance_valid(attacker)
	_decider.note_incoming(manager.cpp_row, attacker.get_instance_id() if valid else 0, EntityNumber.of(attacker) if valid else EntityNumber.NONE,
		context.incoming_start_tick, context.incoming_hit_tick)


## Forgets a pawn leaving the game.
func forget(manager: AIBehaviourManager) -> void:
	_forget_row(manager)
	_managers.erase(manager.get_instance_id())
	_brain_of_manager.erase(manager.get_instance_id())



## One decision for this pawn in C++: gathers its facts and inputs, asks C++, and returns the chosen behaviour's slot (-1 nothing).
## C++ applies the switch to its own copy of the state; the manager starts the behaviour.
func decide_in_cpp(manager: AIBehaviourManager, tick: int, event_priority: int, event_normal: bool) -> int:
	var started := PerfScopes.begin()
	# A tag added late (one nobody declared) or a registry reset can change the bits the brains' tag requirements were compiled to:
	# describe every brain again. Rare; declared tags never cause it.
	if TagRegistry.generation != _tag_generation or TagRegistry.get_tag_count() != _tag_count:
		_tag_generation = TagRegistry.generation
		_tag_count = TagRegistry.get_tag_count()
		_brain_by_text.clear()
		_place_all()
	var row := manager.cpp_row
	var kept: Dictionary = _rows[manager.get_instance_id()]
	if AIInputs.input_count() != _kinds_sent:
		_kinds_sent = AIInputs.input_count()
		_decider.set_input_kinds(AIInputs.kinds())
	# Written here, not by their owner, and only when changed: the owned tags (OwnedTags.version, the AI's state among them), what the
	# behaviour modifiers leave (modifiers_version), the actions that could start (once the AbilityManager's readiness_version moves on), and a
	# group's nearest point (when the lookup, every 2 seconds, finds another).
	var owned := manager.pawn.owned_tags
	if owned and owned.version != kept["tags_version"]:
		_write_owned_tags(manager, kept)
	if manager.modifiers_version != kept["modifiers_version"]:
		_write_modifiers(manager, kept)
	var abilities := manager.pawn.ability_manager
	if abilities and (abilities.readiness_version != kept["ready_version"] or kept["follows_body"]):
		kept["ready_version"] = abilities.readiness_version
		_write_readiness(manager, kept)
	if not kept["groups"].is_empty():
		_write_group_points(manager, kept, tick)
	if check_against_gdscript:
		_check_facts(manager)
	elif _tripwire:
		_decisions_since_check += 1
		if _decisions_since_check >= _check_every:
			_decisions_since_check = 0
			_check_facts(manager)
			var busy := TickDriver.load_average
			_check_every = FACT_CHECK_EVERY_IDLE if busy < 0.5 else (FACT_CHECK_EVERY if busy < 0.9 else FACT_CHECK_EVERY_BUSY)
	var chosen: int = _decider.decide_pawn(row, tick, event_priority, event_normal)
	if check_against_gdscript:
		_check_inputs(manager)
	_counts["cpp"] += 1
	PerfScopes.end(&"ai.decide.cpp", started)
	return chosen


## Whether the interrupt rule kept the running behaviour at the last C++ decision.
func was_kept() -> bool:
	return _decider.was_kept() if _decider else false


## Shadow mode: compares C++'s answer with GDScript's (what runs now), counts it, and puts C++'s copy of the state right after a
## disagreement.
func compare(manager: AIBehaviourManager, cpp_choice: int, tick: int) -> void:
	var running := manager.get_running_behaviour()
	var gd_choice := running.decision_index if running else -1
	_counts["checked"] += 1
	if cpp_choice == gd_choice:
		_counts["agreed"] += 1
		return
	_counts["differs"] += 1
	if _counts["differs"] <= warnings_kept:
		var names := manager.get_behaviour_list()
		push_warning("AIDecisionModule: C++ disagreed at tick %d on %s: GDScript chose %s, C++ chose %s." % [tick, manager.pawn.name,
			String(running.name) if running else "nothing", String(names[cpp_choice].name) if cpp_choice >= 0 else "nothing"])
	place(manager) # copies GDScript's state over C++'s


# --- Events the manager passes on, so C++'s copy of the state follows the game ---


## The running behaviour stopped without a decision (finished, died, removed).
func stopped(manager: AIBehaviourManager, tick: int) -> void:
	_decider.stop_running(manager.cpp_row, tick)


# --- Internals ---


# The behaviours whose action could start now, as a mask by behaviour slot.
static func _can_press_mask(manager: AIBehaviourManager, inputs: AIInputs) -> int:
	var mask := 0
	for behaviour in manager.get_behaviour_list():
		if behaviour.presses_action != &"" and inputs.action_ready(behaviour.presses_action):
			mask |= 1 << behaviour.decision_index
	return mask


# The actions that could start, as a mask by behaviour slot, and any action_ready inputs the conditions read.
func _write_readiness(manager: AIBehaviourManager, kept: Dictionary) -> void:
	var inputs := manager.pawn.ai.inputs
	_decider.set_can_press(manager.cpp_row, _can_press_mask(manager, inputs))
	for slot: int in kept["ready_slots"]:
		_decider.set_input(manager.cpp_row, slot, inputs.value(slot))


# Each group's nearest point, where it is now. The node is kept 2 seconds but checked at every call (as GDScript's reading does), and
# a point can move (one carried by a hero), so its position goes over at every decision.
func _write_group_points(manager: AIBehaviourManager, kept: Dictionary, tick: int) -> void:
	var inputs := manager.pawn.ai.inputs
	for group: Array in kept["groups"]:
		var point := inputs.nearest_in_group(group[0], tick)
		_decider.set_group_point(manager.cpp_row, group[1], group[2], point != null, point.global_position if point else Vector3.ZERO)


# True if an action a behaviour presses has an ability whose readiness follows the body (Jump), so it's asked every time.
func _follows_body(manager: AIBehaviourManager, abilities: AbilityManager) -> bool:
	for behaviour in manager.get_behaviour_list():
		if behaviour.presses_action != &"" and abilities.ready_follows_body(behaviour.presses_action):
			return true
	return false


func _write_owned_tags(manager: AIBehaviourManager, kept: Dictionary) -> void:
	var owned := manager.pawn.owned_tags
	kept["tags_version"] = owned.version if owned else 0
	_decider.set_owned_tags(manager.cpp_row, owned.get_words() if owned else PackedInt64Array())


# What the behaviour modifiers leave, as the numbers the decider uses (the ticks at the match's rate).
func _write_modifiers(manager: AIBehaviourManager, kept: Dictionary) -> void:
	kept["modifiers_version"] = manager.modifiers_version
	var bonus := PackedFloat64Array()
	var jitter := PackedFloat64Array()
	var threshold := PackedInt64Array()
	var cooldown := PackedInt64Array()
	var min_run := PackedInt64Array()
	var blocked := 0
	for behaviour in manager.get_behaviour_list():
		bonus.append(behaviour.score_bonus())
		jitter.append(behaviour.current_jitter())
		threshold.append(behaviour.current_interrupt_threshold())
		cooldown.append(behaviour.current_cooldown_ticks())
		min_run.append(behaviour.current_min_run_ticks())
		if behaviour.decision_blocked:
			blocked |= 1 << behaviour.decision_index
	_decider.set_modifiers(manager.cpp_row, bonus, jitter, threshold, cooldown, min_run, blocked)


# Shadow mode: every input C++ just worked out against GDScript's own, slot by slot (the hit and swing facts, a game's inputs, the
# group points and the memory-based ones all show up here). Counted with the stale facts.
func _check_inputs(manager: AIBehaviourManager) -> void:
	var inputs := manager.pawn.ai.inputs
	var slots := manager.worked_out_inputs()
	inputs.fill(slots)
	var used: PackedFloat64Array = _decider.get_last_inputs()
	for slot in slots:
		var mine := inputs.value(slot)
		var theirs := used[slot] if slot < used.size() else 0.0
		if mine != theirs:
			_counts["stale_facts"] += 1
			if _counts["stale_facts"] <= warnings_kept:
				push_warning("AIDecisionModule: C++ worked out %s as %s for %s, GDScript as %s." % [AIInputs.name_of(slot), theirs, manager.pawn.name, mine])
			return


# The facts written into the row against the live ones (shadow mode, and the debug build's sampled check); a difference means a write
# was missed somewhere.
func _check_facts(manager: AIBehaviourManager) -> void:
	var facts: Dictionary = _decider.get_facts(manager.cpp_row)
	var context := manager.pawn.ai
	var target_id: int = facts["target_id"]
	var live_target := context.current_target.get_instance_id() if context.has_target() else 0
	var written_target := target_id if target_id != 0 and is_instance_valid(instance_from_id(target_id)) else 0
	var owned := manager.pawn.owned_tags
	var live_words := owned.get_words() if owned else PackedInt64Array()
	var stale: bool = facts["owned"] != live_words or written_target != live_target
	if not stale:
		stale = _can_press_mask(manager, context.inputs) != facts["can_press"]
	if stale:
		_counts["stale_facts"] += 1
		if _counts["stale_facts"] <= warnings_kept:
			push_warning("AIDecisionModule: a fact written for %s is out of date: %s." % [manager.pawn.name, str(facts)])


# Why this pawn decides in GDScript, or "" if it can decide in C++.
func _gdscript_reason(manager: AIBehaviourManager) -> String:
	if manager.pawn == null or manager.pawn.ai == null or manager.get_behaviour_list().is_empty():
		return "no AI"
	if _decider == null:
		if not _warned_no_library:
			_warned_no_library = true
			push_warning("AIDecisionModule: the navcore library has no AIBatchDecider, so every pawn decides in GDScript.")
		return "no C++ library"
	if decider == Decider.ALL_GDSCRIPT:
		return "the game mode's setting"
	if decider == Decider.PAWN_SETTING and manager.decides_in == AIBehaviourManager.DecidesIn.GDSCRIPT:
		return "its own setting"
	if manager.pawn.ai.memory == null or manager.pawn.ai.memory.native_store() == null:
		return "the GDScript memory store"
	for behaviour in manager.get_behaviour_list():
		if behaviour.has_own_code():
			return "special mind: %s's behaviour %s has is_available() or score() code of its own" % [_brain_label(manager), behaviour.name]
		for condition in behaviour.all_conditions():
			if not _kind_known(condition.describe()):
				return "special mind: %s's behaviour %s has a condition of a kind C++ doesn't know" % [_brain_label(manager), behaviour.name]
	return ""


func _kind_known(described: Dictionary) -> bool:
	if not KNOWN_CONDITION_KINDS.has(described.get("kind", "")):
		return false
	for child: Dictionary in described.get("conditions", []):
		if not _kind_known(child):
			return false
	return true


func _brain_label(manager: AIBehaviourManager) -> String:
	return manager.pawn.scene_file_path.get_file() if manager.pawn and manager.pawn.scene_file_path != "" else String(manager.pawn.name)


func _forget_row(manager: AIBehaviourManager) -> void:
	if manager.cpp_row >= 0 and _decider:
		_decider.remove_pawn(manager.get_instance_id())
	manager.cpp_row = -1
	_rows.erase(manager.get_instance_id())


# Moves every placed pawn again, after decider or check_against_gdscript changed.
func _place_all() -> void:
	for id: int in _managers.keys():
		var manager := instance_from_id(id) as AIBehaviourManager
		if manager == null or not manager.is_inside_tree():
			_managers.erase(id)
			continue
		place(manager)


# The decider's brain for this manager, described afresh (its conditions may have changed). Pawns with the same behaviour set share one.
func _brain_for(manager: AIBehaviourManager) -> int:
	if _tag_generation < 0: # the tags as the first brain is described
		_tag_generation = TagRegistry.generation
		_tag_count = TagRegistry.get_tag_count()
	var id := manager.get_instance_id()
	var description := manager.describe()
	var shared := description.duplicate()
	for own: String in ["pawn", "pawn_number", "random_seed", "decision_interval_ticks"]:
		shared.erase(own)
	var text := JSON.stringify(shared, "", true, true)
	var brain: int = _brain_by_text.get(text, -2)
	if brain == -2:
		brain = _decider.add_brain(description) # -1, with an error, if it has too many behaviours
		_brain_by_text[text] = brain
	_brain_of_manager[id] = brain
	return brain


func _unhandled_input(event: InputEvent) -> void:
	var key := event as InputEventKey
	if key == null or not key.pressed or key.echo or key.physical_keycode != KEY_F10 or not OS.is_debug_build():
		return
	if decider == Decider.ALL_GDSCRIPT:
		decider = _previous_decider
	else:
		_previous_decider = decider
		decider = Decider.ALL_GDSCRIPT
	print("AIDecisionModule: AI decisions %s (F10)." % ("all in GDScript" if decider == Decider.ALL_GDSCRIPT else "back to C++"))
	get_viewport().set_input_as_handled()
