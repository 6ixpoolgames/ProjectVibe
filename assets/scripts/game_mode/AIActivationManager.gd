# Written by Claude (claude-opus-5-5), 2026-11-07. History: game_mode/CHANGELOG.md.
## Switches AI pawns off when the ground around them isn't loaded, back on when it is, and sets how often the rest run.
##
## A module of GameMode (GameMode.ai_activation_manager), server or offline only. An AI pawn runs only while every chunk within
## [member edge_margin] of it is built; a pawn that keeps the world loaded ([method Pawn.is_keeping_world_loaded]) is always left on,
## and a possession is checked at once. A pawn that's off stops its NetworkEntity and TickState and is left out of snapshots. Pawns
## register with [method add_pawn] and [method remove_pawn] (Pawn does both) and need a [code]set_frozen(frozen)[/code].
## [br]
## It also sets [member Pawn.tick_step] for each running AI pawn: every tick within [member full_rate_within_chunks] chunks of the
## nearest viewer (pawns a player has, and this machine's player's camera), every 2nd up to [member every_4th_tick_beyond_chunks],
## every 4th beyond, and never less often than TickDriver.load_step. Distance is in whole chunk rings, not metres, so pawns in one
## chunk share a rate. A pawn a player has always runs every tick. A game can listen to [signal ai_deactivated] and
## [signal ai_activated] to simulate switched-off pawns more cheaply. Design: pawn spec 8.21, scaling spec 7.1.
# REFACTOR: two jobs in one module, switching pawns off and choosing their tick step, and the name says only the first. Splitting the
# step rule into its own module (or renaming this one) would let a game swap either alone (names say what things do, extensible).
class_name AIActivationManager
extends GameModeModule

## Sent when a pawn is switched off, because the ground around it isn't loaded.
signal ai_deactivated(pawn: Node3D)
## Sent when a pawn is switched back on.
signal ai_activated(pawn: Node3D)

## How close a pawn may get to unbuilt ground, in metres. It has to be further than the pawn moves between its checks,
## about 0.5 m for a walking pawn at the default of 6 ticks.
@export var edge_margin := 2.0
## Each pawn is checked once in this many ticks (physics frames without the tick driver), so a big horde isn't all checked at once.
@export_range(1, 60, 1) var spread_over_ticks := 6
## The most pawns checked in one tick, however many there are. A very large horde takes longer to get through, so with a lot of fast
## pawns, raise edge_margin too. A removed chunk is always handled at once, so this only delays walking to an edge.
@export_range(1, 100000, 1, "or_greater") var max_checks_per_tick := 500
## On, AI pawns far from every viewer run every 2nd or 4th tick (pawn spec 8.21). Off, distance changes nothing (the load ladder
## still applies).
@export var steps_by_distance := true
## Within this many chunks of the nearest viewer, an AI pawn runs every tick. Counted in whole rings of chunks.
@export_range(0.25, 64.0, 0.25, "or_greater") var full_rate_within_chunks := 2.0
## Beyond this many chunks of the nearest viewer, every 4th tick; between the two, every 2nd.
@export_range(0.25, 64.0, 0.25, "or_greater") var every_4th_tick_beyond_chunks := 4.0

var _pawns: Array[Node3D] = []
var _inactive: Dictionary = {} # pawn -> true
var _next_pawn := 0
var _session: Node = null
var _terrains: Array[TerrainGenerator] = []
var _connected_terrains := {} # TerrainGenerator -> true
var _check_everyone := false
var _viewers := PackedVector3Array() # where the viewers are this frame
var _chunk_size := 64.0 # from the first terrain, for the distances
var _driver: Node = null


func _init() -> void:
	# Without the tick driver: after ChunkStreamer's -200, so new ground counts, and before pawns that tick themselves.
	process_physics_priority = -150


func _on_module_added(game_mode: GameModeSingleton) -> void:
	game_mode.ai_activation_manager = self
	_session = get_node_or_null("/root/NetworkSession")
	# With the tick driver, the checks run before each tick, so which pawns are checked when doesn't depend on how many ticks a frame
	# runs (deterministic, as the landing schedule is).
	_driver = get_node_or_null("/root/TickDriver")
	if _driver and not _driver.before_tick.is_connected(_on_before_tick):
		_driver.before_tick.connect(_on_before_tick)


func _on_module_removed(game_mode: GameModeSingleton) -> void:
	game_mode.ai_activation_manager = null
	if _driver and _driver.before_tick.is_connected(_on_before_tick):
		_driver.before_tick.disconnect(_on_before_tick)
	for pawn: Node3D in _inactive.keys():
		if is_instance_valid(pawn):
			_set_active(pawn, true)
	_inactive.clear()
	for pawn: Node3D in _pawns: # back to every tick
		if is_instance_valid(pawn) and &"tick_step" in pawn:
			pawn.tick_step = 1


## The settings a start menu may offer (GameModeModule.get_match_options).
func get_match_options() -> PackedStringArray:
	return PackedStringArray(["steps_by_distance", "full_rate_within_chunks", "every_4th_tick_beyond_chunks"])


## Starts watching a pawn. Adding the same one twice does nothing.
func add_pawn(pawn: Node3D) -> void:
	if pawn != null and not _pawns.has(pawn):
		_pawns.append(pawn)
		# A pawn a player takes or lets go is checked at once (its ControllerManager's signal), rather than at its next turn.
		var controllers: Node = pawn.get(&"controller_manager")
		if controllers and not controllers.possession_changed.is_connected(_on_possession_changed):
			controllers.possession_changed.connect(_on_possession_changed)
		_refresh_terrains()
		_check_pawn(pawn) # at once, so a pawn spawned out where there's no ground never takes a tick there


## Stops watching a pawn, such as one leaving the tree. If it was off, it goes back on.
func remove_pawn(pawn: Node3D) -> void:
	_pawns.erase(pawn)
	var controllers: Node = pawn.get(&"controller_manager") if is_instance_valid(pawn) else null
	if controllers and controllers.possession_changed.is_connected(_on_possession_changed):
		controllers.possession_changed.disconnect(_on_possession_changed)
	if _inactive.has(pawn):
		_inactive.erase(pawn)
		if is_instance_valid(pawn):
			_set_active(pawn, true)


## False while this pawn is switched off.
func is_active(pawn: Node3D) -> bool:
	return not _inactive.has(pawn)


## How many watched pawns run at each step now, for diagnostics: {1: n, 2: n, 4: n}. Frozen pawns aren't counted.
func get_step_counts() -> Dictionary:
	var counts := {1: 0, 2: 0, 4: 0}
	for pawn: Node3D in _pawns:
		if is_instance_valid(pawn) and not _inactive.has(pawn) and &"tick_step" in pawn:
			var step: int = pawn.tick_step
			counts[step] = counts.get(step, 0) + 1
	return counts


## How many pawns are off right now.
func get_inactive_count() -> int:
	return _inactive.size()


## How many pawns are watched, on or off.
func get_watched_count() -> int:
	return _pawns.size()


func _physics_process(_delta: float) -> void:
	if not _on_ticks():
		_timed_check()


func _on_before_tick(_dt: float, _tick: int) -> void:
	if _on_ticks() and not TickDriver.is_resimulating():
		_timed_check()


func _timed_check() -> void:
	var started := PerfScopes.begin() # timed for diagnostics (PerfScopes)
	_check_pawns()
	PerfScopes.end(&"ai.activation", started)


# True while the tick driver runs: the checks are on its ticks then.
func _on_ticks() -> bool:
	return _driver != null and _driver.active


# The work itself, timed by _timed_check.
func _check_pawns() -> void:
	if _pawns.is_empty():
		return
	_refresh_terrains()
	_find_viewers()
	if _check_everyone:
		_check_everyone = false
		for pawn: Node3D in _pawns:
			if is_instance_valid(pawn):
				_check_pawn(pawn)
	var count := mini(ceili(float(_pawns.size()) / spread_over_ticks), max_checks_per_tick)
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
	# A pawn that keeps the world loaded always has ground.
	var keeps_loaded: bool = pawn is Pawn and (pawn as Pawn).is_keeping_world_loaded()
	var has_ground := keeps_loaded or _has_ground_around(pawn.global_position)
	if has_ground and _inactive.has(pawn):
		_inactive.erase(pawn)
		_set_active(pawn, true)
		ai_activated.emit(pawn)
	elif not has_ground and not _inactive.has(pawn):
		_inactive[pawn] = true
		_set_active(pawn, false)
		ai_deactivated.emit(pawn)
	# How often it runs, while it runs.
	if has_ground and &"tick_step" in pawn:
		pawn.tick_step = step_for(pawn)


## How often this pawn should run now: 1 (every tick), 2 or 4. See the class description.
func step_for(pawn: Node3D) -> int:
	var controllers: Node = pawn.get(&"controller_manager")
	if controllers and controllers.has_player():
		return 1
	var step := 1
	if steps_by_distance and not _viewers.is_empty():
		# The nearest viewer's ring of chunks, in whole chunks (see the class description). The ring is the larger of the two grid
		# steps between the chunks, so a ring is a square of chunks round the viewer's.
		var at := _chunk_of(pawn.global_position)
		var nearest := 1 << 30
		for viewer in _viewers:
			var from := _chunk_of(viewer)
			nearest = mini(nearest, maxi(absi(at.x - from.x), absi(at.y - from.y)))
		if nearest >= every_4th_tick_beyond_chunks:
			step = 4
		elif nearest >= full_rate_within_chunks:
			step = 2
	return maxi(step, TickDriver.load_step)


# The chunk-sized square a position is in, counted from the world origin (x and z). The same squares as the terrain's chunks when it
# sits at the origin; either way, pawn and viewer are measured on the same squares.
func _chunk_of(at: Vector3) -> Vector2i:
	return Vector2i(floori(at.x / _chunk_size), floori(at.z / _chunk_size))


# The viewers this frame: pawns a player has, and this machine's player's camera while it's in use.
func _find_viewers() -> void:
	_viewers.clear()
	_chunk_size = 64.0
	for terrain in _terrains:
		if is_instance_valid(terrain):
			_chunk_size = terrain.chunk_size
			break
	# A pawn with a player has its streaming source in the sources' group (PawnStreamingSource), so only those few are looked at.
	for node in get_tree().get_nodes_in_group(StreamingSource.GROUP):
		var source := node as PawnStreamingSource
		var pawn := source.pawn if source else null
		if pawn and pawn.controller_manager and pawn.controller_manager.has_player():
			_viewers.append(pawn.global_position)
	var game_mode: Node = get_node_or_null(^"/root/GameMode")
	var coordinator: PossessionCoordinator = game_mode.possession_coordinator if game_mode else null
	var camera: Camera3D = coordinator.controller.camera if coordinator and coordinator.controller else null
	if camera and camera.is_inside_tree() and camera.current:
		_viewers.append(camera.global_position)


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
	for node in get_tree().get_nodes_in_group(TerrainGenerator.GROUP):
		var terrain := node as TerrainGenerator
		if terrain != null:
			_terrains.append(terrain)
			if not _connected_terrains.has(terrain):
				_connected_terrains[terrain] = true
				terrain.chunk_removed.connect(_on_chunk_removed)


## A pawn could be standing on it, and can't wait for its turn in the staggered checks. During a tick (chunks unload in before_tick,
## at most one a tick) everyone is checked at once, before the tick runs; without the tick driver, at the next check.
func _on_chunk_removed(_key: Vector2i) -> void:
	_check_everyone = true
	if _on_ticks():
		_check_pawns()


func _on_possession_changed(pawn: Node3D, _has_player: bool) -> void:
	if is_instance_valid(pawn) and _pawns.has(pawn):
		_check_pawn(pawn)


func _set_active(pawn: Node3D, active: bool) -> void:
	if pawn.has_method(&"set_frozen"):
		pawn.set_frozen(not active)
