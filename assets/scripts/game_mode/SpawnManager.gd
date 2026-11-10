## Written by Claude (claude-opus-5-5), 2026-11-10: puts pawns into the world at SpawnPoints, and brings players back after they die.
## A module of GameMode, reached as GameMode.spawn_manager. The owner's call: Unreal's GameMode does the same job (it picks a
## PlayerStart and restarts players there). With no spawn points placed it does nothing, so it costs nothing in a game that doesn't
## use it.
##
## How to use it (on the server, or offline; a client never spawns):
##   GameMode.spawn_manager.spawn("goblin")                     # at a point its team may use, any group
##   GameMode.spawn_manager.spawn("goblin", &"red_base")        # at a point in that group
##   GameMode.spawn_manager.spawn_near("goblin", node, 3.0)     # within 3 m of a node, facing its way (PawnSpawner uses this)
##   GameMode.spawn_manager.spawn_player(peer)                  # a player's pawn, possessed for them, and brought back when it dies
##   GameMode.spawn_manager.after_seconds(2.0, callable)        # runs it after 2 s of ticks
##
## Type names are NetworkSession's (register_type), so every spawned pawn exists on every machine. A pawn's team comes from its
## scene: the manager reads it once per type, and uses it to choose points.
##
## Choosing a point:
##   1. Every enabled SpawnPoint that accepts the pawn's team and the group asked for (SpawnPoint.accepts).
##   2. In a shuffled order, from the tick's own random numbers (TickDriver.tick_rng), so it's repeatable.
##   3. On each point, up to tries_per_point spots inside its scatter_radius, and the first one with no pawn standing on it wins:
##      no pawn body within clearance_radius of where the new one's middle would be.
##   4. If every spot is taken, it uses a spot on the first point anyway. A crowded spawn is better than none.
##   5. No point at all: a warning, and nothing spawns.
##
## Players: a pawn from spawn_player that dies comes back after player_respawn_seconds, with full Health. It's the same pawn, so its
## player keeps it, and its entity and history carry on. With player_respawn_at_spawn_point on, it's moved to a point for its team
## first; with that off, or with no point, it comes back where it fell. On a client, the move shows as a quick slide (the client's
## correction smoothing), which is fine for now.
##
## Timing: every delay here counts ticks on TickDriver, and runs between ticks (after_tick_loop), never during one. So pausing the
## tick driver (the arena's P key) pauses the delays too, and stepping runs them a tick at a time.
class_name SpawnManager
extends GameModeModule

## Sent on the server or offline for every pawn this manager spawns.
signal pawn_spawned(pawn: Pawn)
## Sent when a player's pawn comes back after dying.
signal player_respawned(peer: int, pawn: Pawn)

## On: players' pawns come back after dying.
@export var respawn_players := true
## How long a player's pawn stays dead, in seconds.
@export_range(0.0, 60.0, 0.1, "or_greater") var player_respawn_seconds := 3.0
## On: a player's pawn comes back at a spawn point for its team. Off, or with no point: where it fell.
@export var player_respawn_at_spawn_point := true
## How many spots inside a point's scatter_radius it tries before going on to the next point.
@export_range(1, 32, 1) var tries_per_point := 4
## How close another pawn's body may be to a new pawn's middle, in metres, for the spot to count as free.
@export_range(0.0, 5.0, 0.05) var clearance_radius := 0.6
## How far above the ground a pawn appears on terrain, in metres, so it never starts inside it.
@export var ground_lift := 0.3
## The physics layers pawns are on, for the free-spot check. Pawns use layer 2.
@export_flags_3d_physics var pawn_layers := 2

const RANDOM_SALT := 7151 # separates these rolls from other users of the same tick's random numbers

var _session: Node = null
var _driver: Node = null
var _game_mode: GameModeSingleton = null
var _pending: Array = [] # [due tick, Callable], run between ticks
var _players := {} # pawn instance id -> peer
var _team_of_type := {} # type name -> team, read once from its scene
var _spawn_count := 0 # each spawn rolls differently, even several in one tick


func _init() -> void:
	set_process(false)
	set_physics_process(false)


func _on_module_added(game_mode: GameModeSingleton) -> void:
	game_mode.spawn_manager = self
	_game_mode = game_mode
	_session = get_node_or_null("/root/NetworkSession")
	_driver = get_node_or_null("/root/TickDriver")
	if _driver:
		_driver.after_tick_loop.connect(_run_due)


func _on_module_removed(game_mode: GameModeSingleton) -> void:
	game_mode.spawn_manager = null
	if _driver and _driver.after_tick_loop.is_connected(_run_due):
		_driver.after_tick_loop.disconnect(_run_due)
	_pending.clear()


# --- Spawning ---


## Spawns a pawn of this type at a point its team may use, in this group (or any group, with &""). owner_peer is whose input it
## follows, 0 for the server's own. Returns the pawn, or null if there's no point or this machine can't spawn.
func spawn(type_name: String, group: StringName = &"", owner_peer: int = 0) -> Pawn:
	if not _can_spawn():
		return null
	var team := _team_of(type_name)
	var place := find_place(team, group)
	if place.is_empty():
		push_warning("SpawnManager: no SpawnPoint for team %d%s, so no '%s' was spawned." % [team, " in group '%s'" % group if group != &"" else "", type_name])
		return null
	return _spawn_at(type_name, owner_peer, place)


## Spawns a pawn of this type within scatter_radius of a node, facing the node's way, with no spawn point needed. PawnSpawner uses
## this when it has no group of points.
func spawn_near(type_name: String, around: Node3D, scatter_radius: float, owner_peer: int = 0) -> Pawn:
	if not _can_spawn() or around == null:
		return null
	var rng := _next_rng()
	var place := _free_spot(around, around.global_position, around.global_basis.get_euler().y, scatter_radius, rng)
	if place.is_empty():
		place = _spot(around.global_position, around.global_basis.get_euler().y, scatter_radius, rng) # crowded, but it still spawns
	return _spawn_at(type_name, owner_peer, place)


## A player's pawn: spawned at a point for its team, possessed for this player, and brought back when it dies (respawn_players).
## peer is the player's network peer; offline, anything (it's possessed for the one local player).
func spawn_player(peer: int, type_name: String = "pawn", group: StringName = &"") -> Pawn:
	var serving: bool = _session != null and _session.is_server()
	var pawn := spawn(type_name, group, peer if serving else 0)
	if pawn == null:
		return null
	_players[pawn.get_instance_id()] = peer
	# GDScript note: the instance id is bound, not the pawn, so a pawn freed before the call doesn't break it.
	pawn.died.connect(_on_player_died.bind(pawn.get_instance_id()))
	var coordinator: PossessionCoordinator = _game_mode.possession_coordinator if _game_mode else null
	if coordinator:
		if serving:
			coordinator.possess_for(peer, pawn)
		else:
			coordinator.possess(pawn)
	return pawn


## Where a pawn of this team would appear, asked for with this group: {"position": Vector3, "yaw": float}, or {} with no point.
## See "Choosing a point" at the top.
func find_place(team: int, group: StringName = &"") -> Dictionary:
	var points: Array[SpawnPoint] = []
	for node in get_tree().get_nodes_in_group(SpawnPoint.GROUP):
		var point := node as SpawnPoint
		if point and point.is_inside_tree() and point.accepts(team, group):
			points.append(point)
	if points.is_empty():
		return {}
	# Tree order first, so the same points shuffle the same way for the same roll.
	var rng := _next_rng()
	for i in range(points.size() - 1, 0, -1): # GDScript note: a Fisher-Yates shuffle, with our own random numbers
		var j := rng.randi_range(0, i)
		var swap := points[i]
		points[i] = points[j]
		points[j] = swap
	for point in points:
		var place := _free_spot(point, point.global_position, point.get_yaw(), point.scatter_radius, rng)
		if not place.is_empty():
			return place
	return _spot(points[0].global_position, points[0].get_yaw(), points[0].scatter_radius, rng)


## Runs what after this many seconds of ticks, between ticks. Pausing the tick driver pauses the count. For delays that are part of
## the game's rules, such as respawns and body removal.
func after_seconds(seconds: float, what: Callable) -> void:
	var due: int = (_driver.tick + _driver.seconds_to_ticks(seconds)) if _driver else 0
	_pending.append([due, what])


# --- Players ---


func _on_player_died(_pawn: Pawn, _hit: HitInfo, pawn_id: int) -> void:
	if respawn_players:
		after_seconds(player_respawn_seconds, _respawn_player.bind(pawn_id))


func _respawn_player(pawn_id: int) -> void:
	var pawn := instance_from_id(pawn_id) as Pawn
	if pawn == null or not pawn.is_dead():
		return # gone, or something else already brought it back
	if player_respawn_at_spawn_point:
		var place := find_place(pawn.team)
		if not place.is_empty():
			pawn.global_position = place["position"]
			pawn.velocity = Vector3.ZERO
			pawn.yaw = place["yaw"]
	pawn.revive()
	player_respawned.emit(_players.get(pawn_id, 0), pawn)


# --- Inside ---


func _can_spawn() -> bool:
	if _session == null:
		push_warning("SpawnManager: there's no NetworkSession, so nothing can spawn.")
		return false
	if _session.is_client():
		push_warning("SpawnManager: only the server spawns.")
		return false
	return true


func _spawn_at(type_name: String, owner_peer: int, place: Dictionary) -> Pawn:
	var pawn := _session.spawn(type_name, owner_peer, place["position"]) as Pawn
	if pawn == null:
		return null
	pawn.yaw = place["yaw"]
	_spawn_count += 1
	pawn_spawned.emit(pawn)
	return pawn


## A free spot near this centre, or {}. The node is only for its physics world.
func _free_spot(world_node: Node3D, centre: Vector3, yaw: float, radius: float, rng: RandomNumberGenerator) -> Dictionary:
	for i in tries_per_point:
		# The first try is the point itself, so a point with no scatter still gets checked once.
		var place := _spot(centre, yaw, radius if i > 0 else 0.0, rng)
		if _is_free(world_node, place["position"]):
			return place
	return {}


## A spot inside the circle, on the ground if there's terrain.
func _spot(centre: Vector3, yaw: float, radius: float, rng: RandomNumberGenerator) -> Dictionary:
	var angle := rng.randf() * TAU
	var distance := sqrt(rng.randf()) * radius # the square root spreads spots evenly over the circle, not bunched in the middle
	var at := centre + Vector3(cos(angle) * distance, 0.0, sin(angle) * distance)
	at.y = _ground_height(at)
	return {"position": at, "yaw": yaw}


## The height a pawn appears at here: on terrain, just above the ground (building that chunk first if it isn't yet, since the server
## may have no ground there); without terrain, the height it was given.
func _ground_height(at: Vector3) -> float:
	for node in get_tree().get_nodes_in_group(TerrainGenerator.GROUP):
		var terrain := node as TerrainGenerator
		if terrain:
			terrain.load_chunk(terrain.chunk_of(at))
			return terrain.height_at(at.x, at.z) + ground_lift
	return at.y


## True if no pawn body is within clearance_radius of a new pawn's middle here.
func _is_free(world_node: Node3D, feet: Vector3) -> bool:
	if clearance_radius <= 0.0 or not world_node.is_inside_tree():
		return true
	var sphere := SphereShape3D.new()
	sphere.radius = clearance_radius
	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = sphere
	query.transform = Transform3D(Basis.IDENTITY, feet + Vector3(0.0, 0.9, 0.0)) # about a pawn's middle
	query.collision_mask = pawn_layers
	return world_node.get_world_3d().direct_space_state.intersect_shape(query, 1).is_empty()


## A pawn type's team, read from its scene once: an instance is made, read and freed, without entering the tree.
func _team_of(type_name: String) -> int:
	if not _team_of_type.has(type_name):
		var team := -1
		var scene: PackedScene = _session.get_type_scene(type_name) if _session else null
		if scene:
			var probe := scene.instantiate()
			if "team" in probe:
				team = probe.team
			probe.free()
		_team_of_type[type_name] = team
	return _team_of_type[type_name]


## GDScript note: tick_rng hands back one shared generator, seeded from the tick and these numbers, so it's used at once and never
## kept. The spawn count as the key means two spawns in one tick roll differently.
func _next_rng() -> RandomNumberGenerator:
	return _driver.tick_rng(_spawn_count, RANDOM_SALT) if _driver else RandomNumberGenerator.new()


## Between ticks: runs every delay whose tick has come, in the order they were asked for.
func _run_due() -> void:
	if _pending.is_empty():
		return
	var now: int = _driver.tick
	var ready: Array = []
	var still: Array = []
	for entry: Array in _pending:
		(ready if entry[0] <= now else still).append(entry)
	_pending = still
	for entry: Array in ready:
		var what: Callable = entry[1]
		if what.is_valid():
			what.call()
