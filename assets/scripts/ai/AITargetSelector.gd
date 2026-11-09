## Written by Claude (claude-opus-5-5), 2026-11-09: picks the AI's current target from its memory, by priority. A part on the pawn,
## added by PawnInitializer. Pawn spec section 10.5, "Target selection". The standard threat or aggro table, kept small.
##
## At each decision, before the state is checked, every memory entry at awareness min_awareness or more is a candidate, with:
##     priority = awareness_weight × awareness
##              + distance_weight × (1 − distance / distance_range)     (distance to its last known position)
##              + threat_weight × threat
##              + current_target_bonus × current_target_fade's value    (only for the current target)
## The highest wins; ties go to the nearer, then to the lower id. The winner goes on the context as current_target, where behaviours
## that need a target and states such as Combat read it.
##
## The current target bonus stops the pawn flicking between two close targets. It fades by a FadeProfile counted from when the
## target was picked: by default +0.3, held 60 ticks, gone 60 ticks later.
##
## Forcing a target, for taunts: force_target(entity, hold_ticks, priority, reason) overrides the choice for hold_ticks (-1: until
## released). A new force replaces the current one only if its priority is equal or higher, the same rule as forced states. It asks
## for a decision with that priority, so a strong taunt can interrupt the running behaviour. On a client it does nothing and warns.
## Claude 2026-11-09 (scaling spec step 3): when it's called during a tick (by another pawn's ability or behaviour, say), it's queued
## and applied at the start of this pawn's next AI step, in the order the calls were made, so the result never depends on which pawn
## went first; it returns true for "queued", and a weaker force is refused (and logged) when it's applied. Called between ticks (game
## code, a UI, a test), it applies at once, as before. release_forced_target() works the same way.
##
## A game with its own targeting rules extends this and overrides target_priority().
##
## Claude 2026-11-09: the scoring loop runs in the pawn's memory store (AIMemoryStore in C++ when available, pawn spec 10.11) with
## the weights below. A script that overrides target_priority() is noticed when the selector is ready, and then every entry is scored
## by that function in GDScript instead, so a game's own rules always win.
##
## How to use it (outside code only talks to the selector):
##   pawn.ai_target_selector.get_current_target()
##   pawn.ai_target_selector.force_target(player_pawn, 180, 40, "taunt")
##   target_changed(old_target, new_target, reason)
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

var pawn: Pawn = null

var _current: Node3D = null
var _picked_tick := 0
var _forced: Node3D = null
var _force_priority := 0
var _force_until_tick := -1
var _custom_priority := false # Claude 2026-11-09: true when a script overrides target_priority()
# Claude 2026-11-09 (scaling spec step 3): forces and releases asked for during a tick, applied at the pawn's next AI step.
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
	# GDScript note: a script's method list includes inherited methods, and an overridden one appears once per script that defines
	# it, so more than one target_priority means something overrode it.
	var definitions := 0
	for method in get_script().get_script_method_list():
		if method.name == "target_priority":
			definitions += 1
	_custom_priority = definitions > 1


## The current target, or null.
func get_current_target() -> Node3D:
	return _current if is_instance_valid(_current) else null


## True while a forced target is holding.
func is_target_forced() -> bool:
	return _forced != null


## The pawn calls this at each decision, before the state is checked.
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
	var memory := pawn.ai_memory
	var best: Node3D = null
	var best_priority := -INF
	var best_distance := INF
	var best_id := 0
	if memory and not _custom_priority:
		# Claude 2026-11-09: the built-in formula, as one loop in memory's store.
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


## Makes this entity the target for hold_ticks (-1: until released). Returns false, and changes nothing, if a stronger force is
## holding, the entity is gone, or this isn't where the AI runs. Claude 2026-11-09 (step 3): during a tick it's queued instead (see
## the top of this file) and returns true; the priority check happens when it's applied.
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


## Ends a forced target. The next decision picks by priority again. Claude 2026-11-09 (step 3): queued during a tick.
func release_forced_target() -> void:
	if _during_tick():
		_queued.append([])
		return
	if _forced:
		_end_force()


## Claude 2026-11-09 (scaling spec step 3): the pawn calls this at the start of its AI step: applies the forces and releases queued
## during the last tick, in the order they were asked for.
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


# Claude 2026-11-09 (step 3): what force_target did, now shared by the queued way and the immediate one.
func _apply_force(entity: Node3D, hold_ticks: int, priority: int, reason: String) -> bool:
	if _forced and priority < _force_priority:
		if OS.is_debug_build():
			print("AITargetSelector: %s refused a forced target (priority %d, \"%s\"): one is forced at priority %d." % [pawn.name, priority, reason, _force_priority])
		return false
	_forced = entity
	_force_priority = priority
	_force_until_tick = -1 if hold_ticks < 0 else _now() + hold_ticks
	_set_target(entity, reason, _now())
	if pawn.ai_context:
		pawn.ai_context.request_decision(priority, false)
	return true


## The pawn calls this every tick, so a forced target that runs out hands back on time.
func check_force_expiry(tick: int) -> void:
	if _forced and _force_until_tick >= 0 and tick >= _force_until_tick:
		_end_force()


# --- Internals ---


func _set_target(entity: Node3D, reason: String, tick: int) -> void:
	if entity == _current:
		return
	var old := _current
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


# Claude 2026-11-09 (step 3): true while a tick runs, when a request must wait for the pawn's next AI step.
func _during_tick() -> bool:
	var driver: Node = get_node_or_null("/root/TickDriver")
	return driver != null and driver.is_in_tick()


func _now() -> int:
	var driver: Node = get_node_or_null("/root/TickDriver")
	if driver:
		return driver.tick
	return pawn.ai_context.current_tick if pawn and pawn.ai_context else 0
