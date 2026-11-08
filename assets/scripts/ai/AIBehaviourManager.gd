## Written by Claude (claude-opus-5-5), 2026-11-09: picks and runs the pawn's AI behaviour. A part on the pawn, added by
## PawnInitializer, with its behaviours (AIBehaviourBase nodes) as children. Pawn spec sections 10.7 and 10.8.
##
## It only judges between behaviours. Each behaviour holds its own checks, score and actions.
##
## At each decision (pawn spec 10.8):
##   0. Interrupts: if the running behaviour can't be replaced by this decision's reason, it keeps running and that's all.
##   1. Valid: the behaviours the current state allows.
##   2. Hard rules, with no behaviour code run: drop any on cooldown, needing a target when there's none, or whose action can't start.
##   3. Ranges: each one's result can only land between floor = min_score + persistence - jitter and
##      ceiling = max_score + persistence + jitter. One whose ceiling is below the highest floor can't win, so it's dropped.
##      Claude 2026-11-09: a floor is only certain if its behaviour is available, so the highest floor is taken from the first
##      available behaviour, checking from the highest floor down (usually one is_available() call).
##   4. Scoring, highest ceiling first: is_available() and score() run, persistence and this decision's jitter are added. As soon as
##      the next ceiling can't beat the best result, the rest are skipped.
##   5. Jitter: each behaviour gets its own offset within ± its jitter, from the context's replayable random numbers.
##   6. Ties: results within tie_margin are a tie. With randomize_ties one is picked at random, otherwise the fixed order decides.
##   7. Switching: if the winner isn't the running one, the old one's exit() runs, then the new one's enter(), and its persistence
##      starts.
## Between decisions only the running behaviour's tick() runs, every tick_interval_ticks (Claude 2026-11-09). When it returns
## SUCCEEDED or FAILED, the manager decides at once.
##
## How to use it (outside code only talks to the manager):
##   pawn.ai_behaviour_manager.get_running_behaviour()
##   pawn.ai_behaviour_manager.add_persistence_ticks(&"Chase", 60)       # say after landing a hit
##   pawn.ai_behaviour_manager.set_persistence_speed(&"Chase", 0.5)
##   pawn.ai_behaviour_manager.set_interrupt_threshold(&"Chase", 25)     # say for a berserk effect
##   pawn.ai_behaviour_manager.set_score_jitter(&"Wander", 0.2)          # say for a confused effect
##   behaviour_changed(old_behaviour, new_behaviour, reason)
##
## The fixed order: behaviours are sorted by name once, when the manager is ready. Never by the order they were added.
##
## What happens in odd cases (checked in ai/tests/ai_behaviour_manager_selftest.gd):
##   - Its parent isn't a Pawn: it warns and does nothing.
##   - No behaviours at all: it does nothing, so a script can drive the AI controller directly. That's the default part.
##   - A state that allows none of its behaviours: the pawn stands still, with a warning naming the state, once.
##   - Every allowed behaviour is ruled out for now (cooldowns, no target): the pawn stands still until one can run. No warning.
##   - A score() outside min_score to max_score: a warning naming the behaviour, once, in debug builds. It would break step 3 or 4.
##   - A behaviour with an automatic name (starting with "@"): it warns, because names must be the same on every run.
##   - A behaviour asked for by name that doesn't exist: it warns and does nothing.
class_name AIBehaviourManager
extends Node

## Sent each time the running behaviour changes. Either can be null: nothing was running, or nothing runs now.
signal behaviour_changed(old_behaviour: AIBehaviourBase, new_behaviour: AIBehaviourBase, reason: String)

## The jitter for behaviours whose own score_jitter is -1. 0: no randomness.
@export var default_score_jitter := 0.0
## On: results that tie are picked between at random (replayably). Off: the fixed order decides.
@export var randomize_ties := false
## Results closer than this count as a tie.
@export var tie_margin := 0.0001

var pawn: Pawn = null

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


func _exit_tree() -> void:
	if _running and pawn:
		_stop_running("removed", pawn.ai_context.current_tick if pawn.ai_context else 0)


## The behaviour running now, or null.
func get_running_behaviour() -> AIBehaviourBase:
	return _running


## Every behaviour, in the fixed order.
func get_behaviours() -> Array[AIBehaviourBase]:
	return _behaviours.duplicate()


## The pawn calls this when a decision is waiting (see AIContextComponent.request_decision). Uses up the waiting decision.
func decide(tick: int) -> void:
	if pawn == null or pawn.ai_context == null:
		return
	var context := pawn.ai_context
	var event_priority := context.waiting_event_priority()
	var event_is_normal := context.waiting_event_is_normal()
	context.clear_decision()
	if _behaviours.is_empty():
		return
	# 0. Interrupts.
	if _running and not _can_replace_running(event_priority, event_is_normal, tick):
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
		_candidates.append(behaviour)
	if not any_allowed and not _warned_states.has(state_name):
		_warned_states[state_name] = true
		push_warning("AIBehaviourManager: no behaviour on %s is allowed in the state %s, so it stands still there." % [pawn.name, state_name])
	# 3, continued. A floor is only certain if its behaviour is available, so the highest floor comes from the first available
	# behaviour, checking from the highest floor down. (Claude 2026-11-09: found in step 8b. A behaviour with a fixed score that
	# didn't apply right now, such as Search with nothing certain, would otherwise shut out ones that did.)
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
	# 7. Switching.
	if best == _running:
		return
	var reason := "decision" if event_is_normal else "interrupted"
	if best == null:
		_stop_running(reason, tick)
		if context.controller:
			context.controller.release_all() # nothing can run: stand still
		return
	_start(best, reason, tick)


## The pawn calls this every tick the AI runs, after any decision. Ticks the running behaviour.
func tick_running(tick: int) -> void:
	if _running == null or pawn == null:
		return
	# Claude 2026-11-09: only every tick_interval_ticks, counted from when it started (ai_stress: Chase ticking every tick was 1.8 ms
	# of a 200-pawn crowd).
	if _running.tick_interval_ticks > 1 and posmod(tick - _running.started_tick, _running.tick_interval_ticks) != 0:
		return
	var context := pawn.ai_context
	var status := _running.tick(context)
	if status == AIBehaviourBase.Status.RUNNING:
		return
	_stop_running("succeeded" if status == AIBehaviourBase.Status.SUCCEEDED else "failed", tick)
	context.request_decision()
	decide(tick)


## Claude 2026-11-09: stops the running behaviour, if any; its exit() gets this reason. The pawn calls it when it dies.
func stop_running(reason: String) -> void:
	_stop_running(reason, _now())


## Moves a behaviour's persistence back along its fade by this many ticks, so it lasts longer. Negative: it ends sooner.
func add_persistence_ticks(behaviour_name: StringName, ticks: float) -> void:
	var behaviour := _find(behaviour_name)
	if behaviour:
		behaviour.add_persistence_ticks(ticks, _now())


## How fast a behaviour's persistence fades from now on: 1.0 normally, 0.5 for half speed.
func set_persistence_speed(behaviour_name: StringName, speed: float) -> void:
	var behaviour := _find(behaviour_name)
	if behaviour:
		behaviour.set_persistence_speed(speed, _now())


## Changes a behaviour's interrupt threshold, even while it runs.
func set_interrupt_threshold(behaviour_name: StringName, threshold: int) -> void:
	var behaviour := _find(behaviour_name)
	if behaviour:
		behaviour.interrupt_threshold = threshold


## Changes a behaviour's jitter. -1: back to default_score_jitter.
func set_score_jitter(behaviour_name: StringName, jitter: float) -> void:
	var behaviour := _find(behaviour_name)
	if behaviour:
		behaviour.score_jitter = jitter


# --- Internals ---


# Pawn spec 10.7: an event replaces the running behaviour only if it isn't cannot_be_interrupted, the event's priority reaches its
# interrupt_threshold, and, for an ordinary decision, its min_run_ticks have passed.
func _can_replace_running(event_priority: int, event_is_normal: bool, tick: int) -> bool:
	if _running.cannot_be_interrupted:
		return false
	if event_priority < _running.interrupt_threshold:
		return false
	# min_run_ticks 0 means no minimum at all, whatever the ticks say.
	if event_is_normal and _running.min_run_ticks > 0 and tick - _running.started_tick < _running.min_run_ticks:
		return false
	return true


func _start(behaviour: AIBehaviourBase, reason: String, tick: int) -> void:
	var old := _running
	if old:
		old.exit(pawn.ai_context, reason)
		old.ended_tick = tick
	_running = behaviour
	behaviour.started_tick = tick
	behaviour.start_persistence(tick)
	behaviour.enter(pawn.ai_context)
	behaviour_changed.emit(old, behaviour, reason)


func _stop_running(reason: String, tick: int) -> void:
	if _running == null:
		return
	var old := _running
	_running = null
	old.exit(pawn.ai_context, reason)
	old.ended_tick = tick
	behaviour_changed.emit(old, null, reason)


# is_available() once per decision: the floor check and the scoring may both ask.
func _is_available(behaviour: AIBehaviourBase, context: AIContextComponent) -> bool:
	if not behaviour.availability_checked:
		behaviour.availability_checked = true
		behaviour.decision_available = behaviour.is_available(context)
	return behaviour.decision_available


func _could_press(action: StringName) -> bool:
	return pawn.ability_manager != null and pawn.ability_manager.can_start(action)


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
	push_warning("AIBehaviourManager: %s has no behaviour called %s." % [pawn.name if pawn else "this pawn", behaviour_name])
	return null


func _now() -> int:
	var driver: Node = get_node_or_null("/root/TickDriver")
	if driver:
		return driver.tick
	return pawn.ai_context.current_tick if pawn and pawn.ai_context else 0


func _collect_behaviours() -> void:
	_behaviours.clear()
	for child in get_children():
		if child is AIBehaviourBase:
			child.manager = self
			child.pawn = pawn
			child.name_hash = String(child.name).hash()
			_behaviours.append(child)
			if String(child.name).begins_with("@"):
				push_warning("AIBehaviourManager: the behaviour %s has an automatic name, which can differ between runs. Give it a name." % child.name)
	# GDScript note: names are unique among siblings, so sorting by name gives one fixed order whatever order they were added in.
	_behaviours.sort_custom(func(a: AIBehaviourBase, b: AIBehaviourBase) -> bool: return String(a.name) < String(b.name))
	for i in _behaviours.size():
		_behaviours[i].decision_index = i
