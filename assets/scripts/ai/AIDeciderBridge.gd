# Written by Claude (claude-opus-5-5), 2026-11-26. History: ai/CHANGELOG.md.
## Links one pawn's [AIBehaviourManager] to its C++ decider ([code]AIDecider[/code], the main path): keeps the decider's row up to date
## and asks it for each decision.
##
## The manager makes one ([method make_for]) when the pawn decides in C++, and drops it when it moves to GDScript. Before each decision
## it reads the version counters of the facts the row holds and copies only what changed: the owned tags (the AI's state among them),
## the behaviour modifiers' numbers, the actions that could start, the AI's facts ([member AIManager.facts_version]: target, last hit,
## the swing coming) and a game's inputs ([member AIInputs.kept_version]). Brains are compiled once per behaviour set and shared by
## every decider. Where pawns decide: [member AIBehaviourManager.decides_in], the project setting [constant ALL_IN_GDSCRIPT_SETTING],
## and diagnostics' switches ([AIDecisionChecks]). Timed as [code]ai.decide.cpp[/code]. Design: pawn spec 16.5, scaling spec 6.2.
class_name AIDeciderBridge
extends RefCounted

## The project setting that has every pawn decide in GDScript, the backup (false: each pawn's own decides_in).
const ALL_IN_GDSCRIPT_SETTING := "project_base/ai/all_decisions_in_gdscript"

## The decisions made in C++ so far, by every pawn.
static var decisions := 0
## Pawns kept in GDScript because C++ can't read one of their behaviours, counted once per reason.
static var special_minds := 0

## The C++ AIDecider, holding this pawn's row. Typed Object so the game runs without the library.
var decider: Object = null
## The behaviour manager it decides for.
var manager: AIBehaviourManager = null

var _row := -1
var _tags_version := -1
var _modifiers_version := -1
var _ready_version := -1
var _facts_version := -1
var _kept_version := -1
var _ready_slots := PackedInt32Array() # action_ready slots the conditions read
var _groups: Array = [] # [group, distance slot, found slot] for each group the conditions read
var _follows_body := false # an action it presses has readiness that follows the body (Jump), so it's asked every decision

static var _library := ClassDB.class_exists(&"AIDecider")
static var _warned := {} # a reason -> true, so each is said once
static var _kinds_sent := -1 # how many input slots' kinds the decider has (shared by every decider, as in C++)
static var _setting_read := false
static var _setting_all_in_gdscript := false
static var _placement_version := 0
static var _tag_generation := -1
static var _tag_count := -1


## A bridge for this manager, or null if it decides in GDScript (the reason is warned about once if it's a behaviour C++ can't read).
static func make_for(for_manager: AIBehaviourManager) -> AIDeciderBridge:
	var reason := _gdscript_reason(for_manager)
	if reason != "":
		if reason.begins_with("special mind") and not _warned.has(reason):
			_warned[reason] = true
			special_minds += 1
			push_warning("AIDeciderBridge: %s decides in GDScript: %s." % [String(for_manager.pawn.name), reason])
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


func _init(for_manager: AIBehaviourManager) -> void:
	manager = for_manager
	decider = ClassDB.instantiate(&"AIDecider")
	var description := manager.describe()
	var shared := description.duplicate()
	for own: String in ["pawn", "pawn_number", "random_seed", "decision_interval_ticks"]:
		shared.erase(own)
	# The key is everything the brain is compiled from. Not the definitions' ids alone: a behaviour's own conditions can come from the
	# pawn's abilities (Attack's reach), so two pawns with the same definitions can need different brains.
	var brain: int = decider.add_brain(description, JSON.stringify(shared, "", true, true)) # -1, with an error, past 64 behaviours
	if brain < 0:
		return
	var pawn := manager.pawn
	var context := pawn.ai
	_row = decider.add_pawn(manager.get_instance_id(), brain, pawn.entity_number(), context.effective_seed())
	if _row < 0:
		return
	copy_state()
	decider.set_body(_row, pawn.get_instance_id(), context.memory.native_store())
	var by_group := {}
	for slot in manager.worked_out_inputs():
		var kind := AIInputs.kind_of(slot)
		if kind == AIInputs.Kind.GROUP_DISTANCE or kind == AIInputs.Kind.GROUP_FOUND:
			var group := AIInputs.parameter_of(slot)
			if not by_group.has(group):
				by_group[group] = [group, -1, -1]
				_groups.append(by_group[group])
			by_group[group][1 if kind == AIInputs.Kind.GROUP_DISTANCE else 2] = slot
		elif kind == AIInputs.Kind.ACTION_READY:
			_ready_slots.append(slot)
	var abilities := pawn.ability_manager
	if abilities:
		for behaviour in manager.get_behaviour_list():
			if behaviour.settings.presses_action != &"" and abilities.ready_follows_body(behaviour.settings.presses_action):
				_follows_body = true


## One decision in C++: copies over the facts that changed, asks the decider, and returns the chosen behaviour's slot (-1 nothing).
## C++ applies the switch to its own copy of the state; the manager starts the behaviour.
func decide(tick: int, event_priority: int, event_normal: bool) -> int:
	var started := PerfScopes.begin()
	if AIInputs.input_count() != _kinds_sent:
		_kinds_sent = AIInputs.input_count()
		decider.set_input_kinds(AIInputs.kinds())
	_write_changed(tick)
	if AIDecisionChecks.active:
		AIDecisionChecks.before_cpp_decision(self)
	var chosen: int = decider.decide_pawn(_row, tick, event_priority, event_normal)
	if AIDecisionChecks.check_against_gdscript:
		AIDecisionChecks.after_cpp_decision(self)
	decisions += 1
	PerfScopes.end(&"ai.decide.cpp", started)
	return chosen


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


## The facts as written into the row (owned, target_id, can_press and the modifiers' numbers), for the checks.
func written_facts() -> Dictionary:
	return decider.get_facts(_row)


## The inputs the last decision used, as C++ worked them out, for the checks.
func last_inputs() -> PackedFloat64Array:
	return decider.get_last_inputs()


## The behaviours whose action could start now, as a mask by behaviour slot.
static func can_press_mask(for_manager: AIBehaviourManager) -> int:
	var inputs := for_manager.pawn.ai.inputs
	var mask := 0
	for behaviour in for_manager.get_behaviour_list():
		if behaviour.settings.presses_action != &"" and inputs.action_ready(behaviour.settings.presses_action):
			mask |= 1 << behaviour.decision_index
	return mask


# --- Internals ---


# Copies what changed since the last decision, read through each fact's version counter. A group's nearest point goes every time:
# the lookup is kept 2 seconds but checked at every call (as GDScript's reading does), and a point can move (one carried by a hero).
func _write_changed(tick: int) -> void:
	var pawn := manager.pawn
	var context := pawn.ai
	var owned := pawn.owned_tags
	var tags_version := owned.version if owned else 0
	if tags_version != _tags_version:
		_tags_version = tags_version
		decider.set_owned_tags(_row, owned.get_words() if owned else PackedInt64Array())
	if manager.modifiers_version != _modifiers_version:
		_write_modifiers()
	if context.facts_version != _facts_version:
		_facts_version = context.facts_version
		_write_facts(context)
	var inputs := context.inputs
	if inputs.kept_version != _kept_version:
		_kept_version = inputs.kept_version
		for slot in mini(AIInputs.input_count(), inputs.values.size()):
			if AIInputs.kind_of(slot) == AIInputs.Kind.KEPT:
				decider.set_input(_row, slot, inputs.values[slot])
	var abilities := pawn.ability_manager
	if abilities and (abilities.readiness_version != _ready_version or _follows_body):
		_ready_version = abilities.readiness_version
		decider.set_can_press(_row, can_press_mask(manager))
		for slot: int in _ready_slots:
			decider.set_input(_row, slot, inputs.value(slot))
	for group: Array in _groups:
		var point := inputs.nearest_in_group(group[0], tick)
		decider.set_group_point(_row, group[1], group[2], point != null, point.global_position if point else Vector3.ZERO)


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


# What the behaviour modifiers leave, as the numbers the decider uses (the ticks at the match's rate).
func _write_modifiers() -> void:
	_modifiers_version = manager.modifiers_version
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
	decider.set_modifiers(_row, bonus, jitter, threshold, cooldown, min_run, blocked)


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
		return "the GDScript memory store"
	for behaviour in for_manager.get_behaviour_list():
		if behaviour.has_own_code():
			return "special mind: %s's behaviour %s has is_available() or score() code of its own" % [_brain_label(for_manager), behaviour.name]
		for condition in behaviour.all_conditions():
			if not _kind_known(condition.describe()):
				return "special mind: %s's behaviour %s has a condition of a kind C++ doesn't know" % [_brain_label(for_manager), behaviour.name]
	return ""


const _KNOWN_CONDITION_KINDS := ["always", "compare", "chance", "any"] # the kinds AIDecider reads


static func _kind_known(described: Dictionary) -> bool:
	if not _KNOWN_CONDITION_KINDS.has(described.get("kind", "")):
		return false
	for child: Dictionary in described.get("conditions", []):
		if not _kind_known(child):
			return false
	return true


static func _brain_label(for_manager: AIBehaviourManager) -> String:
	var pawn := for_manager.pawn
	return pawn.scene_file_path.get_file() if pawn.scene_file_path != "" else String(pawn.name)
