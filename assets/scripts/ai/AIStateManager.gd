# Written by Claude (claude-opus-5-5), 2026-11-09. History: ai/CHANGELOG.md.
## Picks the pawn's current AI state: the highest-priority state whose prerequisites hold.
##
## A part on the pawn with its [AIStateBase] nodes as children. At each decision it moves the pawn to the first state, checked from the
## highest priority down, whose prerequisites hold, and a change asks for a decision with the new state's priority as the reason.
## States are sorted by priority, then name, once, when the manager is ready. Outside code only talks to the manager; a forced state
## skips the normal check for a while, and during a tick a force is queued until the pawn's next AI step so the order never depends on
## which pawn went first (scaling spec step 3). Server and offline only. The pawn owns the current state's tag
## ([method AIStateBase.get_tag], such as ai.state.combat) in its [OwnedTags].
## [codeblock]
## pawn.ai_context.state_manager.get_current_state()                         # an AIStateBase, or null before the first pick
## pawn.ai_context.state_manager.force_state(&"Combat", 120, 50, "scripted") # skip the normal check for 120 ticks
## pawn.ai_context.state_manager.release_forced_state()
## [/codeblock]
## Design: pawn spec 10.6 and 10.7.
# REFACTOR: forcing with a priority and a hold, and queueing requests made during a tick, is the same code as AITargetSelector's
# force_target. One small shared helper would keep the two rules from drifting apart (reusable). See CHANGELOG.md.
class_name AIStateManager
extends Node

## Sent once each time the state changes. old_state is null for the first pick.
signal state_changed(old_state: AIStateBase, new_state: AIStateBase, reason: String)

## The pawn this is a part of, or null.
var pawn: Pawn = null

var _states: Array[AIStateBase] = [] # highest priority first, then by name
var _current: AIStateBase = null
var _forced: AIStateBase = null
var _force_priority := 0
var _force_until_tick := -1 # -1: until released
var _warned_none_fits := false
# Forces and releases asked for during a tick, applied at the pawn's next AI step. Each is [state_name, hold_ticks, priority,
# reason], or [] for a release.
var _queued: Array = []


func _init() -> void:
	set_process(false)
	set_physics_process(false)


func _enter_tree() -> void:
	pawn = get_parent() as Pawn
	if pawn == null:
		push_warning("AIStateManager: its parent isn't a Pawn, so it never picks a state.")


func _ready() -> void:
	_collect_states()


## The current state, or null before the first pick.
func get_current_state() -> AIStateBase:
	return _current


## Every state, in the order they're checked.
func get_states() -> Array[AIStateBase]:
	return _states.duplicate()


## True while a forced state is holding.
func is_state_forced() -> bool:
	return _forced != null


## [method AIContextComponent.think] calls this at each decision. Checks the states in order and moves to the first that fits,
## unless a force holds.
func update_state(tick: int) -> void:
	if pawn == null:
		return
	if _forced:
		if _force_until_tick >= 0 and tick >= _force_until_tick:
			_end_force()
		else:
			return
	var context := pawn.ai_context
	for state in _states:
		var started := PerfScopes.begin_detailed() # each state's check timed on its own, in detail (PerfScopes)
		var fits := state.prerequisites_met(context)
		PerfScopes.end(state.perf_name, started)
		if fits:
			if state != _current:
				_change_to(state, "prerequisites")
			return
	if not _warned_none_fits:
		_warned_none_fits = true
		push_warning("AIStateManager: no state fits on %s, so it stays in %s. An AIIdleState, which always fits, prevents this." % [pawn.name, String(_current.name) if _current else "no state"])


## [method AIContextComponent.think] calls this every tick, so a force that runs out hands back to the normal check on time.
func check_force_expiry(tick: int) -> void:
	if _forced and _force_until_tick >= 0 and tick >= _force_until_tick:
		_end_force()


## Moves to this state at once, and holds it for hold_ticks (-1: until [method release_forced_state]). Returns false, and changes
## nothing, if a stronger force is holding, the state doesn't exist, or this isn't where the AI runs. During a tick it's queued
## instead and returns true; the priority check happens when it's applied.
func force_state(state_name: StringName, hold_ticks: int, priority: int, reason: String) -> bool:
	if pawn == null:
		return false
	if not pawn.runs_ai_here():
		push_warning("AIStateManager: force_state(%s) on a client does nothing. The AI only runs on the server." % state_name)
		return false
	var state := _find(state_name)
	if state == null:
		push_warning("AIStateManager: %s has no state called %s, so force_state did nothing." % [pawn.name, state_name])
		return false
	if _during_tick():
		_queued.append([state_name, hold_ticks, priority, reason])
		return true
	return _apply_force(state, hold_ticks, priority, reason)


## [method AIContextComponent.think] calls this at the start of the AI step: applies the forces and releases queued during the
## last tick, in the order they were asked for.
func apply_queued(_tick: int) -> void:
	if _queued.is_empty():
		return
	var queued := _queued
	_queued = []
	for request: Array in queued:
		if request.is_empty():
			if _forced:
				_end_force()
		else:
			var state := _find(request[0])
			if state:
				_apply_force(state, request[1], request[2], request[3])


# What force_state does after finding the state, shared by the queued way and the immediate one.
func _apply_force(state: AIStateBase, hold_ticks: int, priority: int, reason: String) -> bool:
	var state_name := state.name
	if _forced and priority < _force_priority:
		if OS.is_debug_build():
			print("AIStateManager: %s refused a force to %s (priority %d, \"%s\"): %s is forced at priority %d." % [pawn.name, state_name, priority, reason, _forced.name, _force_priority])
		return false
	if _forced and OS.is_debug_build():
		print("AIStateManager: %s: a force to %s (priority %d, \"%s\") replaces the force to %s (priority %d)." % [pawn.name, state_name, priority, reason, _forced.name, _force_priority])
	_forced = state
	_force_priority = priority
	_force_until_tick = -1 if hold_ticks < 0 else _now() + TickDriver.ticks_at_rate(hold_ticks) # hold_ticks are at 60 a second
	if state != _current:
		_change_to(state, reason, priority)
	return true


## Ends a forced state. The normal check picks the state again at once. During a tick it's queued, as forces are.
func release_forced_state() -> void:
	if _during_tick():
		_queued.append([])
		return
	if _forced:
		_end_force()


# True while a tick runs, when a request must wait for the pawn's next AI step.
func _during_tick() -> bool:
	return TickDriver.is_in_tick()


# --- Internals ---


func _end_force() -> void:
	_forced = null
	_force_priority = 0
	_force_until_tick = -1
	if pawn and pawn.ai_context:
		pawn.ai_context.request_decision() # an ordinary decision, which checks the states again


# event_priority: how strong a reason this change is for interrupting the running behaviour. A normal change uses the new
# state's priority; a forced one uses the force's.
func _change_to(state: AIStateBase, reason: String, event_priority: int = -1) -> void:
	var old := _current
	var context := pawn.ai_context
	if old:
		old.exit(context)
	_current = state
	if pawn.owned_tags:
		pawn.owned_tags.set_source(self, [state.get_tag()]) # the AI runs only where the pawn is decided, so this never rolls back
	state.enter(context)
	state_changed.emit(old, state, reason)
	if context:
		context.request_decision(state.priority if event_priority < 0 else event_priority, false)


func _find(state_name: StringName) -> AIStateBase:
	for state in _states:
		if state.name == state_name:
			return state
	return null


# The tick now, from the TickDriver autoload.
func _now() -> int:
	return TickDriver.tick


func _collect_states() -> void:
	_states.clear()
	for child in get_children():
		if child is AIStateBase:
			child.manager = self
			child.perf_name = StringName("ai.state." + String(child.name))
			_states.append(child)
			if String(child.name).begins_with("@"):
				push_warning("AIStateManager: the state %s has an automatic name, which can differ between runs. Give it a name." % child.name)
	# Sorted by priority, then name; names are unique among siblings, so the order is fixed.
	_states.sort_custom(func(a: AIStateBase, b: AIStateBase) -> bool:
		return a.priority > b.priority or (a.priority == b.priority and String(a.name) < String(b.name)))
