## Claude (claude-opus-5-5), 2026-11-04: rewritten so states actually register, get picked and change.
## Kept from the original: class name, premade/overwrite handling, request_register_state(), set_references().
##
## Decides which child state (AIStateComponentBase) the AI is in. Behaviours read it through
## context.currentState to decide whether they're eligible (their stateName).
##
## HOW AN EVALUATION WORKS (every evaluation_interval seconds, default 0.2):
##  1. If a forced state is active (force_state(), not yet expired), it's the target.
##  2. Otherwise the target is the valid state (is_valid(context) == true) with the LOWEST state_priority.
##  3. If no state is valid, the target is default_state (by name, default "Idle").
##  4. Moving from the current state to the target needs the current state's permission:
##       current.can_exit(context) must be true, and it must have been current for min_time_in_state.
##  5. On a change: old.exit(), new.enter(), state_changed is emitted, and the behaviour manager re-decides at once.
##
## CORNER CASES (expected behaviour):
##  - Equal priorities, both valid: the one higher in the scene tree wins.
##  - The current state is still valid but a more important one becomes valid: switch (if allowed by 4).
##  - can_exit() false (e.g. Dead): the state never changes again, forced states included.
##  - Forced states skip min_time_in_state but still respect can_exit(), so stunning a dead pawn does nothing.
##  - force_state() with an unknown name returns false and changes nothing. A new force replaces an old one.
##    seconds <= 0 means "until clear_forced_state()".
##  - default_state names a state that doesn't exist (or is empty): no state, currentState is &"".
##  - No state at all: behaviours' state gate is skipped, so every behaviour is eligible.
##  - Two states with the same name: the first in the tree is used, and a warning is printed.
##  - Missing parts (no memory, no stats): the context fields are null; states should treat that as
##    "not valid" (the example states do), so the pawn falls back to default_state.
extends Node
class_name AIStateManagerComponent

signal state_changed(old_state: StringName, new_state: StringName)

#node referrences
var aiCore: AICoreComponent
var nexus:PawnNexusComponent

@export var isPremade:= false
@export var evaluation_interval: float = 0.2 ## seconds between evaluations
@export var default_state: StringName = &"Idle" ## used when no state is valid. Empty or unknown = no state
@export var active:= true ## turn off to freeze this pawn's state

var allStates: Array[AIStateComponentBase] = []
var current: AIStateComponentBase = null
var context:= AIContext.new() ## replaced by the AI core's shared context when there is one

var _sinceEvaluation: float = 0.0
var _forced: AIStateComponentBase = null
var _forcedTimeLeft: float = 0.0 ## <= 0 with _forced set = until cleared


func _enter_tree() -> void:
	if get_parent() is AICoreComponent:
		aiCore = get_parent()
		nexus = aiCore.nexus
		context = aiCore.context
		_check_overwrite_premade()
		if not isForDeletion and nexus:
			nexus.aiStateManager = self

var isForDeletion:= false
func _check_overwrite_premade()->void:
	#region check if should overwrite and cleanup extra nodes
	if nexus.allow_overwrites.AIStateManager:
		if aiCore.aiStateManager != self:
			if isPremade:
				isForDeletion = true
				self.queue_free()
				return
			else:
				aiCore.aiStateManager.queue_free()
	else:
		if aiCore.aiStateManager != self:
			if isPremade:
				aiCore.aiStateManager.queue_free()
			else:
				isForDeletion = true
				self.queue_free()
				return
	#endregion
	aiCore.aiStateManager = self


func request_register_state(state: AIStateComponentBase)->void:
	if allStates.has(state):
		return
	for s in allStates:
		if s.get_state_name() == state.get_state_name():
			print(state.get_state_name(), " is used by two states under ", self, "; the first one in the tree wins")
	allStates.append(state)
	state.set_references(nexus)


func _physics_process(delta: float) -> void:
	if active:
		update(delta)


##advances the manager by [param delta] seconds. Called every physics frame; public so tests can drive it
func update(delta: float) -> void:
	_sinceEvaluation += delta
	if current:
		current.timeInState += delta
	if _forced and _forcedTimeLeft > 0.0:
		_forcedTimeLeft -= delta
		if _forcedTimeLeft <= 0.0:
			_forced = null
	if _sinceEvaluation >= evaluation_interval:
		_sinceEvaluation = 0.0
		evaluate()


##picks the state right now (see the header for the rules)
func evaluate() -> void:
	context.refresh()
	var target := _pick_target()
	if target == current:
		return
	if current:
		if not current.can_exit(context):
			return
		if target != _forced and current.timeInState < current.min_time_in_state:
			return
	_change_to(target)


##puts the AI in state [param state_name] for [param seconds] (<= 0: until clear_forced_state()),
##ignoring validity and priorities. For stuns, scripted moments, etc. False if no such state exists
func force_state(state_name: StringName, seconds: float = 0.0) -> bool:
	var state := get_state(state_name)
	if state == null:
		return false
	_forced = state
	_forcedTimeLeft = seconds
	evaluate()
	return true


func clear_forced_state() -> void:
	_forced = null
	_forcedTimeLeft = 0.0
	evaluate()


func get_current_state() -> AIStateComponentBase:
	return current


##the current state's name, or &"" when there is none. Read by AIContext.refresh()
func get_current_state_name() -> StringName:
	return current.get_state_name() if current else &""


##the first registered state with this name (in tree order), or null
func get_state(state_name: StringName) -> AIStateComponentBase:
	if state_name == &"":
		return null
	for s in _states_in_tree_order():
		if s.get_state_name() == state_name:
			return s
	return null


func _pick_target() -> AIStateComponentBase:
	if _forced and is_instance_valid(_forced):
		return _forced
	var best: AIStateComponentBase = null
	for s in _states_in_tree_order():
		if (best == null or s.state_priority < best.state_priority) and s.is_valid(context):
			best = s
	if best == null:
		best = get_state(default_state)
	return best


func _change_to(target: AIStateComponentBase) -> void:
	var old := current
	if old:
		old.isCurrent = false
		old.exit(context)
	current = target
	if current:
		current.isCurrent = true
		current.timeInState = 0.0
	context.currentState = get_current_state_name() #so enter() and listeners already see the new state
	if current:
		current.enter(context)
	state_changed.emit(old.get_state_name() if old else &"", get_current_state_name())


func _states_in_tree_order() -> Array[AIStateComponentBase]:
	var out: Array[AIStateComponentBase] = []
	for c in get_children():
		if c is AIStateComponentBase and allStates.has(c):
			out.append(c)
	return out


func set_references(nexusRef:PawnNexusComponent)->void:
	nexus = nexusRef


##original API used by AICoreComponent; same as setting active
func set_is_state_manager_active(isActive: bool) -> void:
	active = isActive


func get_debug_text() -> String:
	var lines: PackedStringArray = ["state: %s%s" % [get_current_state_name() if current else "(none)", "  (forced)" if _forced else ""]]
	for s in _states_in_tree_order():
		lines.append("%s %s  prio %d" % [">" if s == current else " ", s.get_state_name(), s.state_priority])
	return "\n".join(lines)
