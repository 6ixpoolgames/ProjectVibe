# Written by Claude (claude-opus-5-5), 2026-11-09. History: ai/CHANGELOG.md.
## Picks the pawn's current AI state: the highest-priority state whose prerequisites hold.
##
## A component of the pawn's AIManager with its [AIStateBase] nodes as children. At each decision it moves the pawn to the first state, checked from the
## highest priority down, whose prerequisites hold, and a change asks for a decision with the new state's priority as the reason.
## States are sorted by priority, then name, once, when the manager is ready. Server and offline only. The pawn owns the current
## state's tag ([method AIStateBase.get_tag], such as ai.state.combat) in its [OwnedTags], so behaviours gate on it. There's no
## forcing: a scripted state is a state whose prerequisites read a tag the script grants (pawn spec 16.5).
## [codeblock]
## pawn.ai.state_manager.get_current_state()   # an AIStateBase, or null before the first pick
## [/codeblock]
## Design: pawn spec 10.6, 16.5.
class_name AIStateManager
extends Node

## Sent once each time the state changes. old_state is null for the first pick.
signal state_changed(old_state: AIStateBase, new_state: AIStateBase, reason: String)

## The pawn this is a part of, or null.
var pawn: Pawn = null

var _states: Array[AIStateBase] = [] # highest priority first, then by name
var _current: AIStateBase = null
var _warned_none_fits := false


func _init() -> void:
	set_process(false)
	set_physics_process(false)


func _enter_tree() -> void:
	var ai := get_parent() as AIManager
	pawn = ai.pawn if ai else null
	if pawn == null:
		push_warning("AIStateManager: its parent isn't a pawn's AIManager, so it never picks a state.")


func _ready() -> void:
	_collect_states()


## The current state, or null before the first pick.
func get_current_state() -> AIStateBase:
	return _current


## Every state, in the order they're checked.
func get_states() -> Array[AIStateBase]:
	return _states.duplicate()


## [method AIManager.think] calls this at each decision. Checks the states in order and moves to the first that fits.
func update_state(_tick: int) -> void:
	if pawn == null:
		return
	var context := pawn.ai
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


# --- Internals ---


# The new state's priority is how strong a reason the change is for interrupting the running behaviour.
func _change_to(state: AIStateBase, reason: String) -> void:
	var old := _current
	var context := pawn.ai
	if old:
		old.exit(context)
	_current = state
	if pawn.owned_tags:
		pawn.owned_tags.set_source(self, [state.get_tag()]) # the AI runs only where the pawn is decided, so this never rolls back
	state.enter(context)
	state_changed.emit(old, state, reason)
	if context:
		context.request_decision(state.priority, false)


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
