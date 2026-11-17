# Written by Claude (claude-opus-5-5), 2026-11-17. History: ai/CHANGELOG.md.
## Makes the AI's behaviour decisions in C++, the main path, and decides which pawns use GDScript's decider, the backup.
##
## A GameMode module ([code]GameMode.get_module(AIDecisionModule)[/code]). Scaling spec 6.2, steps 5c and 5d. It holds the C++
## decider (AIBatchDecider): one brain per behaviour set, shared by the pawns using it, and each pawn's row: its decision state
## (running behaviour, cooldowns, persistence) and the facts a decision is made from. A pawn deciding in C++ asks it for each decision
## ([method decide_in_cpp]); C++ decides from the row alone, and the behaviour manager starts the chosen behaviour. Without this module
## every pawn decides in GDScript, as before.
## [br]
## [b]Facts are written through[/b] (the owner's call): whatever owns a fact writes it into the pawn's row when it changes, so a
## decision gathers nothing. The state manager's state_changed, the context's current_target setter, its notes of hits and swings, a
## game's inputs (AIInputs.set_input), the nearest point of a group when the lookup finds another, and the actions that could start
## when the AbilityManager's readiness_version has moved on. The pawn's position and memory are read in C++ (its body, its
## AIMemoryStore). Shadow mode also checks that the written facts match the live ones ([code]stale_facts[/code] in [method get_counts]).
## [br]
## Where each pawn decides (the owner's call: C++ is main, GDScript a dormant backup):
## [br]- The pawn's own setting, [member AIBehaviourManager.decides_in] (C++ by default), unless [member decider] overrides it for
##   every pawn.
## [br]- GDScript regardless, with a warning naming why, for: a game without the C++ library, a pawn on the GDScript memory store, and a
##   "special mind": a behaviour with
##   its own is_available() or score() code, a persistence fade or mask whose script has its own value_at(), or a condition of a
##   kind C++ doesn't know. C++ can't read code, so such a pawn keeps the GDScript decider; there should only be a few.
## [br]
## Nothing watches every tick: where a pawn decides is settled when it first decides, and again only when something changes it (its
## setting, [member decider], its behaviours' conditions).
## [br]
## [member check_against_gdscript] (shadow mode, for tests and finding faults): every pawn decides in GDScript, and each pawn that
## could decide in C++ also has C++ decide beside it, from C++'s own copy of its state; the answers are compared and counted
## ([method get_counts]), the first few disagreements logged, and C++'s copy put right after one.
## [br]
## Keys (debug builds): F10 switches every pawn to GDScript and back, to tell whether a fault is in the C++ decider.
## [br]
## What it costs is timed ([PerfScopes]): [code]ai.decide.cpp[/code], one pawn's decision in C++ with its inputs gathered.
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

var _decider: Object = null # the C++ AIBatchDecider, null without the library
var _warned_no_library := false
var _brain_of_manager := {} # behaviour manager instance id -> brain number
var _brain_by_text := {} # a brain's shared description as text -> brain number
var _state_numbers: Array = [] # brain number -> {state name -> the decider's state number}
var _managers := {} # instance id -> the behaviour managers it has placed, to move them when decider changes
var _warned_minds := {} # a special mind's reason -> true, so each is said once
var _previous_decider := Decider.PAWN_SETTING # what F10 goes back to
var _counts := {"cpp": 0, "checked": 0, "agreed": 0, "differs": 0, "special_minds": 0, "stale_facts": 0}
var _kinds_sent := 0 # how many input slots' kinds C++ has
var _rows := {} # manager instance id -> {ready_version, ready_slots, groups, sent_points, on_state}: what this module keeps per pawn


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


## The C++ decider, or null without the library. For tests.
func get_decider() -> Object:
	return _decider


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
	var brain := _brain_for(manager, true)
	if brain < 0:
		_forget_row(manager)
		return
	var context := manager.pawn.ai_context
	var row: int = _decider.add_pawn(id, brain, context.pawn_number(), context.random_seed)
	if row < 0:
		_forget_row(manager)
		return
	# Its state as the behaviour nodes hold it, so moving in changes nothing.
	var running := manager.get_running_behaviour()
	var ended := PackedInt64Array()
	var persistence := PackedFloat64Array()
	for behaviour in manager.get_behaviours():
		ended.append(behaviour.ended_tick)
		persistence.append_array(behaviour.persistence_state())
	_decider.set_pawn_state(row, running.decision_index if running else -1, running.started_tick if running else -1, ended, persistence)
	for behaviour in manager.get_behaviours():
		if behaviour.persistence_mask:
			_decider.set_persistence_mask(row, behaviour.decision_index, behaviour.persistence_mask.values_at_rate())
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
	var on_state := func(_old: AIStateBase, _new: AIStateBase, _reason: String) -> void: state_changed(manager)
	var old: Dictionary = _rows.get(id, {})
	if old.has("on_state") and context.state_manager and context.state_manager.state_changed.is_connected(old["on_state"]):
		context.state_manager.state_changed.disconnect(old["on_state"])
	if context.state_manager:
		context.state_manager.state_changed.connect(on_state)
	var abilities := manager.pawn.ability_manager
	_rows[id] = {"ready_version": -1, "ready_slots": ready_slots, "groups": groups, "sent_points": {}, "on_state": on_state,
		"follows_body": abilities != null and _follows_body(manager, abilities), "next_group_look": -1}
	state_changed(manager)
	target_changed(manager)
	facts_changed(manager)
	for slot in AIInputs.input_count():
		if AIInputs.kind_of(slot) == AIInputs.Kind.KEPT and slot < context.inputs.values.size():
			_decider.set_input(row, slot, context.inputs.values[slot])


## The pawn's state changed: its number goes into the row. The state manager's state_changed calls it.
func state_changed(manager: AIBehaviourManager) -> void:
	if manager.cpp_row < 0:
		return
	_decider.set_state(manager.cpp_row, _state_number(manager, manager.pawn.ai_context.current_state_name()))


## The pawn's target changed (the context's current_target setter).
func target_changed(manager: AIBehaviourManager) -> void:
	if manager.cpp_row < 0:
		return
	var target := manager.pawn.ai_context.current_target
	_decider.set_target(manager.cpp_row, target.get_instance_id() if is_instance_valid(target) else 0)


## One of the pawn's own inputs changed (AIInputs.set_input).
func input_set(manager: AIBehaviourManager, slot: int, value: float) -> void:
	if manager.cpp_row >= 0:
		_decider.set_input(manager.cpp_row, slot, value)


## The facts C++ works the pawn's inputs out from (its last hit, the swing coming at it) changed: copies them over.
func facts_changed(manager: AIBehaviourManager) -> void:
	var context := manager.pawn.ai_context
	_decider.note_hit(manager.cpp_row, context.last_hit_tick,
		context.last_attacker.get_instance_id() if is_instance_valid(context.last_attacker) else 0)
	var attacker := context.incoming_attacker
	var valid := is_instance_valid(attacker)
	_decider.note_incoming(manager.cpp_row, attacker.get_instance_id() if valid else 0, AIContextComponent.number_of(attacker) if valid else -1,
		context.incoming_start_tick, context.incoming_hit_tick)


## Forgets a pawn leaving the game.
func forget(manager: AIBehaviourManager) -> void:
	_forget_row(manager)
	_managers.erase(manager.get_instance_id())
	_brain_of_manager.erase(manager.get_instance_id())


## True while the pawn's decisions are made in C++ (not in shadow mode, where GDScript makes them).
func drives(manager: AIBehaviourManager) -> bool:
	return manager.cpp_row >= 0 and not check_against_gdscript


## One decision for this pawn in C++: gathers its facts and inputs, asks C++, and returns the chosen behaviour's slot (-1 nothing).
## C++ applies the switch to its own copy of the state; the manager starts the behaviour.
func decide_in_cpp(manager: AIBehaviourManager, tick: int, event_priority: int, event_normal: bool) -> int:
	var started := PerfScopes.begin()
	var row := manager.cpp_row
	var kept: Dictionary = _rows[manager.get_instance_id()]
	if AIInputs.input_count() != _kinds_sent:
		_kinds_sent = AIInputs.input_count()
		_decider.set_input_kinds(AIInputs.kinds())
	# The two facts written here rather than by their owner, each only when it changed: the actions that could start (once the
	# AbilityManager's readiness_version has moved on), and a group's nearest point (when the lookup, every 2 seconds, finds another).
	var abilities := manager.pawn.ability_manager
	if abilities and (abilities.readiness_version != kept["ready_version"] or kept["follows_body"]):
		kept["ready_version"] = abilities.readiness_version
		_write_readiness(manager, kept)
	# The lookup keeps a point for 2 seconds, so it's only asked when that's up (or the point it gave has gone).
	if not kept["groups"].is_empty() and tick >= kept["next_group_look"]:
		_write_group_points(manager, kept, tick)
	if check_against_gdscript:
		_check_facts(manager)
	var chosen: int = _decider.decide_pawn(row, tick, event_priority, event_normal)
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


func persistence_ticks_added(manager: AIBehaviourManager, slot: int, ticks: float, tick: int) -> void:
	_decider.add_persistence_ticks(manager.cpp_row, slot, ticks, tick)


func persistence_speed_set(manager: AIBehaviourManager, slot: int, speed: float, tick: int) -> void:
	_decider.set_persistence_speed(manager.cpp_row, slot, speed, tick)


func jitter_set(manager: AIBehaviourManager, slot: int, effective_jitter: float) -> void:
	_decider.set_score_jitter(manager.cpp_row, slot, effective_jitter)


func threshold_set(manager: AIBehaviourManager, slot: int, threshold: int) -> void:
	_decider.set_interrupt_threshold(manager.cpp_row, slot, threshold)


## A behaviour's per-pawn persistence mask changed (null: none). A mask with its own value_at() code makes the pawn a special mind.
func mask_set(manager: AIBehaviourManager, behaviour: AIBehaviourBase) -> void:
	if behaviour.persistence_mask and ScriptOverrides.overrides(behaviour.persistence_mask.get_script(), &"value_at"):
		place(manager) # to GDScript
		return
	_decider.set_persistence_mask(manager.cpp_row, behaviour.decision_index,
		behaviour.persistence_mask.values_at_rate() if behaviour.persistence_mask else {})


# --- Internals ---


# The actions that could start, as a mask by behaviour slot, and any action_ready inputs the conditions read.
func _write_readiness(manager: AIBehaviourManager, kept: Dictionary) -> void:
	var inputs := manager.pawn.ai_context.inputs
	var mask := 0
	for behaviour in manager.get_behaviour_list():
		if behaviour.presses_action != &"" and inputs.action_ready(behaviour.presses_action):
			mask |= 1 << behaviour.decision_index
	_decider.set_can_press(manager.cpp_row, mask)
	for slot: int in kept["ready_slots"]:
		_decider.set_input(manager.cpp_row, slot, inputs.value(slot))


# Each group's nearest point, written when it's another node than last time.
func _write_group_points(manager: AIBehaviourManager, kept: Dictionary, tick: int) -> void:
	var inputs := manager.pawn.ai_context.inputs
	var sent: Dictionary = kept["sent_points"]
	var all_there := true
	for group: Array in kept["groups"]:
		var point := inputs.nearest_in_group(group[0], tick)
		all_there = all_there and point != null
		if sent.get(group[0]) != point or point == null:
			sent[group[0]] = point
			_decider.set_group_point(manager.cpp_row, group[1], group[2], point != null, point.global_position if point else Vector3.ZERO)
	# A point found is kept 2 seconds (AIInputs.nearest_in_group); with none found, it looks again at the next decision.
	kept["next_group_look"] = tick + TickDriver.ticks_at_rate(AIInputs.GROUP_LOOK_AGAIN_TICKS) if all_there else tick + 1


# True if an action a behaviour presses has an ability whose readiness follows the body (Jump), so it's asked every time.
func _follows_body(manager: AIBehaviourManager, abilities: AbilityManager) -> bool:
	for behaviour in manager.get_behaviour_list():
		if behaviour.presses_action != &"" and abilities.ready_follows_body(behaviour.presses_action):
			return true
	return false


# The decider's number for a state name in this pawn's brain.
func _state_number(manager: AIBehaviourManager, state_name: StringName) -> int:
	var brain: int = _brain_of_manager.get(manager.get_instance_id(), -1)
	if brain < 0:
		return 0
	var states: Dictionary = _state_numbers[brain]
	var number: Variant = states.get(state_name)
	if number == null:
		number = _decider.find_state(brain, state_name)
		states[state_name] = number
	return number


# Shadow mode: the facts written into the row against the live ones; a difference means a write was missed somewhere.
func _check_facts(manager: AIBehaviourManager) -> void:
	var facts: Dictionary = _decider.get_facts(manager.cpp_row)
	var context := manager.pawn.ai_context
	var target_id: int = facts["target_id"]
	var live_target := context.current_target.get_instance_id() if context.has_target() else 0
	var written_target := target_id if target_id != 0 and is_instance_valid(instance_from_id(target_id)) else 0
	var stale: bool = facts["state"] != _state_number(manager, context.current_state_name()) or written_target != live_target
	if not stale:
		var mask := 0
		for behaviour in manager.get_behaviour_list():
			if behaviour.presses_action != &"" and context.inputs.action_ready(behaviour.presses_action):
				mask |= 1 << behaviour.decision_index
		stale = mask != facts["can_press"]
	if stale:
		_counts["stale_facts"] += 1
		if _counts["stale_facts"] <= warnings_kept:
			push_warning("AIDecisionModule: a fact written for %s is out of date: %s." % [manager.pawn.name, str(facts)])


# Why this pawn decides in GDScript, or "" if it can decide in C++.
func _gdscript_reason(manager: AIBehaviourManager) -> String:
	if manager.pawn == null or manager.pawn.ai_context == null or manager.get_behaviour_list().is_empty():
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
	if manager.pawn.ai_context.memory == null or manager.pawn.ai_context.memory.native_store() == null:
		return "the GDScript memory store"
	for behaviour in manager.get_behaviour_list():
		if behaviour.has_own_code():
			return "special mind: %s's behaviour %s has is_available() or score() code of its own" % [_brain_label(manager), behaviour.name]
		for profile: FadeProfile in [behaviour.persistence_fade, behaviour.persistence_mask]:
			if profile and ScriptOverrides.overrides(profile.get_script(), &"value_at"):
				return "special mind: %s's behaviour %s has a fade with value_at() code of its own" % [_brain_label(manager), behaviour.name]
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
	var kept: Dictionary = _rows.get(manager.get_instance_id(), {})
	var states := manager.pawn.ai_context.state_manager if manager.pawn and manager.pawn.ai_context else null
	if kept.has("on_state") and states and states.state_changed.is_connected(kept["on_state"]):
		states.state_changed.disconnect(kept["on_state"])
	_rows.erase(manager.get_instance_id())


# Moves every placed pawn again, after decider or check_against_gdscript changed.
func _place_all() -> void:
	for id: int in _managers.keys():
		var manager := instance_from_id(id) as AIBehaviourManager
		if manager == null or not manager.is_inside_tree():
			_managers.erase(id)
			continue
		place(manager)


# The decider's brain for this manager. Pawns with the same behaviour set share one. again: describe it afresh (its conditions may
# have changed).
func _brain_for(manager: AIBehaviourManager, again := false) -> int:
	var id := manager.get_instance_id()
	var known: Variant = _brain_of_manager.get(id)
	if known != null and not again:
		return known
	var description := manager.describe()
	var shared := description.duplicate()
	for own: String in ["pawn", "pawn_number", "random_seed", "decision_interval_ticks"]:
		shared.erase(own)
	var text := JSON.stringify(shared, "", true, true)
	var brain: int = _brain_by_text.get(text, -2)
	if brain == -2:
		brain = _decider.add_brain(description) # -1, with an error, if it has too many behaviours
		_brain_by_text[text] = brain
		if brain >= 0:
			_state_numbers.append({})
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
