## Written by Claude (claude-opus-5-5), 2026-11-10: keeps a number of pawns of one type alive, replacing each that dies after a delay.
## Put one in a level and set it in the inspector. Works on the server or offline; on a client it does nothing, since the server's
## pawns reach clients by themselves. It spawns through GameMode.spawn_manager, which it needs.
##
## Where its pawns appear: with spawn_group empty, within scatter_radius of the spawner itself, facing the spawner's way; with a
## group, at SpawnPoints in that group that accept the pawn's team (see SpawnManager, "Choosing a point").
##
## What it does, checked between ticks:
##   - Fills up to keep_alive at once when it's switched on, and after that whenever it has fewer than keep_alive living pawns and
##     no replacement is still waiting.
##   - A pawn of its own that dies: its body is removed after body_seconds, and a replacement is due respawn_seconds after the death.
##     The replacement is a fresh pawn, not the dead one revived, so its AI starts clean (no memory of the fight it died in).
##   - A pawn of its own that's removed some other way (the game despawned it) counts as a death, without a body to remove.
##   - total_limit above 0 stops it after that many, in all. 0: no limit.
##   - only_where_loaded on: it waits while the ground around it isn't loaded, the rule AIActivationManager uses, so a spawner no
##     player is near doesn't run AI nobody sees. With no terrain, the ground always counts as loaded.
## All its delays count ticks (SpawnManager.after_seconds), so pausing the tick driver pauses them.
##
## How to use it from code:
##   spawner.active = true          # starts filling; false stops spawning, and leaves its pawns where they are
##   spawner.refill_now()           # fills up at once, skipping the replacements' wait
##   spawner.get_alive()            # its living pawns
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
			_update.call_deferred() # GDScript note: deferred, so setting it from _ready or a signal doesn't spawn halfway through
## The NetworkSession type name to spawn (NetworkSession.register_type).
@export var pawn_type := "goblin"
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
	# GDScript note: filter() keeps the entries the function returns true for; these are the replacements not due yet.
	_waiting = _waiting.filter(func(due: int) -> bool: return due > now)
	var missing := keep_alive - _alive.size() - _waiting.size()
	if missing <= 0:
		return
	if only_where_loaded and not _ground_loaded():
		return
	for i in missing:
		if total_limit > 0 and _spawned_total >= total_limit:
			return
		var pawn: Pawn = manager.spawn(pawn_type, spawn_group) if spawn_group != &"" else manager.spawn_near(pawn_type, self, scatter_radius)
		if pawn == null:
			return # no point, or the type isn't registered: SpawnManager has warned
		_spawned_total += 1
		_alive.append(pawn.get_instance_id())
		pawn.died.connect(_on_died.bind(pawn.get_instance_id()))
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
func _ground_loaded() -> bool:
	var terrains := get_tree().get_nodes_in_group(TerrainGenerator.GROUP)
	if terrains.is_empty():
		return true
	for node in terrains:
		var terrain := node as TerrainGenerator
		if terrain and terrain.has_ground_around(global_position, loaded_margin):
			return true
	return false
