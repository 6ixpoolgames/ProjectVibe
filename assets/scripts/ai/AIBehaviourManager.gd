# Written by Claude (claude-opus-5-5), 2026-11-09. History: ai/CHANGELOG.md.
## Picks and runs the pawn's AI behaviour, judging between its behaviours by score.
##
## A part on the pawn (added by PawnInitializer or the game's AI brain) with its [AIBehaviourBase] nodes as children. At each decision
## it checks whether the running behaviour may be replaced, drops behaviours that fail a hard rule, scores the rest and starts the
## winner; between decisions only the running behaviour's tick runs. Behaviours are kept sorted by name (the fixed order), never by
## the order added. Outside code only talks to the manager:
## [codeblock]
## pawn.ai_context.behaviour_manager.get_running_behaviour()
## pawn.ai_context.behaviour_manager.add_persistence_ticks(&"Chase", 60)    # say after landing a hit
## pawn.ai_context.behaviour_manager.set_score_jitter(&"Wander", 0.2)       # say for a confused effect
## pawn.ai_context.behaviour_manager.add_score_modifier(charge_shout, self)   # raise melee until removed (AIScoreModifier)
## [/codeblock]
## With the [AIDecisionModule] in the game, C++ makes the decisions and this manager is the backup ([method decide]).
## Design: pawn spec 10.7 and 10.8, scaling spec 6.2.
class_name AIBehaviourManager
extends Node

## Sent each time the running behaviour changes. Either can be null: nothing was running, or nothing runs now.
signal behaviour_changed(old_behaviour: AIBehaviourBase, new_behaviour: AIBehaviourBase, reason: String)

## Called after every decision of every pawn: [code]func(record: AIDecisionRecord, manager: AIBehaviourManager)[/code]. Static, so one
## listener hears every pawn. For diagnostics and checking another decider (scaling spec 6.2). Empty (default): no record is made.
static var decision_listener := Callable()
## The [AIDecisionModule] running decisions in C++, set by it while it's in the game; null otherwise (every pawn decides here).
static var decision_module: AIDecisionModule = null

## Where this pawn's decisions are made.
enum DecidesIn {
	CPP, ## by C++, the main path (the default)
	GDSCRIPT, ## by this manager, the backup
}

## Where this pawn's decisions are made: C++ (the default, with the [AIDecisionModule] in the game) or GDScript. The game mode can
## override it for every pawn ([member AIDecisionModule.decider]).
@export var decides_in := DecidesIn.CPP:
	set(value):
		decides_in = value
		if _placed_by:
			_placed_by.place(self)
## The jitter for behaviours whose own score_jitter is -1. 0: no randomness.
@export var default_score_jitter := 0.0
## On: results that tie are picked between at random (replayably). Off: the fixed order decides.
@export var randomize_ties := false
## Results closer than this count as a tie.
@export var tie_margin := 0.0001

## The pawn this is a part of, or null.
var pawn: Pawn = null
## Its row in the C++ decider, set by the [AIDecisionModule]; -1 while it decides in GDScript.
var cpp_row := -1

var _behaviours: Array[AIBehaviourBase] = [] # by name
var _running: AIBehaviourBase = null
# Reused every decision, so a decision creates no arrays.
var _candidates: Array[AIBehaviourBase] = []
var _ties: Array[AIBehaviourBase] = []
var _by_ceiling := func(a: AIBehaviourBase, b: AIBehaviourBase) -> bool:
	return a.decision_ceiling > b.decision_ceiling or (a.decision_ceiling == b.decision_ceiling and a.decision_index < b.decision_index)
var _by_floor := func(a: AIBehaviourBase, b: AIBehaviourBase) -> bool:
	return a.decision_floor > b.decision_floor or (a.decision_floor == b.decision_floor and a.decision_index < b.decision_index)
var _by_index := func(a: AIBehaviourBase, b: AIBehaviourBase) -> bool:
	return a.decision_index < b.decision_index
## Goes up by one whenever the score modifiers' sums or blocks change, so the C++ decider's copy is written again. Don't set it.
var modifiers_version := 0

var _warned_states := {} # state name -> true, for "no behaviour's tag requirements pass in this state"
# Score modifiers (pawn spec 10.13): {modifier (resolved), source (a key), ends (a tick, -1 until removed)}, in the order added.
var _modifiers: Array[Dictionary] = []
var _modifiers_dirty := false
var _modifier_values_set := false # some behaviour has a sum or a block, so clearing them needs a pass
var _soonest_modifier_end := -1
var _modifiers_tags_version := -1 # the owned tags' version the sums were worked out for
var _checked_tags_version := -1 # check_running()'s last look
var _checked_modifiers_version := -1
var _input_slots := PackedInt32Array() # the worked-out inputs the behaviours' conditions read
var _input_slots_known := false
var _placed_by: AIDecisionModule = null # the module that settled where it decides

const TIE_SALT := 0x7135
const MODIFIER_TAG_SOURCE := &"score_modifiers" # the owned-tags source for the modifiers' granted tags # what the tie-breaking random number is for, so it differs from every behaviour's jitter


func _init() -> void:
	set_process(false)
	set_physics_process(false)


func _enter_tree() -> void:
	pawn = get_parent() as Pawn
	if pawn == null:
		push_warning("AIBehaviourManager: its parent isn't a Pawn, so it does nothing.")


func _ready() -> void:
	_collect_behaviours()
	# The running behaviour stops when the pawn dies (the AbilityManager's died). Its exit's orders are ignored: a dead pawn's controller
	# takes none and lets go of everything itself, so an order stream holds only AI-step orders (netcode spec 19.10).
	var abilities := pawn.ability_manager if pawn else null
	if abilities:
		abilities.died.connect(func(_pawn: Pawn, _hit: HitInfo) -> void: stop_running("died"))
		# Wake-ups: the running behaviour's tick() runs at its next AI step after an event it waits for.
		abilities.ability_finished.connect(_on_ability_ended)
		abilities.ability_cancelled.connect(func(ability: AbilityBase, _by: AbilityBase) -> void: _on_ability_ended(ability))
	var navigation := pawn.navigation_manager if pawn else null
	if navigation:
		navigation.path_ended.connect(_on_path_ended)


func _exit_tree() -> void:
	if _running and pawn:
		_stop_running("removed", pawn.ai_context.current_tick if pawn.ai_context else 0)
	if _placed_by and is_instance_valid(_placed_by):
		_placed_by.forget(self)
	_placed_by = null


## The behaviour running now, or null.
func get_running_behaviour() -> AIBehaviourBase:
	return _running


## Every behaviour, in the fixed order.
func get_behaviours() -> Array[AIBehaviourBase]:
	return _behaviours.duplicate()


## The same list without a copy, for code that reads it often (the AIDecisionModule). Don't change it.
func get_behaviour_list() -> Array[AIBehaviourBase]:
	return _behaviours


## This brain as plain data: the manager's, the AI context's and each behaviour's settings, in the fixed order. Taken by
## [code]AIBatchDecider.add_brain()[/code] and saved by [AIDecisionRecorder]. Settings changed during play show in the next call.
func describe() -> Dictionary:
	var context := pawn.ai_context if pawn else null
	var behaviours: Array = []
	for behaviour in _behaviours:
		var tag_names: Array = []
		for tag in behaviour.tags:
			tag_names.append(String(tag))
		var lowest: Variant = null # JSON has no infinity
		if behaviour.min_score > -INF:
			lowest = behaviour.min_score
		var fade: Variant = null
		if behaviour.persistence_fade:
			fade = behaviour.persistence_fade.values_at_rate()
		behaviours.append({
			"name": String(behaviour.name), "name_hash": behaviour.name_hash, "tags": tag_names, "enabled": behaviour.enabled,
			# Names and the words they make now (TagQuery.describe_words); null: no requirements.
			"tag_requirements": behaviour.tag_requirements.describe_words() if behaviour.tag_requirements else null,
			"max_score": behaviour.max_score, "min_score": lowest,
			"needs_target": behaviour.needs_target, "presses_action": String(behaviour.presses_action),
			"cooldown_ticks": behaviour.cooldown_ticks, "cooldown_ticks_at_rate": TickDriver.ticks_at_rate(behaviour.cooldown_ticks),
			"min_run_ticks": behaviour.min_run_ticks,
			"min_run_ticks_at_rate": TickDriver.ticks_at_rate(behaviour.min_run_ticks), # what the interrupt rule compares with
			"interrupt_threshold": behaviour.interrupt_threshold, "cannot_be_interrupted": behaviour.cannot_be_interrupted,
			"score_jitter": behaviour.score_jitter, "effective_jitter": behaviour.effective_jitter(),
			"persistence": behaviour.persistence, "has_persistence_fade": behaviour.persistence_fade != null,
			"persistence_fade": fade,
			"script": behaviour.get_script().resource_path.get_file() if behaviour.get_script() else "",
			# How C++ judges it: from its conditions and curves, or by asking GDScript for a behaviour with its own code.
			"scorer": "given" if behaviour.has_own_code() else "conditions",
			"conditions": _describe_conditions(behaviour), "score_curves": _describe_curves(behaviour),
		})
	return {
		"pawn_number": pawn.entity_number() if pawn else 0, "pawn": String(pawn.name) if pawn else "",
		"random_seed": context.effective_seed() if context else 0,
		"decision_interval_ticks": context.decision_interval_ticks if context else 0,
		"default_score_jitter": default_score_jitter, "randomize_ties": randomize_ties,
		"tie_margin": tie_margin, "tie_salt": TIE_SALT, "tag_words": TagRegistry.get_categories().size(), "behaviours": behaviours,
	}


## Makes the waiting decision ([method AIContextComponent.request_decision]) and starts what it chose. record: filled in while
## [member decision_listener] is set (null: made here). Twin of C++ [code]AIBatchDecider[/code]: same steps, a change goes in both.
func decide(tick: int, record: AIDecisionRecord = null) -> void:
	if pawn == null or pawn.ai_context == null:
		return
	var context := pawn.ai_context
	var event_priority := context.waiting_event_priority()
	var event_is_normal := context.waiting_event_is_normal()
	context.clear_decision()
	if _behaviours.is_empty():
		return
	if record == null and decision_listener.is_valid():
		record = AIDecisionRecord.new()
	# Where it decides is settled the first time, and again only when something changes it (no per-tick check).
	var module := decision_module
	if module and _placed_by != module:
		_placed_by = module
		module.place(self)
	# The inputs the conditions read start afresh, each worked out when first read (scaling spec 6.2). A record needs them all.
	context.inputs.begin_decision(tick)
	refresh_modifiers(tick)
	# C++, the main path: it decides, from its own copy of the state and the facts written into it, and this starts what it chose.
	if cpp_row >= 0 and not module.check_against_gdscript:
		var slot := module.decide_in_cpp(self, tick, event_priority, event_is_normal)
		var chosen: AIBehaviourBase = _behaviours[slot] if slot >= 0 and slot < _behaviours.size() else null
		if record:
			_fill_record(record, tick, event_priority, event_is_normal, module.was_kept(), false)
			record.chosen = chosen.name if chosen else &""
		_switch_to(chosen, event_is_normal, tick)
		if record:
			decision_listener.call(record, self)
		return
	# Shadow mode: C++ decides beside GDScript from its own copy of the state, and is checked once GDScript has decided.
	var cpp_choice := module.decide_in_cpp(self, tick, event_priority, event_is_normal) if module and cpp_row >= 0 else -2
	if record:
		context.inputs.fill(worked_out_inputs())
	var owned := _owned_words()
	# 0. Interrupts. A running behaviour whose tag requirements fail, or that a modifier blocks, isn't held by its min_run_ticks;
	# its interrupt_threshold and cannot_be_interrupted still hold it, as they hold it through a state change.
	if _running and not _can_replace_running(event_priority, event_is_normal and not _must_go(_running, owned), tick):
		if record:
			_fill_record(record, tick, event_priority, event_is_normal, true)
			record.chosen = _running.name
			decision_listener.call(record, self)
		if cpp_choice != -2:
			module.compare(self, cpp_choice, tick)
		return
	# 1 and 2. Valid behaviours, and the hard rules.
	var state_name := context.current_state_name()
	var any_allowed := false
	_candidates.clear()
	for behaviour in _behaviours:
		if not behaviour.passes_requirements(owned): # includes switched off
			continue
		any_allowed = true
		if behaviour.decision_blocked:
			continue
		if behaviour != _running and behaviour.is_cooling_down(tick):
			continue
		if behaviour.needs_target and not context.has_target():
			continue
		# The running one has already pressed its action, so "could it start" doesn't apply to it.
		if behaviour.presses_action != &"" and behaviour != _running and not _could_press(behaviour.presses_action):
			continue
		# 3. Its range.
		var jitter := behaviour.effective_jitter()
		behaviour.decision_persistence = behaviour.persistence_now(tick)
		behaviour.decision_jitter = jitter * context.random_signed(behaviour.name_hash) if jitter > 0.0 else 0.0
		# Persistence and the score modifiers' sum, added together first, as C++ does, so the two agree to the bit.
		var boost := behaviour.decision_persistence + behaviour.decision_modifier
		behaviour.decision_ceiling = behaviour.max_score + boost + jitter
		behaviour.decision_floor = behaviour.min_score + boost - jitter if behaviour.min_score > -INF else -INF
		behaviour.availability_checked = false
		behaviour.decision_scored = false
		_candidates.append(behaviour)
	if not any_allowed and not _warned_states.has(state_name):
		_warned_states[state_name] = true
		push_warning("AIBehaviourManager: no behaviour on %s passes its tag requirements in the state %s, so it stands still there." % [pawn.name, state_name])
	# 3, continued. A floor is only certain if its behaviour is available, so take the highest floor from the first available
	# behaviour, highest floor down (else a fixed-score behaviour that doesn't apply, like Search, would shut out ones that do).
	var highest_floor := -INF
	_candidates.sort_custom(_by_floor)
	for behaviour in _candidates:
		if behaviour.decision_floor == -INF:
			break # sorted, so no floors left
		if _is_available(behaviour, context):
			highest_floor = behaviour.decision_floor
			break
	# 4. Scoring, highest ceiling first.
	_candidates.sort_custom(_by_ceiling)
	var best: AIBehaviourBase = null
	var best_result := -INF
	_ties.clear()
	for behaviour in _candidates:
		if behaviour.decision_ceiling < highest_floor:
			continue # can't beat a result some other behaviour is sure to reach
		if best and behaviour.decision_ceiling < best_result - tie_margin:
			break # sorted by ceiling, so nothing after this can win either
		if not _is_available(behaviour, context):
			continue
		var raw := behaviour.score(context)
		_check_score_range(behaviour, raw)
		behaviour.decision_score = raw
		behaviour.decision_scored = true
		var result := raw + (behaviour.decision_persistence + behaviour.decision_modifier) + behaviour.decision_jitter
		if best == null or result > best_result + tie_margin:
			best = behaviour
			best_result = result
			_ties.clear()
			_ties.append(behaviour)
		elif result >= best_result - tie_margin:
			_ties.append(behaviour)
	# 5. Ties.
	if _ties.size() > 1:
		_ties.sort_custom(_by_index)
		best = _ties[mini(int(context.random_unit(TIE_SALT) * _ties.size()), _ties.size() - 1)] if randomize_ties else _ties[0]
	# The record is filled in before switching, which changes cooldowns.
	if record:
		_fill_record(record, tick, event_priority, event_is_normal, false)
		record.chosen = best.name if best else &""
	# 6. Switching.
	_switch_to(best, event_is_normal, tick)
	if record:
		decision_listener.call(record, self)
	if cpp_choice != -2:
		module.compare(self, cpp_choice, tick)


## [method AIContextComponent.think] calls this every tick the AI runs, after any decision. Ticks the running behaviour.
func tick_running(tick: int) -> void:
	if _running == null or pawn == null:
		return
	# Only when woken by an event it waits for, at the tick it asked for, or every tick_interval_ticks counted from when it started:
	# ticking every tick costs a crowd far more (ai_stress).
	var woken := _running.woken or (_running.wake_tick >= 0 and tick >= _running.wake_tick)
	var interval := TickDriver.ticks_at_rate(_running.tick_interval_ticks)
	# Or one skipped since its pawn's last run, for a pawn running every Nth tick (pawn spec 8.21).
	if not woken and interval > 1 and not pawn.fired_since_last_run(tick, -_running.started_tick, interval):
		return
	# Used up before tick(), so tick() can ask again.
	_running.woken = false
	if _running.wake_tick >= 0 and tick >= _running.wake_tick:
		_running.wake_tick = -1
	var context := pawn.ai_context
	var tick_started := PerfScopes.begin_detailed() # each behaviour's tick timed on its own, in detail (PerfScopes)
	var status := _running.tick(context)
	PerfScopes.end(_running.perf_tick_name, tick_started)
	if status == AIBehaviourBase.Status.RUNNING:
		return
	_stop_running("succeeded" if status == AIBehaviourBase.Status.SUCCEEDED else "failed", tick)
	context.request_decision()
	var record: AIDecisionRecord = null
	if decision_listener.is_valid():
		record = AIDecisionRecord.new()
		record.cause = AIDecisionRecord.CAUSE_BEHAVIOUR_ENDED
	var decide_started := PerfScopes.begin()
	decide(tick, record)
	PerfScopes.end(&"ai.decide.behaviour", decide_started)


## Stops the running behaviour, if any; its exit() gets this reason. Called with "died" when the pawn dies.
func stop_running(reason: String) -> void:
	_stop_running(reason, _now())


## Moves a behaviour's persistence back along its fade by this many ticks, so it lasts longer. Negative: it ends sooner.
func add_persistence_ticks(behaviour_name: StringName, ticks: float) -> void:
	var behaviour := _find(behaviour_name)
	if behaviour:
		behaviour.add_persistence_ticks(ticks, _now())
		if cpp_row >= 0:
			decision_module.persistence_ticks_added(self, behaviour.decision_index, ticks, _now())


## How fast a behaviour's persistence fades from now on: 1.0 normally, 0.5 for half speed.
func set_persistence_speed(behaviour_name: StringName, speed: float) -> void:
	var behaviour := _find(behaviour_name)
	if behaviour:
		behaviour.set_persistence_speed(speed, _now())
		if cpp_row >= 0:
			decision_module.persistence_speed_set(self, behaviour.decision_index, speed, _now())


## Gives this pawn's behaviour a persistence mask: a fade multiplied with its own persistence fade, for this pawn only. Null: none.
## Counted from when the behaviour starts, as the fade is.
func set_persistence_mask(behaviour_name: StringName, mask: FadeProfile) -> void:
	var behaviour := _find(behaviour_name)
	if behaviour:
		behaviour.persistence_mask = mask
		if cpp_row >= 0:
			decision_module.mask_set(self, behaviour)


## Changes a behaviour's interrupt threshold, even while it runs.
func set_interrupt_threshold(behaviour_name: StringName, threshold: int) -> void:
	var behaviour := _find(behaviour_name)
	if behaviour:
		behaviour.interrupt_threshold = threshold
		if cpp_row >= 0:
			decision_module.threshold_set(self, behaviour.decision_index, threshold)


## Called when a behaviour's conditions change ([method AIBehaviourBase.rebuild_conditions]), so the inputs worked out at each
## decision are listed again, and C++ gets the new brain.
func inputs_changed() -> void:
	_input_slots_known = false
	if _placed_by:
		_placed_by.place(self)


## Changes a behaviour's jitter. -1: back to default_score_jitter.
func set_score_jitter(behaviour_name: StringName, jitter: float) -> void:
	var behaviour := _find(behaviour_name)
	if behaviour:
		behaviour.score_jitter = jitter
		if cpp_row >= 0:
			decision_module.jitter_set(self, behaviour.decision_index, behaviour.effective_jitter())


## Adds a score modifier (pawn spec 10.13), kept under this source: anything that names it, usually the node or effect that adds it.
## A source may add several; [method remove_score_modifier] takes all of its own away.
func add_score_modifier(modifier: AIScoreModifier, source: Variant) -> void:
	if modifier == null:
		return
	var resolved := modifier.resolved() as AIScoreModifier
	var now := _now()
	var ends := now + TickDriver.ticks_at_rate(resolved.duration_ticks) if resolved.duration_ticks > 0 else -1
	_modifiers.append({"modifier": resolved, "source": _source_key(source), "ends": ends})
	_modifiers_dirty = true
	refresh_modifiers(now)
	if resolved.wakes_decision and pawn and pawn.ai_context:
		pawn.ai_context.request_decision(0, false)


## Takes away every score modifier this source added.
func remove_score_modifier(source: Variant) -> void:
	var key: Variant = _source_key(source)
	var wakes := false
	for i in range(_modifiers.size() - 1, -1, -1):
		if _modifiers[i]["source"] == key:
			wakes = wakes or _modifiers[i]["modifier"].wakes_decision
			_modifiers.remove_at(i)
			_modifiers_dirty = true
	if not _modifiers_dirty:
		return
	refresh_modifiers(_now())
	if wakes and pawn and pawn.ai_context:
		pawn.ai_context.request_decision(0, false)


## The score modifiers now, in the order added: {modifier, source, ends} each (ends is the tick it goes, -1 until removed).
func get_score_modifiers() -> Array[Dictionary]:
	return _modifiers.duplicate(true)


## Works the modifiers' sum and block for each behaviour out again, if anything they depend on changed: the list, a deadline passing,
## or the pawn's owned tags (their ongoing requirements). Every decision calls it first; cheap when nothing changed.
func refresh_modifiers(tick: int) -> void:
	var owned := pawn.owned_tags if pawn else null
	var tags_version := owned.version if owned else 0
	var expired := _soonest_modifier_end >= 0 and tick >= _soonest_modifier_end
	if not _modifiers_dirty and not expired and (tags_version == _modifiers_tags_version or _modifiers.is_empty()):
		return
	_modifiers_dirty = false
	_soonest_modifier_end = -1
	var granted: Array[StringName] = []
	for i in range(_modifiers.size() - 1, -1, -1):
		var ends: int = _modifiers[i]["ends"]
		if ends >= 0 and tick >= ends:
			_modifiers.remove_at(i)
			continue
		if ends >= 0 and (_soonest_modifier_end < 0 or ends < _soonest_modifier_end):
			_soonest_modifier_end = ends
	for entry in _modifiers:
		granted.append_array(entry["modifier"].granted_tags)
	if owned:
		owned.set_source(MODIFIER_TAG_SOURCE, granted) # may change the owned tags, read just below
		tags_version = owned.version
	_modifiers_tags_version = tags_version
	if _modifiers.is_empty() and not _modifier_values_set:
		return
	var words := _owned_words()
	var any_set := false
	var changed := false
	for behaviour in _behaviours:
		var sum := 0.0
		var blocked := false
		for entry in _modifiers: # in the order added, so the sum is the same on every run
			var modifier: AIScoreModifier = entry["modifier"]
			if not modifier.counts_for(words) or not modifier.applies_to_behaviour(behaviour):
				continue
			if modifier.blocks:
				blocked = true
			else:
				sum += modifier.amount
		if sum != behaviour.decision_modifier or blocked != behaviour.decision_blocked:
			changed = true
			behaviour.decision_modifier = sum
			behaviour.decision_blocked = blocked
		any_set = any_set or sum != 0.0 or blocked
	_modifier_values_set = any_set
	if changed:
		modifiers_version += 1


## The AI step calls this every run, before deciding: if the owned tags or the modifiers changed and the running behaviour's tag
## requirements now fail (or a modifier blocks it), it asks for a decision that its min_run_ticks don't hold off (its
## interrupt_threshold still does). A pawn out of shots leaves Keep Distance at once instead of at its next decision tick.
func check_running(tick: int) -> void:
	refresh_modifiers(tick)
	if _running == null or _running.cannot_be_interrupted or pawn == null or pawn.ai_context == null:
		return
	var owned := pawn.owned_tags
	var tags_version := owned.version if owned else 0
	if tags_version == _checked_tags_version and modifiers_version == _checked_modifiers_version:
		return
	_checked_tags_version = tags_version
	_checked_modifiers_version = modifiers_version
	if _must_go(_running, _owned_words()):
		pawn.ai_context.request_decision(0, false)


# --- Internals ---


# A behaviour that may no longer run: its tag requirements fail, or a modifier blocks it.
func _must_go(behaviour: AIBehaviourBase, owned_words: PackedInt64Array) -> bool:
	return behaviour.decision_blocked or not behaviour.passes_requirements(owned_words)


# The pawn's owned tags as words (none without an OwnedTags part).
func _owned_words() -> PackedInt64Array:
	return pawn.owned_tags.get_words() if pawn and pawn.owned_tags else PackedInt64Array()


# A modifier's source as a key: an object by its instance id (so a freed one still matches), anything else as it is.
static func _source_key(source: Variant) -> Variant:
	if source is Object:
		return source.get_instance_id()
	return source


# Pawn spec 10.7: an event replaces the running behaviour only if it isn't cannot_be_interrupted, the event's priority reaches its
# interrupt_threshold, and, for an ordinary decision, its min_run_ticks have passed.
func _can_replace_running(event_priority: int, event_is_normal: bool, tick: int) -> bool:
	if _running.cannot_be_interrupted:
		return false
	if event_priority < _running.interrupt_threshold:
		return false
	# min_run_ticks 0 means no minimum at all, whatever the ticks say.
	if event_is_normal and _running.min_run_ticks > 0 and tick - _running.started_tick < TickDriver.ticks_at_rate(_running.min_run_ticks):
		return false
	return true


# Step 6: starts the chosen behaviour, or stops the running one if nothing was chosen. C++ has already applied the same switch to
# its own copy of the state.
func _switch_to(best: AIBehaviourBase, event_is_normal: bool, tick: int) -> void:
	if best == _running:
		return
	var switch_started := PerfScopes.begin()
	var reason := "decision" if event_is_normal else "interrupted"
	if best == null:
		_stop_running(reason, tick, false)
		var hands := pawn.ai_context.controller if pawn and pawn.ai_context else null
		if hands:
			hands.release_all() # nothing can run: stand still
	else:
		_start(best, reason, tick)
	PerfScopes.end(&"ai.decide.switch", switch_started)


func _start(behaviour: AIBehaviourBase, reason: String, tick: int) -> void:
	var old := _running
	if old:
		old.exit(pawn.ai_context, reason)
		old.ended_tick = tick
	_running = behaviour
	behaviour.started_tick = tick
	behaviour.start_persistence(tick)
	behaviour.clear_wake_ups()
	behaviour.enter(pawn.ai_context)
	behaviour_changed.emit(old, behaviour, reason)


# tell_cpp: false when a decision stops it, since C++ made (or checks) that decision itself; true when it stops on its own
# (finished, died, removed), so C++'s copy of the state follows.
func _stop_running(reason: String, tick: int, tell_cpp := true) -> void:
	if _running == null:
		return
	var old := _running
	_running = null
	old.exit(pawn.ai_context, reason)
	old.ended_tick = tick
	if tell_cpp and cpp_row >= 0 and decision_module:
		decision_module.stopped(self, tick)
	behaviour_changed.emit(old, null, reason)


# is_available() once per decision: the floor check and the scoring may both ask.
func _is_available(behaviour: AIBehaviourBase, context: AIContextComponent) -> bool:
	if not behaviour.availability_checked:
		behaviour.availability_checked = true
		var started := PerfScopes.begin_detailed() # each behaviour's check timed on its own, in detail (PerfScopes)
		behaviour.decision_available = behaviour.is_available(context)
		PerfScopes.end(behaviour.perf_available_name, started)
	return behaviour.decision_available


# Writes what this decision was made from into record: the reasons, the running behaviour, and each behaviour's hard rule, range,
# availability and score, in the fixed order. Called before switching, so the hard rules are asked again exactly as the decision
# asked them (nothing between changes them). Only runs while decision_listener is set.
# numbers: false for a decision C++ made, where GDScript's scratch values (ranges, availability, scores) weren't worked out.
func _fill_record(record: AIDecisionRecord, tick: int, event_priority: int, event_is_normal: bool, kept_by_interrupt: bool,
		numbers := true) -> void:
	var context := pawn.ai_context
	record.tick = tick
	record.pawn_number = pawn.entity_number()
	record.pawn_name = pawn.name
	record.event_priority = event_priority
	record.event_is_normal = event_is_normal
	record.has_target = context.has_target()
	record.state = context.current_state_name()
	record.running_before = _running.name if _running else &""
	record.running_started_tick = _running.started_tick if _running else -1
	record.kept_by_interrupt = kept_by_interrupt
	record.inputs = context.inputs.values.duplicate()
	if pawn.owned_tags:
		record.owned_tags = pawn.owned_tags.get_owned()
	if record.cause != AIDecisionRecord.CAUSE_AI_STEP: # no target or state update ran, so before and after are what they are now
		record.note_target_before(context.current_target)
		record.state_before = record.state
		record.state_after = record.state
	if kept_by_interrupt:
		return # no behaviour was looked at
	var owned := _owned_words()
	for behaviour in _behaviours:
		var rule := AIDecisionRecord.RULE_NONE
		if not behaviour.enabled:
			rule = AIDecisionRecord.RULE_OFF
		elif not behaviour.passes_requirements(owned):
			rule = AIDecisionRecord.RULE_TAGS
		elif behaviour.decision_blocked:
			rule = AIDecisionRecord.RULE_BLOCKED
		elif behaviour != _running and behaviour.is_cooling_down(tick):
			rule = AIDecisionRecord.RULE_COOLDOWN
		elif behaviour.needs_target and not record.has_target:
			rule = AIDecisionRecord.RULE_NO_TARGET
		elif behaviour.presses_action != &"" and behaviour != _running and not _could_press(behaviour.presses_action):
			rule = AIDecisionRecord.RULE_ACTION
		record.add_behaviour(behaviour, rule if numbers or rule != AIDecisionRecord.RULE_NONE else AIDecisionRecord.RULE_NOT_WORKED_OUT)


# Whether pressing the action could start an ability: the action_ready input, asked of the AbilityManager again only after something
# that affects it changed (AIInputs.action_ready).
func _could_press(action: StringName) -> bool:
	return pawn.ai_context.inputs.action_ready(action)


## The slots of the worked-out inputs any behaviour's conditions or curves read, listed once (and again after inputs_changed()).
func worked_out_inputs() -> PackedInt32Array:
	if not _input_slots_known:
		_input_slots_known = true
		var slots := {}
		for behaviour in _behaviours:
			behaviour.add_input_slots(slots)
		_input_slots.clear()
		for slot: int in slots:
			if AIInputs.is_worked_out(slot):
				_input_slots.append(slot)
		_input_slots.sort() # a fixed order, so the inputs are worked out the same way every run
	return _input_slots


func _describe_conditions(behaviour: AIBehaviourBase) -> Array:
	var list: Array = []
	for condition in behaviour.all_conditions():
		list.append(condition.describe())
	return list


func _describe_curves(behaviour: AIBehaviourBase) -> Array:
	var list: Array = []
	for curve in behaviour.score_curves:
		if curve:
			list.append(curve.describe())
	return list


func _check_score_range(behaviour: AIBehaviourBase, raw: float) -> void:
	if behaviour.warned_score_range or not OS.is_debug_build():
		return
	if raw > behaviour.max_score + 0.000001 or raw < behaviour.min_score - 0.000001:
		behaviour.warned_score_range = true
		push_warning("AIBehaviourManager: %s's score() gave %.3f, outside its min_score %.3f to max_score %.3f. Choices may be wrong until that's fixed." % [behaviour.name, raw, behaviour.min_score, behaviour.max_score])


func _find(behaviour_name: StringName) -> AIBehaviourBase:
	for behaviour in _behaviours:
		if behaviour.name == behaviour_name:
			return behaviour
	push_warning("AIBehaviourManager: %s has no behaviour called %s." % [String(pawn.name) if pawn else "this pawn", behaviour_name]) # String(), so both sides are text
	return null


# The tick now, from the TickDriver autoload.
func _now() -> int:
	return TickDriver.tick


func _collect_behaviours() -> void:
	_behaviours.clear()
	for child in get_children():
		if child is AIBehaviourBase:
			child.manager = self
			child.pawn = pawn
			child.name_hash = String(child.name).hash()
			child.perf_available_name = StringName("ai.available." + String(child.name))
			child.perf_tick_name = StringName("ai.behaviour." + String(child.name))
			_behaviours.append(child)
			if String(child.name).begins_with("@"):
				push_warning("AIBehaviourManager: the behaviour %s has an automatic name, which can differ between runs. Give it a name." % child.name)
	# Sorted by name: one fixed order whatever order they were added in.
	_behaviours.sort_custom(func(a: AIBehaviourBase, b: AIBehaviourBase) -> bool: return String(a.name) < String(b.name))
	for i in _behaviours.size():
		_behaviours[i].decision_index = i

# The wake-ups' events: a walk ending, and an ability ending. Only the running behaviour, and only if it asked.
func _on_path_ended(_reached: bool) -> void:
	if _running and _running.wakes_on_path_end:
		_running.woken = true


func _on_ability_ended(ability: AbilityBase) -> void:
	if _running and _running.wakes_on_action != &"" and ability.trigger_action == _running.wakes_on_action:
		_running.woken = true
