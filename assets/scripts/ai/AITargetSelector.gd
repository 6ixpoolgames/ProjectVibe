# Written by Claude (claude-opus-5-5), 2026-11-09. History: ai/CHANGELOG.md.
## Picks the AI's current target from its memory, by priority: the standard threat or aggro table, kept small.
##
## A part on the pawn. At each decision, before the state is checked, every memory entry at awareness [member min_awareness] or more
## is a candidate, and the highest priority wins (ties go to the nearer, then the lower id); the winner becomes the context's
## current_target. The current target gets a fading bonus so the pawn doesn't flick between two close targets.
## [codeblock]
## priority = awareness_weight × awareness
##          + distance_weight × (1 − distance / distance_range)     (distance to its last known position)
##          + threat_weight × threat
##          + current_target_bonus × current_target_fade's value    (only for the current target)
## [/codeblock]
## [method force_target] overrides the choice, for taunts. A game with its own rules overrides [method target_priority]; the loop then
## runs in GDScript instead of the memory store ([code]AIMemoryStore[/code] in C++, whose [code]best_target[/code] must match this
## formula). Listen to [signal target_changed]:
## [codeblock]
## pawn.ai_context.target_selector.force_target(player_pawn, 180, 40, "taunt")
## [/codeblock]
## Design: pawn spec 10.5 and 10.11, scaling spec step 3.
# REFACTOR: forcing and queueing are the same code as AIStateManager's force_state (reusable). See CHANGELOG.md.
class_name AITargetSelector
extends Node

## Sent once each time the current target changes. Either can be null.
signal target_changed(old_target: Node3D, new_target: Node3D, reason: String)

## How much awareness counts.
@export var awareness_weight := 1.0
## How much being near counts.
@export var distance_weight := 0.5
## How much threat counts.
@export var threat_weight := 1.0
## Distance, in metres, at which nearness counts for nothing. Usually the sight range.
@export_range(0.5, 500.0, 0.5, "or_greater") var distance_range := 25.0
## Entries below this awareness aren't targets, so a barely noticed shape isn't chased.
@export_range(0.0, 1.0, 0.01) var min_awareness := 0.3
## Added to the current target's priority, fading by current_target_fade.
@export var current_target_bonus := 0.3
## How the current target bonus fades. Empty: full for 60 ticks, then a straight line to nothing over 60 more.
@export var current_target_fade: FadeProfile

## The pawn this is a part of, or null.
var pawn: Pawn = null

var _current: Node3D = null
var _picked_tick := 0
var _forced: Node3D = null
var _force_priority := 0
var _force_until_tick := -1
var _custom_priority := false # true when a script overrides target_priority()
# Forces and releases asked for during a tick, applied at the pawn's next AI step.
# Each is [entity, hold_ticks, priority, reason], or [] for a release.
var _queued: Array = []


func _init() -> void:
	set_process(false)
	set_physics_process(false)


func _enter_tree() -> void:
	pawn = get_parent() as Pawn
	if pawn == null:
		push_warning("AITargetSelector: its parent isn't a Pawn, so it never picks a target.")


func _ready() -> void:
	if current_target_fade == null:
		current_target_fade = FadeProfile.new()
		current_target_fade.mode = FadeProfile.Mode.LINEAR
		current_target_fade.hold_ticks = 60
		current_target_fade.fade_ticks = 60
	# A script below this one overrides target_priority() (ScriptOverrides): the game scores targets its own way.
	_custom_priority = ScriptOverrides.overrides(get_script(), &"target_priority")


## The current target, or null.
func get_current_target() -> Node3D:
	return _current if is_instance_valid(_current) else null


## True while a forced target is holding.
func is_target_forced() -> bool:
	return _forced != null


## [method AIContextComponent.think] calls this at each decision, before the state is checked.
func update_target(tick: int) -> void:
	if pawn == null:
		return
	if _forced and not is_instance_valid(_forced):
		_end_force()
	if _forced:
		if _force_until_tick >= 0 and tick >= _force_until_tick:
			_end_force()
		else:
			_set_target(_forced, "forced", tick)
			return
	var memory := pawn.ai_context.memory
	var best: Node3D = null
	var best_priority := -INF
	var best_distance := INF
	var best_id := 0
	if memory and not _custom_priority:
		# The built-in formula, as one loop in memory's store.
		var current_id := _current.get_instance_id() if is_instance_valid(_current) else 0
		var bonus := current_target_bonus * current_target_fade.value_at(tick - _picked_tick) if current_id != 0 and current_target_fade else 0.0
		var index: int = memory.get_store().best_target(pawn.global_position, awareness_weight, distance_weight, threat_weight, distance_range, min_awareness, current_id, bonus, tick)
		_set_target(memory.entity_at(index) if index >= 0 else null, "priority", tick)
		return
	if memory:
		for i in memory.entry_count():
			if memory.awareness_at(i, tick) < min_awareness:
				continue
			var entity := memory.entity_at(i)
			if entity == null:
				continue
			var priority := target_priority(memory, i, tick)
			var distance := pawn.global_position.distance_squared_to(memory.last_known_position_at(i))
			var id := entity.get_instance_id()
			if priority > best_priority + 0.000001 \
					or (absf(priority - best_priority) <= 0.000001 and (distance < best_distance or (distance == best_distance and id < best_id))):
				best = entity
				best_priority = priority
				best_distance = distance
				best_id = id
	_set_target(best, "priority", tick)


## This entry's target priority. Override for a game's own rules.
func target_priority(memory: AIMemory, index: int, tick: int) -> float:
	var distance := pawn.global_position.distance_to(memory.last_known_position_at(index))
	var priority := awareness_weight * memory.awareness_at(index, tick) \
			+ distance_weight * (1.0 - clampf(distance / distance_range, 0.0, 1.0)) \
			+ threat_weight * memory.threat_at(index)
	if memory.entity_at(index) == _current and current_target_fade:
		priority += current_target_bonus * current_target_fade.value_at(tick - _picked_tick)
	return priority


## Makes this entity the target for hold_ticks at 60 a second (-1: until released). Returns false, changing nothing, if a stronger
## force holds, the entity is gone, or this isn't where the AI runs. During a tick it's queued and returns true.
func force_target(entity: Node3D, hold_ticks: int, priority: int, reason: String) -> bool:
	if pawn == null or not is_instance_valid(entity):
		return false
	if not pawn.runs_ai_here():
		push_warning("AITargetSelector: force_target on a client does nothing. The AI only runs on the server.")
		return false
	if _during_tick():
		_queued.append([entity, hold_ticks, priority, reason])
		return true
	return _apply_force(entity, hold_ticks, priority, reason)


## Ends a forced target. The next decision picks by priority again. During a tick it's queued, as forces are.
func release_forced_target() -> void:
	if _during_tick():
		_queued.append([])
		return
	if _forced:
		_end_force()


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
		elif is_instance_valid(request[0]):
			_apply_force(request[0], request[1], request[2], request[3])


# What force_target does, shared by the queued way and the immediate one.
func _apply_force(entity: Node3D, hold_ticks: int, priority: int, reason: String) -> bool:
	if _forced and priority < _force_priority:
		if OS.is_debug_build():
			print("AITargetSelector: %s refused a forced target (priority %d, \"%s\"): one is forced at priority %d." % [pawn.name, priority, reason, _force_priority])
		return false
	_forced = entity
	_force_priority = priority
	_force_until_tick = -1 if hold_ticks < 0 else _now() + TickDriver.ticks_at_rate(hold_ticks) # hold_ticks are at 60 a second
	_set_target(entity, reason, _now())
	if pawn.ai_context:
		pawn.ai_context.request_decision(priority, false)
	return true


## [method AIContextComponent.think] calls this every tick, so a forced target that runs out hands back on time.
func check_force_expiry(tick: int) -> void:
	if _forced and _force_until_tick >= 0 and tick >= _force_until_tick:
		_end_force()


# --- Internals ---


func _set_target(entity: Node3D, reason: String, tick: int) -> void:
	if entity == _current:
		return
	# A freed target (a dead pawn's body removed) is announced as null: listeners with typed parameters (the replay's gameplay
	# channel, the AI debug timeline) fail on a freed Object.
	var old: Node3D = _current if is_instance_valid(_current) else null
	_current = entity
	_picked_tick = tick
	if pawn.ai_context:
		pawn.ai_context.current_target = entity
	target_changed.emit(old, entity, reason)


func _end_force() -> void:
	_forced = null
	_force_priority = 0
	_force_until_tick = -1
	if pawn and pawn.ai_context:
		pawn.ai_context.request_decision()


# True while a tick runs, when a request must wait for the pawn's next AI step.
func _during_tick() -> bool:
	return TickDriver.is_in_tick()


# The tick now, from the TickDriver autoload.
func _now() -> int:
	return TickDriver.tick
