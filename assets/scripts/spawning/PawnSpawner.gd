# Written by Claude (claude-opus-5-5), 2026-11-10. History: spawning/CHANGELOG.md.
## Keeps a number of pawns of one type alive, replacing each that dies after a delay.
##
## Put one in a level and set it in the inspector (pawn spec 8.9). Server or offline only; it spawns through GameMode.spawn_manager,
## which it needs. With [member spawn_group] empty, pawns appear within [member scatter_radius] of the spawner; with a group, at
## SpawnPoints that accept the pawn's team (see the SpawnManager README). It fills up to [member keep_alive] when switched on and
## whenever fewer are alive; a dead pawn's body goes after [member body_seconds] and a fresh replacement is due [member respawn_seconds]
## later (a pawn removed another way counts as a death). All delays count ticks, so pausing the tick driver pauses them.
## [codeblock]
## spawner.active = true          # starts filling; false stops spawning and leaves its pawns where they are
## spawner.refill_now()           # fills up at once, skipping the replacements' wait
## spawner.get_alive()            # its living pawns
## [/codeblock]
class_name PawnSpawner
extends Node3D

## Sent for each pawn it spawns.
signal spawned(pawn: Pawn)
## Sent when one of its pawns dies.
signal pawn_died(pawn: Pawn)

## On: it keeps its pawns topped up. A game that starts its match later (such as after a menu) can leave this off and turn it on.
@export var active := true:
	set(value):
		active = value
		if active and is_inside_tree():
			_update.call_deferred() # deferred, so setting it from _ready or a signal doesn't spawn halfway through
## The NetworkSession type name to spawn (NetworkSession.register_type). Empty, the default: it spawns nothing, and warns once.
@export var pawn_type := ""
## How many living pawns it keeps.
@export_range(0, 1000, 1, "or_greater") var keep_alive := 3
## Seconds from a death to its replacement.
@export_range(0.0, 600.0, 0.1, "or_greater") var respawn_seconds := 5.0
## Seconds a dead pawn's body stays before it's removed. Below 0: never removed.
@export_range(-1.0, 600.0, 0.1, "or_greater") var body_seconds := 3.0
## How many it spawns in all, then stops. 0: no limit.
@export_range(0, 100000, 1, "or_greater") var total_limit := 0
## Spawn points to use, by group. Empty: around the spawner itself.
@export var spawn_group: StringName = &""
## With no group: how far from the spawner, in metres, a pawn may appear.
@export_range(0.0, 100.0, 0.1, "or_greater") var scatter_radius := 3.0
## On: it waits while the ground around it isn't loaded.
@export var only_where_loaded := true
## How much ground around the spawner must be loaded, in metres.
@export var loaded_margin := 2.0

var _alive: Array[int] = [] # instance ids of its living pawns; ids, because a freed pawn can't sit in a typed array
var _waiting: Array[int] = [] # the tick each replacement still waiting is due
var _spawned_total := 0
var _warned := false


func _ready() -> void:
	var driver := get_node_or_null("/root/TickDriver")
	if driver:
		driver.after_tick_loop.connect(_update)
	if active:
		_update.call_deferred()


## Fills up now, without waiting for the replacements' delays.
func refill_now() -> void:
	_waiting.clear()
	_update()


## Its living pawns.
func get_alive() -> Array[Pawn]:
	var out: Array[Pawn] = []
	for id in _alive:
		var pawn := instance_from_id(id) as Pawn
		if pawn:
			out.append(pawn)
	return out


## How many it has spawned in all.
func get_spawned_total() -> int:
	return _spawned_total


var _warned_no_type := false

# Between ticks, and when switched on: drop pawns that are gone, then spawn what's missing and not waiting.
func _update() -> void:
	if not active or not is_inside_tree():
		return
	var session := get_node_or_null("/root/NetworkSession")
	if session and session.is_client():
		return
	var manager := _manager()
	if manager == null:
		return
	var now: int = TickDriver.tick
	for i in range(_alive.size() - 1, -1, -1):
		if instance_from_id(_alive[i]) == null: # removed without dying: a replacement is due as for a death
			_alive.remove_at(i)
			_waiting.append(now + TickDriver.seconds_to_ticks(respawn_seconds))
	# filter() keeps the replacements not due yet.
	_waiting = _waiting.filter(func(due: int) -> bool: return due > now)
	var missing := keep_alive - _alive.size() - _waiting.size()
	if missing <= 0:
		return
	if only_where_loaded and not _ground_loaded():
		return
	if pawn_type == "": # nothing chosen to spawn; said once
		if not _warned_no_type:
			_warned_no_type = true
			push_warning("PawnSpawner '%s' has no pawn_type, so it spawns nothing. Set it to a type registered with NetworkSession.register_type." % name)
		return
	for i in missing:
		if total_limit > 0 and _spawned_total >= total_limit:
			return
		var pawn: Pawn = manager.spawn(pawn_type, spawn_group) if spawn_group != &"" else manager.spawn_near(pawn_type, self, scatter_radius)
		if pawn == null:
			return # no point, or the type isn't registered: SpawnManager has warned
		_spawned_total += 1
		_alive.append(pawn.get_instance_id())
		if pawn.ability_manager: # died is the AbilityManager's signal
			pawn.ability_manager.died.connect(_on_died.bind(pawn.get_instance_id()))
		spawned.emit(pawn)


func _on_died(pawn: Pawn, _hit: HitInfo, pawn_id: int) -> void:
	_alive.erase(pawn_id)
	_waiting.append(TickDriver.tick + TickDriver.seconds_to_ticks(respawn_seconds))
	pawn_died.emit(pawn)
	var manager := _manager()
	if body_seconds >= 0.0 and manager:
		manager.after_seconds(body_seconds, _remove_body.bind(pawn_id))


func _remove_body(pawn_id: int) -> void:
	var pawn := instance_from_id(pawn_id) as Pawn
	if pawn == null or not pawn.is_dead():
		return # already gone, or brought back by something else
	var entity := pawn.get_network_entity()
	var session := get_node_or_null("/root/NetworkSession")
	if entity and session:
		session.despawn(entity.entity_id)
	else:
		pawn.queue_free()


func _manager() -> SpawnManager:
	var game_mode := get_node_or_null("/root/GameMode")
	var manager: SpawnManager = game_mode.spawn_manager if game_mode else null
	if manager == null and not _warned:
		_warned = true
		push_warning("PawnSpawner '%s': there's no SpawnManager in GameMode, so it can't spawn." % name)
	return manager


# The rule AIActivationManager uses: every chunk within the margin is built. No terrain: always loaded.
# REFACTOR: a copy of AIActivationManager's rule; one shared "is the ground loaded here" check would keep them alike (duplicated
# logic). See CHANGELOG.md.
func _ground_loaded() -> bool:
	var terrains := get_tree().get_nodes_in_group(TerrainGenerator.GROUP)
	if terrains.is_empty():
		return true
	for node in terrains:
		var terrain := node as TerrainGenerator
		if terrain and terrain.has_ground_around(global_position, loaded_margin):
			return true
	return false
