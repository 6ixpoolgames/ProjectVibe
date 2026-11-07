## Written by Claude (claude-opus-5-5), 2026-11-07: switches AI pawns off when the ground around them isn't loaded, and back on
## when it is. So a horde costs almost nothing where no player is, and nothing walks off the edge of the world. Claude 2026-11-07:
## a Pawn stops its NetworkEntity and TickState too, which leaves only this module's checks, and it's left out of snapshots while off.
##
## The rule: an AI pawn runs only while every chunk within edge_margin of it is built. In other words, it's near enough to a
## source. A pawn with its own active source has ground wherever it goes, so it's never switched off.
##
## This is a first pass, chosen by the owner for tier 0. It's meant to be replaced or added to: a game that needs AI simulated
## out of sight, such as ecology, migration or faction wars, can listen to ai_deactivated and ai_activated, and simulate those
## pawns some cheaper way while they're off. None of that exists yet.
##
## What a pawn needs:
##   - to call GameMode.ai_activity.add_pawn(self) when it's an AI pawn, and remove_pawn(self) when it stops being one
##   - a method set_simulation_active(active: bool), which stops and restarts its ticks and leaves all its state as it is
##
## What happens in odd cases (all checked in game_mode/tests/game_mode_selftest.gd):
##   - No terrain in the scene: every pawn stays on.
##   - On a client: this does nothing, because AI only runs on the server.
##   - A pawn that's freed: it's dropped from the list.
##   - The module is removed: every pawn it switched off goes back on.
class_name AIActivityModule
extends GameModeModule

## Sent when a pawn is switched off, because the ground around it isn't loaded.
signal ai_deactivated(pawn: Node3D)
## Sent when a pawn is switched back on.
signal ai_activated(pawn: Node3D)

## How close a pawn may get to unbuilt ground, in metres. It has to be further than the pawn moves between its checks,
## about 0.5 m for a walking pawn at the default of 6 frames.
@export var edge_margin := 2.0
## Each pawn is checked once in this many physics frames, so a big horde isn't all checked at once.
@export_range(1, 60, 1) var spread_over_frames := 6
## The most pawns checked in one frame, however many there are. A very large horde takes longer to get through, so with a lot
## of fast pawns, raise edge_margin too. A removed chunk is always handled at once, so this only delays walking to an edge.
@export_range(1, 100000, 1, "or_greater") var max_checks_per_frame := 500

var _pawns: Array[Node3D] = []
var _inactive: Dictionary = {} # pawn -> true
var _next_pawn := 0
var _session: Node = null
var _terrains: Array[Terrain] = []
var _connected_terrains := {} # Terrain -> true
var _check_everyone := false


func _init() -> void:
	# After ChunkStreamer's -200, so new ground counts, and before NetworkTime's -100, so nothing ticks over ground that's gone.
	process_physics_priority = -150


func _on_module_added(game_mode: GameModeSingleton) -> void:
	game_mode.ai_activity = self
	_session = get_node_or_null("/root/NetworkSession")


func _on_module_removed(game_mode: GameModeSingleton) -> void:
	game_mode.ai_activity = null
	for pawn: Node3D in _inactive.keys():
		if is_instance_valid(pawn):
			_set_active(pawn, true)
	_inactive.clear()


## Starts watching an AI pawn. Adding the same one twice does nothing.
func add_pawn(pawn: Node3D) -> void:
	if pawn != null and not _pawns.has(pawn):
		_pawns.append(pawn)
		_refresh_terrains()
		_check_pawn(pawn) # at once, so a pawn spawned out where there's no ground never takes a tick there


## Stops watching a pawn, such as one a player has taken over. If it was off, it goes back on.
func remove_pawn(pawn: Node3D) -> void:
	_pawns.erase(pawn)
	if _inactive.has(pawn):
		_inactive.erase(pawn)
		if is_instance_valid(pawn):
			_set_active(pawn, true)


func is_active(pawn: Node3D) -> bool:
	return not _inactive.has(pawn)


## How many pawns are off right now.
func get_inactive_count() -> int:
	return _inactive.size()


func get_watched_count() -> int:
	return _pawns.size()


func _physics_process(_delta: float) -> void:
	if _pawns.is_empty():
		return
	_refresh_terrains()
	if _check_everyone:
		_check_everyone = false
		for pawn: Node3D in _pawns:
			if is_instance_valid(pawn):
				_check_pawn(pawn)
	var count := mini(ceili(float(_pawns.size()) / spread_over_frames), max_checks_per_frame)
	for i in count:
		if _pawns.is_empty():
			return
		_next_pawn = (_next_pawn + 1) % _pawns.size()
		var pawn: Node3D = _pawns[_next_pawn]
		if is_instance_valid(pawn):
			_check_pawn(pawn)
		else:
			_pawns.remove_at(_next_pawn)
			_inactive.erase(pawn)


func _check_pawn(pawn: Node3D) -> void:
	if _session != null and _session.is_client():
		return
	if not pawn.is_inside_tree():
		return
	var has_ground := _has_ground_around(pawn.global_position)
	if has_ground and _inactive.has(pawn):
		_inactive.erase(pawn)
		_set_active(pawn, true)
		ai_activated.emit(pawn)
	elif not has_ground and not _inactive.has(pawn):
		_inactive[pawn] = true
		_set_active(pawn, false)
		ai_deactivated.emit(pawn)


## True if some terrain has all the chunks around this position, or if there are no terrains to ask.
func _has_ground_around(at: Vector3) -> bool:
	if _terrains.is_empty():
		return true
	for terrain in _terrains:
		if is_instance_valid(terrain) and terrain.has_ground_around(at, edge_margin):
			return true
	return false


## Finds the terrains again, and listens for chunks going away on any new ones.
func _refresh_terrains() -> void:
	_terrains.clear()
	for node in get_tree().get_nodes_in_group(Terrain.GROUP):
		var terrain := node as Terrain
		if terrain != null:
			_terrains.append(terrain)
			if not _connected_terrains.has(terrain):
				_connected_terrains[terrain] = true
				terrain.chunk_removed.connect(_on_chunk_removed)


## A pawn could be standing on it. Its next tick can't wait for its turn in the staggered checks, so everyone gets checked
## before the next tick. At most one chunk unloads per frame.
func _on_chunk_removed(_key: Vector2i) -> void:
	_check_everyone = true


func _set_active(pawn: Node3D, active: bool) -> void:
	if pawn.has_method(&"set_simulation_active"):
		pawn.set_simulation_active(active)
