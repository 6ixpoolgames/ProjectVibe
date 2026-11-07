## Written by Claude (claude-opus-5-5), 2026-11-07: starts, runs and stops a pawn's abilities. A part on the pawn, added by
## PawnInitializer, with the abilities as its children. Pawn spec section 8.
##
## The pawn calls tick_abilities(dt) once per tick, after its input arrives and before move_and_slide. Each tick, in this order:
##   1. Counters: cooldowns and waiting presses count down, and every ability's every_tick() runs.
##   2. Locomotion: exactly one runs. A locomotion ability whose trigger_action is held, and which can run, wins, by priority and then
##      tree order (Sprint). Otherwise the default runs: the first locomotion ability with no trigger_action (Walk).
##   3. Actions: running timed ones tick. A pressed action starts the first ability bound to it that can start. One that can't yet
##      keeps the press for its buffer_window and tries again each tick.
## Everything that persists between ticks lives on the abilities and rolls back (see AbilityBase), so this node keeps none.
##
## How to use it (outside code only talks to the manager):
##   pawn.ability_manager.can_start(&"jump")    # could a press start something right now? For an AI deciding what to press
##   pawn.ability_manager.is_busy()             # is a timed action running?
##   pawn.ability_manager.has_action(&"sprint") # does anything answer to this action?
##   pawn.ability_manager.cancel(&"sprint")     # stops whatever is running for this action
##
## Lockouts: while an ability runs, the categories in its locks_out can't start, and a locked-out locomotion ability stops steering
## (the pawn slows to a stop). Categories are tags (TagRegistry), so locking &"movement" also locks &"movement.jump".
##
## What happens in odd cases (all checked in tests/ability_selftest.gd):
##   - Its parent isn't a Pawn: it warns and does nothing.
##   - No locomotion with an empty trigger_action: when nothing else runs, nothing steers, and the pawn keeps its velocity.
##   - Two abilities on one action: only one starts per press, and the others' waiting presses are dropped.
##   - No TickStateComponent on the pawn: abilities work, but nothing about them rolls back.
class_name AbilityManager
extends Node

signal ability_started(ability: AbilityBase)
signal ability_finished(ability: AbilityBase)

var pawn: Pawn = null

var _abilities: Array[AbilityBase] = [] # every ability, in run order: by priority, then tree order
var _locomotions: Array[AbilityBase] = []
var _actions: Array[AbilityBase] = []
var _default_locomotion: AbilityBase = null
var _locked_mask := 0 # categories locked right now, as bits
var _tick_rate := 60.0


func _init() -> void:
	set_process(false)
	set_physics_process(false)


func _enter_tree() -> void:
	pawn = get_parent() as Pawn
	if pawn == null:
		push_warning("AbilityManager: its parent isn't a Pawn, so it does nothing.")


func _ready() -> void:
	var driver: Node = get_node_or_null("/root/TickDriver")
	if driver:
		_tick_rate = float(driver.get_tick_rate())
	_collect_abilities()
	_register_rollback_state()


## The pawn calls this once per tick. dt is the fixed tick length.
func tick_abilities(dt: float) -> void:
	if pawn == null:
		return
	_locked_mask = 0
	for ability in _actions:
		if ability.is_running_timed():
			_locked_mask |= ability.locks_out_mask
	for ability in _abilities:
		if ability.cooldown_ticks_left > 0:
			ability.cooldown_ticks_left -= 1
		if ability.buffer_ticks_left > 0:
			ability.buffer_ticks_left -= 1
		ability.every_tick(dt)
	_run_locomotion(dt)
	_run_actions(dt)


## True if pressing this action now would start something.
func can_start(action: StringName) -> bool:
	for ability in _abilities:
		if ability.trigger_action == action and not ability.is_running_timed() and _is_ready(ability):
			return true
	return false


## True while a timed action is running, such as an attack's swing.
func is_busy() -> bool:
	for ability in _actions:
		if ability.is_running_timed():
			return true
	return false


## True if any ability answers to this action.
func has_action(action: StringName) -> bool:
	for ability in _abilities:
		if ability.trigger_action == action:
			return true
	return false


## Stops whatever is running for this action, which starts its cooldown.
func cancel(action: StringName) -> void:
	for ability in _abilities:
		if ability.trigger_action == action and ability.is_running_timed():
			_finish(ability)


## True if this ability's category is locked out right now.
func is_locked(ability: AbilityBase) -> bool:
	return ability.category_mask & _locked_mask != 0


## Seconds as whole ticks, at least 1 for anything above 0.
func ticks_for(seconds: float) -> int:
	return 0 if seconds <= 0.0 else maxi(1, roundi(seconds * _tick_rate))


## Every ability, in run order.
func get_abilities() -> Array[AbilityBase]:
	return _abilities.duplicate()


# --- Internals ---


func _run_locomotion(dt: float) -> void:
	var chosen: AbilityBase = null
	for ability in _locomotions:
		if ability.trigger_action == &"":
			continue
		var wanted := pawn.is_action_held(ability.trigger_action)
		if ability.is_running_timed():
			if wanted and not is_locked(ability):
				chosen = ability
				break
			_finish(ability) # let go, or locked out
		elif wanted and _is_ready(ability):
			_start(ability)
			chosen = ability
			break
	if chosen == null:
		chosen = _default_locomotion
	# Only one locomotion runs. Any other timed one still going stops.
	for ability in _locomotions:
		if ability != chosen and ability.is_running_timed():
			_finish(ability)
	if chosen == null:
		return
	chosen.tick(dt)
	if chosen.is_running_timed():
		chosen.ticks_left -= 1
		if chosen.ticks_left <= 0:
			_finish(chosen)


func _run_actions(dt: float) -> void:
	var used_actions := {} # actions that started something this tick, so one press starts one ability
	for ability in _actions:
		if ability.is_running_timed():
			ability.tick(dt)
			ability.ticks_left -= 1
			if ability.ticks_left <= 0:
				_finish(ability)
			continue
		if ability.trigger_action == &"" or used_actions.has(ability.trigger_action):
			continue
		var pressed := pawn.was_action_pressed(ability.trigger_action)
		if not pressed and ability.buffer_ticks_left <= 0:
			continue
		if _is_ready(ability):
			_start(ability)
			used_actions[ability.trigger_action] = true
		elif pressed and ability.buffer_window > 0.0:
			ability.buffer_ticks_left = ticks_for(ability.buffer_window)
	# A press that started something doesn't also wait in another ability on the same action.
	for ability in _actions:
		if used_actions.has(ability.trigger_action) and not ability.is_running_timed():
			ability.buffer_ticks_left = 0


func _is_ready(ability: AbilityBase) -> bool:
	return ability.cooldown_ticks_left <= 0 and not is_locked(ability) and ability.can_start()


func _start(ability: AbilityBase) -> void:
	ability.buffer_ticks_left = 0
	ability.ticks_left = ticks_for(ability.duration)
	if ability.kind == AbilityBase.Kind.ACTION and ability.is_running_timed():
		_locked_mask |= ability.locks_out_mask # later abilities this tick respect it at once
	ability.start()
	ability_started.emit(ability)
	if ability.kind == AbilityBase.Kind.ACTION and not ability.is_running_timed():
		_finish(ability) # an action with no duration is done as soon as it starts


func _finish(ability: AbilityBase) -> void:
	ability.ticks_left = 0
	ability.cooldown_ticks_left = ticks_for(ability.cooldown)
	ability.stop()
	ability_finished.emit(ability)


func _collect_abilities() -> void:
	_abilities.clear()
	for child in get_children():
		if child is AbilityBase:
			child.manager = self
			child.pawn = pawn
			child.category_mask = TagRegistry.mask_of(child.category) if child.category != &"" else 0
			child.locks_out_mask = TagRegistry.mask_of_list(child.locks_out)
			_abilities.append(child)
	# GDScript note: sort_custom keeps this rule; abilities with equal priority keep their tree order because each has a distinct index.
	_abilities.sort_custom(func(a: AbilityBase, b: AbilityBase) -> bool:
		return a.priority < b.priority or (a.priority == b.priority and a.get_index() < b.get_index()))
	_locomotions.clear()
	_actions.clear()
	_default_locomotion = null
	for ability in _abilities:
		if ability.kind == AbilityBase.Kind.LOCOMOTION:
			_locomotions.append(ability)
			if ability.trigger_action == &"" and _default_locomotion == null:
				_default_locomotion = ability
		else:
			_actions.append(ability)


## Tells the pawn's TickStateComponent which ability properties roll back, before the first tick is recorded.
func _register_rollback_state() -> void:
	if pawn == null:
		return
	var tick_state: TickStateComponent = null
	for child in pawn.get_children():
		if child is TickStateComponent:
			tick_state = child
			break
	if tick_state == null:
		return
	var entries: Array[String] = []
	for ability in _abilities:
		var path := String(pawn.get_path_to(ability))
		for property in ability.get_rollback_properties():
			entries.append("%s:%s" % [path, property])
	if not entries.is_empty():
		tick_state.add_state_properties(entries)
