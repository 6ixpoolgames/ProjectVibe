# Written by Claude (claude-opus-5-5), 2026-11-10. History: game_mode/CHANGELOG.md.
## Puts pawns into the world at SpawnPoints, and brings players back after they die.
##
## A module of GameMode (GameMode.spawn_manager), like Unreal's GameMode picking a PlayerStart. With no spawn points placed it does
## nothing. Server or offline only. Type names are NetworkSession's (register_type), so every spawned pawn exists on every machine;
## a pawn's team comes from its scene. Delays count ticks on TickDriver and run between ticks, so pausing the driver pauses them.
## [codeblock]
## GameMode.spawn_manager.spawn("goblin", &"red_base")     # at a point in that group
## GameMode.spawn_manager.spawn_near("goblin", node, 3.0)  # within 3 m of a node (PawnSpawner uses this)
## GameMode.spawn_manager.spawn_player(peer)               # possessed for them, and brought back when it dies
## [/codeblock]
## Points are chosen by team and group, shuffled with the tick's random numbers (repeatable); the first free spot wins (README).
class_name SpawnManager
extends GameModeModule

## Sent on the server or offline for every pawn this manager spawns.
signal pawn_spawned(pawn: Pawn)
## Sent when a player's pawn comes back after dying.
signal player_respawned(peer: int, pawn: Pawn)

## On: players' pawns come back after dying.
@export var respawn_players := true
## How long a player's pawn stays dead, in ticks at 60 a second (180: 3 s).
@export_range(0, 3600, 1, "or_greater") var player_respawn_ticks := 180
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
## For how many ticks a spot it handed out counts as taken, until physics has stepped and sees the pawn there
## itself. 2 covers a frame that runs two ticks.
@export_range(1, 60, 1) var claim_ticks := 2

## The most pawns spawners ([PawnSpawner]) may spawn in one tick; the rest wait for the next ticks, so a wave or a burst of
## replacements is spread out instead of landing in one frame (a pawn costs about 10 ms to spawn). 0: no limit. Players' pawns
## ([method spawn_player]) are never held back, but count towards it.
@export_range(0, 64, 1, "or_greater") var max_spawns_per_tick := 1

## Separates these rolls from other users of the same tick's random numbers (DeterministicRandom).
const RANDOM_SALT := 7151

var _session: Node = null
var _driver: Node = null
var _game_mode: GameModeSingleton = null
var _players := {} # pawn instance id -> peer
var _team_of_type := {} # type name -> team, read once from its scene
# Every roll counts, spawns and respawns alike, so each one differs, even several in one tick, and players brought back in the same
# tick don't try the same spots.
var _roll_count := 0
var _claimed: Array = [] # [tick, feet position] of each spot handed out lately (claim_ticks)
var _counted_tick := -1 # the tick _spawned_in_tick counts for
var _spawned_in_tick := 0


func _init() -> void:
	set_process(false)
	set_physics_process(false)


func _on_module_added(game_mode: GameModeSingleton) -> void:
	game_mode.spawn_manager = self
	_game_mode = game_mode
	_session = get_node_or_null("/root/NetworkSession")
	_driver = get_node_or_null("/root/TickDriver")


func _on_module_removed(game_mode: GameModeSingleton) -> void:
	game_mode.spawn_manager = null


## The settings a start menu may offer (GameModeModule.get_match_options).
func get_match_options() -> PackedStringArray:
	return PackedStringArray(["respawn_players", "player_respawn_ticks"])


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
	var place := _free_spot(around, around.global_position, around.global_basis.get_euler().y, scatter_radius)
	if place.is_empty():
		place = _spot(around.global_position, around.global_basis.get_euler().y, scatter_radius) # crowded, but it still spawns
	return _spawn_at(type_name, owner_peer, place)


## A player's pawn: spawned at a point for its team, possessed for this player, and brought back when it dies (respawn_players).
## peer is the player's network peer; offline, anything (it's possessed for the one local player).
func spawn_player(peer: int, type_name: String = "pawn", group: StringName = &"") -> Pawn:
	var serving: bool = _session != null and _session.is_server()
	var pawn := spawn(type_name, group, peer if serving else 0)
	if pawn == null:
		return null
	_players[pawn.get_instance_id()] = peer
	# The instance id is bound, not the pawn, so a pawn freed before the call doesn't break it.
	if pawn.ability_manager: # died is the AbilityManager's signal
		pawn.ability_manager.died.connect(_on_player_died.bind(pawn.get_instance_id()))
	var coordinator: PossessionCoordinator = _game_mode.possession_coordinator if _game_mode else null
	if coordinator:
		if serving:
			coordinator.possess_for(peer, pawn)
		else:
			coordinator.possess(pawn)
	return pawn


## Where a pawn of this team would appear, asked for with this group: {"position": Vector3, "yaw": float}, or {} with no point.
## See "How a spawn point is chosen" in the README.
func find_place(team: int, group: StringName = &"") -> Dictionary:
	var points: Array[SpawnPoint] = []
	for node in get_tree().get_nodes_in_group(SpawnPoint.GROUP):
		var point := node as SpawnPoint
		if point and point.is_inside_tree() and point.accepts(team, group):
			points.append(point)
	if points.is_empty():
		return {}
	# Tree order first, so the same points shuffle the same way for the same roll.
	for i in range(points.size() - 1, 0, -1): # Fisher-Yates shuffle with repeatable random numbers
		var j := mini(int(_roll() * (i + 1)), i)
		var swap := points[i]
		points[i] = points[j]
		points[j] = swap
	for point in points:
		var place := _free_spot(point, point.global_position, point.get_yaw(), point.scatter_radius)
		if not place.is_empty():
			return place
	return _spot(points[0].global_position, points[0].get_yaw(), points[0].scatter_radius)


## Runs what after this many ticks (at 60 a second, converted to the match's rate), booked with the tick scheduler: it runs just
## before the tick it's due on, between ticks. Pausing the tick driver pauses the count. For delays that are part of the game's rules,
## such as respawns and body removal.
func after_ticks(ticks: int, what: Callable) -> void:
	if _driver:
		_driver.scheduler.book(_driver.tick + _driver.ticks_at_rate(ticks), what)


# --- Players ---


func _on_player_died(_pawn: Pawn, _hit: HitInfo, pawn_id: int) -> void:
	if respawn_players:
		after_ticks(player_respawn_ticks, _respawn_player.bind(pawn_id))


func _respawn_player(pawn_id: int) -> void:
	var pawn := instance_from_id(pawn_id) as Pawn
	if pawn == null or not pawn.is_dead():
		return # gone, or something else already brought it back
	if player_respawn_at_spawn_point:
		var place := find_place(pawn.team)
		if not place.is_empty():
			pawn.yaw = place["yaw"] # before the teleport, so its Visual is drawn facing that way at once too
			pawn.velocity = Vector3.ZERO
			pawn.teleport(place["position"])
			_claim(place["position"]) # so another player brought back this tick goes somewhere else
	if pawn.ability_manager:
		pawn.ability_manager.revive()
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
	var started := PerfScopes.begin() # timed for diagnostics, as spawning.spawn
	var pawn := _session.spawn(type_name, owner_peer, place["position"]) as Pawn
	if pawn == null:
		return null
	pawn.yaw = place["yaw"]
	_claim(place["position"]) # so the next pawn spawned this tick goes somewhere else
	_count_spawn()
	pawn_spawned.emit(pawn)
	PerfScopes.end(&"spawning.spawn", started)
	return pawn


## A free spot near this centre, or {}. The node is only for its physics world.
func _free_spot(world_node: Node3D, centre: Vector3, yaw: float, radius: float) -> Dictionary:
	for i in tries_per_point:
		# The first try is the point itself, so a point with no scatter still gets checked once.
		var place := _spot(centre, yaw, radius if i > 0 else 0.0)
		if _is_free(world_node, place["position"]):
			return place
	return {}


## A spot inside the circle, on the ground if there's terrain.
func _spot(centre: Vector3, yaw: float, radius: float) -> Dictionary:
	var angle := _roll() * TAU
	var distance := sqrt(_roll()) * radius # the square root spreads spots evenly over the circle, not bunched in the middle
	var at := centre + Vector3(cos(angle) * distance, 0.0, sin(angle) * distance)
	at.y = _ground_height(at)
	return {"position": at, "yaw": yaw}


# The chunk, landed now if it isn't yet: through the terrain's ChunkStreamer, so it's on this tick and recorded (state store spec 13.12),
# rather than published at a moment of its own. A terrain with no streamer builds it itself.
func _land_chunk(terrain: TerrainGenerator, key: Vector2i) -> void:
	if terrain.has_chunk(key):
		return
	for node in get_tree().get_nodes_in_group(ChunkStreamer.GROUP):
		var streamer := node as ChunkStreamer
		if streamer and streamer.terrain == terrain:
			streamer.land_now(key)
			return
	terrain.load_chunk(key)


## The height a pawn appears at here: on terrain, just above the ground (building that chunk first if it isn't yet, since the server
## may have no ground there); without terrain, the height it was given.
func _ground_height(at: Vector3) -> float:
	for node in get_tree().get_nodes_in_group(TerrainGenerator.GROUP):
		var terrain := node as TerrainGenerator
		if terrain:
			_land_chunk(terrain, terrain.chunk_of(at))
			return terrain.height_at(at.x, at.z) + ground_lift
	return at.y


## True if no pawn body is within clearance_radius of a new pawn's middle here, and no spot handed out lately is within twice
## clearance_radius (two pawns' worth), since physics doesn't see those pawns yet.
func _is_free(world_node: Node3D, feet: Vector3) -> bool:
	if clearance_radius <= 0.0 or not world_node.is_inside_tree():
		return true
	_forget_old_claims()
	for claim: Array in _claimed:
		if (claim[1] as Vector3).distance_to(feet) < clearance_radius * 2.0:
			return false
	# REFACTOR: a new shape and query for every spot tried. Made once and reused, a wave of spawns would allocate nothing (efficient).
	var sphere := SphereShape3D.new()
	sphere.radius = clearance_radius
	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = sphere
	query.transform = Transform3D(Basis.IDENTITY, feet + Vector3(0.0, 0.9, 0.0)) # about a pawn's middle
	query.collision_mask = pawn_layers
	return world_node.get_world_3d().direct_space_state.intersect_shape(query, 1).is_empty()


## Remembers a spot a pawn was just put on, for claim_ticks ticks (see the README).
func _claim(feet: Vector3) -> void:
	_forget_old_claims()
	_claimed.append([_driver.tick if _driver else 0, feet])


# Drops claims older than claim_ticks, by which time physics has stepped and sees those pawns itself.
func _forget_old_claims() -> void:
	var now: int = _driver.tick if _driver else 0
	_claimed = _claimed.filter(func(claim: Array) -> bool: return now - int(claim[0]) < claim_ticks)


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


## How many more pawns spawners may spawn this tick ([member max_spawns_per_tick]); a large number with no limit.
func spawns_left_this_tick() -> int:
	if max_spawns_per_tick <= 0:
		return 1 << 30
	var now: int = _driver.tick if _driver else 0
	return max_spawns_per_tick - (_spawned_in_tick if _counted_tick == now else 0)


func _count_spawn() -> void:
	var now: int = _driver.tick if _driver else 0
	if _counted_tick != now:
		_counted_tick = now
		_spawned_in_tick = 0
	_spawned_in_tick += 1


# The next roll, from 0 up to 1: from the tick and the roll count, which keeps two rolls in one tick different.
func _roll() -> float:
	_roll_count += 1
	return DeterministicRandom.unit(_roll_count, _driver.tick if _driver else 0, RANDOM_SALT)
