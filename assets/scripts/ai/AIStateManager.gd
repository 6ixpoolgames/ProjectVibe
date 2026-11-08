## Written by Claude (claude-opus-5-5), 2026-11-09: picks the pawn's current AI state. A part on the pawn, added by PawnInitializer,
## with its states (AIStateBase nodes) as children. Pawn spec section 10.6.
##
## How a state is picked: at each decision, the states are checked from the highest priority down, and the pawn moves to the first
## whose prerequisites hold. That's all. Smoothness comes from memory, which rises and fades steadily; a pawn flickering between
## states is fixed in that state's prerequisites, not with a new mechanism. It works the way AbilityManager picks a locomotion.
##
## When the state changes, it asks the context for a decision with the new state's priority as the reason, so the behaviour
## manager decides at once and the running behaviour may be interrupted (pawn spec 10.7).
##
## How to use it (outside code only talks to the manager):
##   pawn.ai_state_manager.get_current_state()                         # an AIStateBase, or null before the first pick
##   pawn.ai_state_manager.force_state(&"Combat", 120, 50, "scripted")   # skip the normal check for 120 ticks
##   pawn.ai_state_manager.release_forced_state()
##   state_changed(old_state, new_state, reason)                       # for debug readouts and, later, animation
##
## Forcing a state (pawn spec 10.6):
##   - The normal check is skipped for hold_ticks (or until release_forced_state() when hold_ticks is -1), then it takes over again.
##   - A new force replaces the current one only if its priority is equal or higher. A weaker one is refused and logged.
##   - It takes effect at once. The behaviour manager decides at the pawn's next AI step, which is this tick if that hasn't run yet.
##   - Server only: on a client it does nothing and warns.
##
## The fixed order: states are sorted by priority, then name, once, when the manager is ready. Never by the order they were added.
##
## What happens in odd cases (checked in ai/tests/ai_state_manager_selftest.gd):
##   - Its parent isn't a Pawn: it warns and never picks a state.
##   - No state fits: it keeps the current one and warns once. An AIIdleState, which always fits, prevents this.
##   - A state with an automatic name (starting with "@"): it warns, because names must be the same on every run.
##   - force_state with a name it doesn't have: it warns and returns false.
class_name AIStateManager
extends Node

## Sent once each time the state changes. old_state is null for the first pick.
signal state_changed(old_state: AIStateBase, new_state: AIStateBase, reason: String)

var pawn: Pawn = null

var _states: Array[AIStateBase] = [] # highest priority first, then by name
var _current: AIStateBase = null
var _forced: AIStateBase = null
var _force_priority := 0
var _force_until_tick := -1 # -1: until released
var _warned_none_fits := false


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


## The pawn calls this at each decision. Checks the states in order and moves to the first that fits, unless a force holds.
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
		if state.prerequisites_met(context):
			if state != _current:
				_change_to(state, "prerequisites")
			return
	if not _warned_none_fits:
		_warned_none_fits = true
		push_warning("AIStateManager: no state fits on %s, so it stays in %s. An AIIdleState, which always fits, prevents this." % [pawn.name, _current.name if _current else "no state"])


## The pawn calls this every tick, so a force that runs out hands back to the normal check on time, not at the next decision.
func check_force_expiry(tick: int) -> void:
	if _forced and _force_until_tick >= 0 and tick >= _force_until_tick:
		_end_force()


## Moves to this state at once, and holds it for hold_ticks (-1: until release_forced_state()). Returns false, and changes nothing,
## if a stronger force is holding, the state doesn't exist, or this isn't where the AI runs.
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
	if _forced and priority < _force_priority:
		if OS.is_debug_build():
			print("AIStateManager: %s refused a force to %s (priority %d, \"%s\"): %s is forced at priority %d." % [pawn.name, state_name, priority, reason, _forced.name, _force_priority])
		return false
	if _forced and OS.is_debug_build():
		print("AIStateManager: %s: a force to %s (priority %d, \"%s\") replaces the force to %s (priority %d)." % [pawn.name, state_name, priority, reason, _forced.name, _force_priority])
	_forced = state
	_force_priority = priority
	_force_until_tick = -1 if hold_ticks < 0 else _now() + hold_ticks
	if state != _current:
		_change_to(state, reason, priority)
	return true


## Ends a forced state. The normal check picks the state again at once.
func release_forced_state() -> void:
	if _forced:
		_end_force()


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
	state.enter(context)
	state_changed.emit(old, state, reason)
	if context:
		context.request_decision(state.priority if event_priority < 0 else event_priority, false)


func _find(state_name: StringName) -> AIStateBase:
	for state in _states:
		if state.name == state_name:
			return state
	return null


func _now() -> int:
	var driver: Node = get_node_or_null("/root/TickDriver")
	if driver:
		return driver.tick
	return pawn.ai_context.current_tick if pawn and pawn.ai_context else 0


func _collect_states() -> void:
	_states.clear()
	for child in get_children():
		if child is AIStateBase:
			child.manager = self
			_states.append(child)
			if String(child.name).begins_with("@"):
				push_warning("AIStateManager: the state %s has an automatic name, which can differ between runs. Give it a name." % child.name)
	# GDScript note: sort_custom returns true when a should come before b. Names are unique among siblings, so the order is fixed.
	_states.sort_custom(func(a: AIStateBase, b: AIStateBase) -> bool:
		return a.priority > b.priority or (a.priority == b.priority and String(a.name) < String(b.name)))
