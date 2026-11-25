# Written by Claude (claude-opus-5-5), 2026-11-09. History: ai/CHANGELOG.md.
## Picks the AI's current target from its memory, by priority: the standard threat or aggro table, kept small.
##
## A component of the pawn's AIManager. At each decision, before the state, every memory entry at [member min_awareness] or more is a
## candidate; the highest priority wins (ties: the nearer, then the lower id) and becomes the context's current_target, which gets a
## fading bonus so the pawn doesn't flick between two close targets. A taunt is threat on the taunter's entry (no forcing).
## [codeblock]
## priority = awareness_weight × awareness
##          + distance_weight × (1 − distance / distance_range)     (distance to its last known position)
##          + threat_weight × threat
##          + current_target_bonus × current_target_fade's value    (only for the current target)
## [/codeblock]
## A game with its own rules overrides [method target_priority]; the loop then runs in GDScript instead of the memory store
## ([code]AIMemoryStore[/code] in C++, whose [code]best_target[/code] must match this formula). Listen to [signal target_changed].
## Design: pawn spec 10.5, 10.11 and 16.5.
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
var _custom_priority := false # true when a script overrides target_priority()


func _init() -> void:
	set_process(false)
	set_physics_process(false)


func _enter_tree() -> void:
	var ai := get_parent() as AIManager
	pawn = ai.pawn if ai else null
	if pawn == null:
		push_warning("AITargetSelector: its parent isn't a pawn's AIManager, so it never picks a target.")


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


## [method AIManager.think] calls this at each decision, before the state is checked.
func update_target(tick: int) -> void:
	if pawn == null:
		return
	var memory := pawn.ai.memory
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


# --- Internals ---


func _set_target(entity: Node3D, reason: String, tick: int) -> void:
	if entity == _current:
		return
	# A freed target (a dead pawn's body removed) is announced as null: listeners with typed parameters (the replay's gameplay
	# channel, the AI debug timeline) fail on a freed Object.
	var old: Node3D = _current if is_instance_valid(_current) else null
	_current = entity
	_picked_tick = tick
	if pawn.ai:
		pawn.ai.current_target = entity
	target_changed.emit(old, entity, reason)
