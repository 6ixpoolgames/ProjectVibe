## Claude (claude-opus-5-5), 2026-11-03: rewritten to actually choose and run behaviours (utility selection).
## Kept from the original: premade/overwrite handling, registration, and the 1-key debug print.
##
## Picks which child behaviour (AIBehaviourComponentBase) runs, using utility scores.
##
## HOW A DECISION WORKS (every decision_interval seconds, default 0.2):
##  1. Candidates = child behaviours that are
##       - eligible in the current AI state (stateName empty/"All", or equal to the state),
##       - not on cooldown, and
##       - is_available(context) == true.
##  2. Each candidate's score = score(context) + random 0..randomness + commitment_bonus (only if it's running).
##  3. The highest score wins.
##
## CORNER CASES (expected behaviour):
##  - Score 0 or below: not a candidate. 0 means "I don't want to run".
##  - Exact tie: the running behaviour stays. Between others, the one higher in the scene tree wins,
##    so drag a node up to prefer it.
##  - The running behaviour stops being a candidate (state changed, unavailable, score <= 0):
##    it is ALWAYS stopped, even with NEVER_UNTIL_DONE. Eligibility beats interrupt policy, so
##    "can't run any more" always wins over "don't interrupt me". Exit reason: STATE_CHANGED or UNAVAILABLE.
##  - Something scores higher while one runs: the running one is asked can_be_interrupted_by(new).
##    Default policy NEVER_UNTIL_DONE says no: it keeps running until it finishes or becomes ineligible.
##    ALWAYS says yes (after min_run_time, default 0). (Claude 2026-11-04: default switched to NEVER_UNTIL_DONE)
##  - A NEVER_UNTIL_DONE behaviour whose tick() never returns SUCCEEDED/FAILED holds the pawn until it
##    becomes unavailable. Endless behaviours (idle, patrol loops) should use ALWAYS.
##  - Two behaviours with nearly equal, changing scores can swap back and forth. That's expected with
##    pure utility; if it bothers you, raise one's commitment_bonus or min_run_time.
##  - tick() returns SUCCEEDED/FAILED: the behaviour exits, its cooldown starts, and a new decision
##    happens straight away (no idle gap). With cooldown 0 it can be picked again at once,
##    which is how you make a looping behaviour.
##  - No candidates at all: nothing runs. The pawn gets no AI movement commands, so it stops.
##  - The AI state changes (AIStateManagerComponent.state_changed): decide on the next physics frame. (Claude 2026-11-04)
##  - A memory fact of a type listed in any behaviour's wake_on_facts is ADDED: decide on the next
##    physics frame instead of waiting. Refreshes of known facts don't wake it (they happen every poll).
##  - The running behaviour is ticked once per decision interval with delta = time since its last tick,
##    not every frame. Steering/physics still run every frame in the controllers and pawn.
##  - Missing parts (no AI core, memory, state manager or movement controller): it still runs.
##    Those context fields are null and context helpers return false.
##  - No known AI state: the state gate is skipped and every behaviour is eligible.
extends Node
class_name AIBehaviourManagerComponent

signal behaviour_changed(old: AIBehaviourComponentBase, new: AIBehaviourComponentBase)

@export var isPremade:=false
@export var decision_interval: float = 0.2 ## seconds between decisions (5 per second)
@export var active:= true ## turn off to freeze this pawn's decisions

var allBehaviours: Array[AIBehaviourComponentBase] = []
var allBehaviourNames: Array[StringName] = []
var current: AIBehaviourComponentBase = null
var context:= AIContext.new()

var aiCore: AICoreComponent
var pawn: CharacterPawn3D
var nexus: PawnNexusComponent

var _time: float = 0.0 ## manager clock, in seconds. Cooldowns use this, not wall time
var _sinceDecision: float = 0.0
var _sinceTick: float = 0.0
var _wakeRequested:= false
var _watchedMemory: AIMemoryComponent = null


func _enter_tree()->void:
	if get_parent() is AICoreComponent:
		aiCore = get_parent()
		nexus = aiCore.nexus
		if nexus:
			pawn = nexus.pawn
		_check_overwrite_premade()
		if not isForDeletion:
			aiCore.aiBehaviourManager = self
		context = aiCore.context # Claude 2026-11-04: share the AI core's context (and blackboard) with the state manager


var isForDeletion:= false
func _check_overwrite_premade()->void:
	#region check if should overwrite and cleanup extra nodes
	if nexus.allow_overwrites.AIBehaviourManager:
		if aiCore.aiBehaviourManager != self:
			if isPremade:
				isForDeletion = true
				self.queue_free()
				return
			else:
				aiCore.aiBehaviourManager.queue_free()
	else:
		if aiCore.aiBehaviourManager != self:
			if isPremade:
				aiCore.aiBehaviourManager.queue_free()
			else:
				isForDeletion = true
				self.queue_free()
				return
	#endregion
	aiCore.aiBehaviourManager = self


func _exit_tree() -> void:
	if current:
		_stop_current(AIBehaviourComponentBase.ExitReason.REMOVED)


func request_register_behaviour_component(behaviour: AIBehaviourComponentBase):
	if allBehaviours.has(behaviour):
		return
	if allBehaviourNames.has(behaviour.behaviourID):
		print(behaviour, " shares behaviourID '", behaviour.behaviourID, "' with another behaviour. Both will still run; rename one for clearer debugging")
	allBehaviours.append(behaviour)
	allBehaviourNames.append(behaviour.behaviourID)


func _physics_process(delta: float) -> void:
	if active:
		update(delta)


##advances the manager by [param delta] seconds. Called every physics frame; public so tests can drive it
func update(delta: float) -> void:
	_time += delta
	_sinceDecision += delta
	_sinceTick += delta
	if current:
		current.runTime += delta
	if _sinceDecision >= decision_interval or _wakeRequested:
		_wakeRequested = false
		_sinceDecision = 0.0
		decide()
		_tick_current()


##makes a decision right now (see the header for the rules)
func decide() -> void:
	context.refresh()
	_watch_memory()
	_watch_state()
	var best: AIBehaviourComponentBase = null
	var bestScore := -INF
	var currentIsCandidate := false
	for b in _behaviours_in_tree_order():
		b.set_references_from(context)
		var s := _candidate_score(b)
		b.lastScore = s
		if s <= 0.0:
			continue
		if b == current:
			currentIsCandidate = true
		if s > bestScore or (s == bestScore and b == current): #ties: running one stays; otherwise first in tree wins
			best = b
			bestScore = s

	if current and not currentIsCandidate:
		var reason := AIBehaviourComponentBase.ExitReason.UNAVAILABLE
		if not current.is_eligible_in_state(context.currentState):
			reason = AIBehaviourComponentBase.ExitReason.STATE_CHANGED
		_switch_to(best, reason)
	elif best != current:
		if current == null or current.can_be_interrupted_by(best):
			_switch_to(best, AIBehaviourComponentBase.ExitReason.INTERRUPTED)


func _candidate_score(b: AIBehaviourComponentBase) -> float:
	if not b.is_eligible_in_state(context.currentState):
		return 0.0
	if b != current and _time < b.cooldownUntil:
		return 0.0
	if not b.is_available(context):
		return 0.0
	var s := b.score(context)
	if s <= 0.0:
		return s
	if b.randomness > 0.0:
		s += randf() * b.randomness
	if b == current:
		s += b.commitment_bonus
	return s


func _tick_current() -> void:
	if current == null:
		_sinceTick = 0.0
		return
	var status := current.tick(context, _sinceTick)
	_sinceTick = 0.0
	if status == AIBehaviourComponentBase.Status.RUNNING:
		return
	var reason := AIBehaviourComponentBase.ExitReason.SUCCEEDED if status == AIBehaviourComponentBase.Status.SUCCEEDED else AIBehaviourComponentBase.ExitReason.FAILED
	_stop_current(reason)
	decide() #pick the next one now rather than idling until the next interval


func _switch_to(next: AIBehaviourComponentBase, reason: AIBehaviourComponentBase.ExitReason) -> void:
	var old := current
	if current:
		_stop_current(reason)
	if next:
		current = next
		next.isRunning = true
		next.runTime = 0.0
		_sinceTick = 0.0
		next.enter(context)
	behaviour_changed.emit(old, current)


func _stop_current(reason: AIBehaviourComponentBase.ExitReason) -> void:
	var b := current
	current = null
	b.isRunning = false
	if reason == AIBehaviourComponentBase.ExitReason.SUCCEEDED or reason == AIBehaviourComponentBase.ExitReason.FAILED:
		b.cooldownUntil = _time + b.cooldown
	b.exit(context, reason)


func _behaviours_in_tree_order() -> Array[AIBehaviourComponentBase]:
	var out: Array[AIBehaviourComponentBase] = []
	for c in get_children():
		if c is AIBehaviourComponentBase and allBehaviours.has(c):
			out.append(c)
	return out


#connects to the memory's fact_added signal once memory exists, for wake_on_facts
func _watch_memory() -> void:
	if context.memory == _watchedMemory:
		return
	if _watchedMemory and is_instance_valid(_watchedMemory):
		_watchedMemory.fact_added.disconnect(_on_fact_added)
	_watchedMemory = context.memory
	if _watchedMemory:
		_watchedMemory.fact_added.connect(_on_fact_added)


# Claude 2026-11-04: a state change re-decides on the next update, so behaviours switch the moment the state does
var _watchedStates: AIStateManagerComponent = null
func _watch_state() -> void:
	var states: AIStateManagerComponent = aiCore.aiStateManager if aiCore else null
	if states == _watchedStates:
		return
	if _watchedStates and is_instance_valid(_watchedStates):
		_watchedStates.state_changed.disconnect(_on_state_changed)
	_watchedStates = states
	if _watchedStates:
		_watchedStates.state_changed.connect(_on_state_changed)


##can also be connected by hand (tests, or a state manager living elsewhere)
func _on_state_changed(_old: StringName, _new: StringName) -> void:
	_wakeRequested = true


func _on_fact_added(fact: AIMemoryFact) -> void:
	for b in allBehaviours:
		if b.wake_on_facts.has(fact.type):
			_wakeRequested = true
			return


func get_debug_text() -> String:
	var lines: PackedStringArray = ["state: %s" % (context.currentState if context.currentState != &"" else "(none)")]
	for b in _behaviours_in_tree_order():
		lines.append(("> " if b == current else "  ") + b.get_debug_text())
	return "\n".join(lines)


##debug function, prints all behaviours and scores for validation
func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed:
		if event.keycode == KEY_1:
			print(pawn, "\n", get_debug_text())
