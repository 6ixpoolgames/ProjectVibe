# Written by Claude (claude-opus-5-5), 2026-11-09. History: ai/CHANGELOG.md.
## Picks and runs the pawn's AI behaviour, judging between its behaviours by score.
##
## A part on the pawn, added by PawnInitializer (or the game's AI brain, [code]PawnDefaultsRes.ai_brain[/code]), with its behaviours
## ([AIBehaviourBase] nodes) as children. Pawn spec sections 10.7 and 10.8. It only judges between behaviours. Each behaviour holds its
## own checks, score and actions.
## [br]
## At each decision (pawn spec 10.8):
## [br]First, the pawn's inputs ([AIInputs]) start afresh: each is worked out the first time a condition reads it this decision.
## [br]0. Interrupts: if the running behaviour can't be replaced by this decision's reason, it keeps running and that's all.
## [br]1. Valid: the behaviours the current state allows.
## [br]2. Hard rules, with no behaviour code run: drop any on cooldown, needing a target when there's none, or whose action can't
##   start.
## [br]3. Ranges: each one's result can only land between floor = min_score + persistence - jitter and ceiling = max_score +
##   persistence + jitter. One whose ceiling is below the highest floor can't win, so it's dropped. A floor is only certain if its
##   behaviour is available, so the highest floor is taken from the first available behaviour, checking from the highest floor down
##   (usually one is_available() call).
## [br]4. Scoring, highest ceiling first: is_available() and score() run, persistence and this decision's jitter are added. As soon
##   as the next ceiling can't beat the best result, the rest are skipped.
## [br]5. Jitter: each behaviour gets its own offset within ± its jitter, from the context's replayable random numbers.
## [br]6. Ties: results within [member tie_margin] are a tie. With [member randomize_ties] one is picked at random, otherwise the
##   fixed order decides.
## [br]7. Switching: if the winner isn't the running one, the old one's exit() runs, then the new one's enter(), and its persistence
##   starts.
## [br]
## Between decisions only the running behaviour's tick() runs, every tick_interval_ticks, or sooner when a wake-up it asked for
## happens (a walk ending, an ability on its action ending, a tick it named; [method AIBehaviourBase.wake_at]). When it returns
## SUCCEEDED or FAILED, the manager decides at once. When the pawn dies, the running behaviour stops (reason "died").
## [br]
## How to use it (outside code only talks to the manager):
## [codeblock]
## pawn.ai_context.behaviour_manager.get_running_behaviour()
## pawn.ai_context.behaviour_manager.add_persistence_ticks(&"Chase", 60)    # say after landing a hit
## pawn.ai_context.behaviour_manager.set_persistence_speed(&"Chase", 0.5)
## pawn.ai_context.behaviour_manager.set_interrupt_threshold(&"Chase", 25)  # say for a berserk effect
## pawn.ai_context.behaviour_manager.set_score_jitter(&"Wander", 0.2)       # say for a confused effect
## [/codeblock]
## Listen to [signal behaviour_changed] to follow its choices.
## [br]
## [b]C++ makes the decisions; this is the backup[/b] (scaling spec 6.2, the owner's call). With the [AIDecisionModule] in the game,
## a pawn whose [member decides_in] is C++ (the default) has each decision made by AIBatchDecider (native/src/ai_batch_decider.cpp)
## from plain data, and this manager only starts what it chose. The GDScript steps below run for a pawn set to GDScript, a "special
## mind" C++ can't read (a behaviour with its own is_available() or score() code), a game without the C++ library or the module, and
## in shadow mode, where C++ is checked against them. The two follow the same steps: a change to [method decide] goes in both, and
## ai/tests/ai_batch_decider_selftest and ai_conditions_selftest check they agree. C++ keeps its own copy of each pawn's decision state
## (running behaviour, cooldowns, persistence), kept in step by the events this manager passes on (a behaviour stopping, persistence
## and jitter changes).
## [br]
## To see what each decision was made from, set [member decision_listener] (the [AIDecisionRecorder] does). While it's empty, no
## record is made.
## [br]
## The fixed order: behaviours are sorted by name once, when the manager is ready. Never by the order they were added.
## [br]
## What happens in odd cases (checked in ai/tests/ai_behaviour_manager_selftest.gd):
## [br]- Its parent isn't a Pawn: it warns and does nothing.
## [br]- No behaviours at all: it does nothing, so a script can drive the AI controller directly. That's the default part.
## [br]- A state that allows none of its behaviours: the pawn stands still, with a warning naming the state, once.
## [br]- Every allowed behaviour is ruled out for now (cooldowns, no target): the pawn stands still until one can run. No warning.
## [br]- A score() outside min_score to max_score: a warning naming the behaviour, once, in debug builds. It would break step 3 or 4.
## [br]- A behaviour with an automatic name (starting with "@"): it warns, because names must be the same on every run.
## [br]- A behaviour asked for by name that doesn't exist: it warns and does nothing.
class_name AIBehaviourManager
extends Node

## Sent each time the running behaviour changes. Either can be null: nothing was running, or nothing runs now.
signal behaviour_changed(old_behaviour: AIBehaviourBase, new_behaviour: AIBehaviourBase, reason: String)

## Called after every decision of every pawn, with an [AIDecisionRecord] of what it was made from and what it chose, and this
## manager: [code]func(record: AIDecisionRecord, manager: AIBehaviourManager)[/code]. For diagnostics and for checking another
## decider against this one (scaling spec 6.2). Empty, the default: no record is made, which costs one check per decision.
## [br]
## GDScript note: "static" means one for every manager, so one listener hears every pawn.
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
var _warned_states := {} # state name -> true, for "no behaviour is allowed in this state"
var _input_slots := PackedInt32Array() # the worked-out inputs the behaviours' conditions read
var _input_slots_known := false
var _placed_by: AIDecisionModule = null # the module that settled where it decides

const TIE_SALT := 0x7135 # what the tie-breaking random number is for, so it differs from every behaviour's jitter


func _init() -> void:
	set_process(false)
	set_physics_process(false)


func _enter_tree() -> void:
	pawn = get_parent() as Pawn
	if pawn == null:
		push_warning("AIBehaviourManager: its parent isn't a Pawn, so it does nothing.")


func _ready() -> void:
	_collect_behaviours()
	# The running behaviour stops when the pawn dies (the AbilityManager's died).
	var abilities := _sibling_ability_manager()
	if abilities:
		abilities.died.connect(func(_pawn: Pawn, _hit: HitInfo) -> void: stop_running("died"))
		# Wake-ups: the running behaviour's tick() runs at its next AI step after an event it waits for.
		abilities.ability_finished.connect(_on_ability_ended)
		abilities.ability_cancelled.connect(func(ability: AbilityBase, _by: AbilityBase) -> void: _on_ability_ended(ability))
	var navigation := _sibling_navigation_manager()
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


## This brain as plain data: the manager's settings, the AI context's, and each behaviour's, in the fixed order. Everything a
## decision reads that doesn't change from one decision to the next. AIBatchDecider.add_brain() takes it, and AIDecisionRecorder
## saves it. The pawn's own fields are pawn_number, pawn, random_seed and decision_interval_ticks; the rest is the same for every pawn
## with the same behaviour set. Settings changed during play (set_score_jitter, set_interrupt_threshold) show in the next call.
func describe() -> Dictionary:
	var context := pawn.ai_context if pawn else null
	var behaviours: Array = []
	for behaviour in _behaviours:
		var states: Array = []
		for state in behaviour.allowed_states:
			states.append(String(state))
		behaviours.append({
			"name": String(behaviour.name), "name_hash": behaviour.name_hash, "allowed_states": states,
			"max_score": behaviour.max_score, "min_score": behaviour.min_score if behaviour.min_score > -INF else null, # JSON has no infinity
			"needs_target": behaviour.needs_target, "presses_action": String(behaviour.presses_action),
			"cooldown_ticks": behaviour.cooldown_ticks, "cooldown_ticks_at_rate": TickDriver.ticks_at_rate(behaviour.cooldown_ticks),
			"min_run_ticks": behaviour.min_run_ticks,
			"min_run_ticks_at_rate": TickDriver.ticks_at_rate(behaviour.min_run_ticks), # what the interrupt rule compares with
			"interrupt_threshold": behaviour.interrupt_threshold, "cannot_be_interrupted": behaviour.cannot_be_interrupted,
			"score_jitter": behaviour.score_jitter, "effective_jitter": behaviour.effective_jitter(),
			"persistence": behaviour.persistence, "has_persistence_fade": behaviour.persistence_fade != null,
			"persistence_fade": behaviour.persistence_fade.values_at_rate() if behaviour.persistence_fade else null,
			"script": behaviour.get_script().resource_path.get_file() if behaviour.get_script() else "",
			# How C++ judges it: from its conditions and curves, or by asking GDScript for a behaviour with its own code.
			"scorer": "given" if behaviour.has_own_code() else "conditions",
			"conditions": _describe_conditions(behaviour), "score_curves": _describe_curves(behaviour),
		})
	return {
		"pawn_number": context.pawn_number() if context else 0, "pawn": String(pawn.name) if pawn else "",
		"random_seed": context.random_seed if context else 0,
		"decision_interval_ticks": context.decision_interval_ticks if context else 0,
		"default_score_jitter": default_score_jitter, "randomize_ties": randomize_ties,
		"tie_margin": tie_margin, "tie_salt": TIE_SALT, "behaviours": behaviours,
	}


## [method AIContextComponent.run_ai] calls this when a decision is waiting (see [method AIContextComponent.request_decision]). Uses
## up the waiting decision. record: the [AIDecisionRecord] to fill in while [member decision_listener] is set; run_ai passes one
## with the target and state updates in it. Null makes one here if something listens.
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
	# 0. Interrupts.
	if _running and not _can_replace_running(event_priority, event_is_normal, tick):
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
		if not behaviour.is_allowed_in(state_name):
			continue
		any_allowed = true
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
		behaviour.decision_ceiling = behaviour.max_score + behaviour.decision_persistence + jitter
		behaviour.decision_floor = behaviour.min_score + behaviour.decision_persistence - jitter if behaviour.min_score > -INF else -INF
		behaviour.availability_checked = false
		behaviour.decision_scored = false
		_candidates.append(behaviour)
	if not any_allowed and not _warned_states.has(state_name):
		_warned_states[state_name] = true
		push_warning("AIBehaviourManager: no behaviour on %s is allowed in the state %s, so it stands still there." % [pawn.name, state_name])
	# 3, continued. A floor is only certain if its behaviour is available, so the highest floor comes from the first available
	# behaviour, checking from the highest floor down. Otherwise a behaviour with a fixed score that doesn't apply right now, such as
	# Search with nothing certain, would shut out ones that do.
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
		var result := raw + behaviour.decision_persistence + behaviour.decision_jitter
		if best == null or result > best_result + tie_margin:
			best = behaviour
			best_result = result
			_ties.clear()
			_ties.append(behaviour)
		elif result >= best_result - tie_margin:
			_ties.append(behaviour)
	# 6. Ties.
	if _ties.size() > 1:
		_ties.sort_custom(_by_index)
		best = _ties[mini(int(context.random_unit(TIE_SALT) * _ties.size()), _ties.size() - 1)] if randomize_ties else _ties[0]
	# The record is filled in before switching, which changes cooldowns.
	if record:
		_fill_record(record, tick, event_priority, event_is_normal, false)
		record.chosen = best.name if best else &""
	# 7. Switching.
	_switch_to(best, event_is_normal, tick)
	if record:
		decision_listener.call(record, self)
	if cpp_choice != -2:
		module.compare(self, cpp_choice, tick)


## [method AIContextComponent.run_ai] calls this every tick the AI runs, after any decision. Ticks the running behaviour.
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


## Gives this pawn's behaviour a persistence mask: a fade multiplied with its own persistence fade, for this pawn only, so something
## can reshape how one pawn's persistence fades without changing the brain every pawn shares (the owner's call: the hook now, its
## uses later). Null: no mask. Counted from when the behaviour starts, as the fade is.
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


# --- Internals ---


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


# Step 7: starts the chosen behaviour, or stops the running one if nothing was chosen. C++ has already applied the same switch to
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
	record.pawn_number = context.pawn_number()
	record.pawn_name = pawn.name
	record.event_priority = event_priority
	record.event_is_normal = event_is_normal
	record.has_target = context.has_target()
	record.state = context.current_state_name()
	record.running_before = _running.name if _running else &""
	record.running_started_tick = _running.started_tick if _running else -1
	record.kept_by_interrupt = kept_by_interrupt
	record.inputs = context.inputs.values.duplicate()
	if record.cause != AIDecisionRecord.CAUSE_AI_STEP: # no target or state update ran, so before and after are what they are now
		record.note_target_before(context.current_target)
		record.state_before = record.state
		record.state_after = record.state
	if kept_by_interrupt:
		return # no behaviour was looked at
	for behaviour in _behaviours:
		var rule := AIDecisionRecord.RULE_NONE
		if not behaviour.is_allowed_in(record.state):
			rule = AIDecisionRecord.RULE_STATE
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
	# GDScript note: names are unique among siblings, so sorting by name gives one fixed order whatever order they were added in.
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


# The pawn's NavigationManager, a sibling, found at _ready, or null.
# REFACTOR: the same lookup as _sibling_ability_manager below (reusable). See CHANGELOG.md.
func _sibling_navigation_manager() -> NavigationManager:
	if pawn == null:
		return null
	for child in pawn.get_children():
		if child is NavigationManager:
			return child
	return null


# The pawn's AbilityManager, a sibling, found at _ready (every part is in the pawn by then), or null.
# REFACTOR: the same lookup as AIContextComponent's (reusable). See CHANGELOG.md.
func _sibling_ability_manager() -> AbilityManager:
	if pawn == null:
		return null
	for child in pawn.get_children():
		if child is AbilityManager:
			return child
	return null
