## Written by Claude (claude-opus-5-5), 2026-11-07: switches AI pawns off when the ground around them isn't loaded, and back on
## Claude 2026-11-07: renamed from AIActivityModule, and reached as GameMode.ai_activation_manager, so that the name says what it does.
## when it is. So a horde costs almost nothing where no player is, and nothing walks off the edge of the world. Claude 2026-11-07:
## a Pawn stops its NetworkEntity and TickState too, which leaves only this module's checks, and it's left out of snapshots while off.
##
## The rule: an AI pawn runs only while every chunk within edge_margin of it is built. In other words, it's near enough to a
## source. A pawn with its own active source has ground wherever it goes, so it's never switched off.
## Claude 2026-11-16 (pawn M2): every pawn is watched, and one that keeps the world loaded (counts_on_this_machine, the source contract) is left
## running, checked each time it's looked at. Nothing has to tell this when that changes, so a pawn can't be left unwatched. A
## possession is checked at once (its ControllerManager's possession_changed signal), so a frozen pawn a player takes starts at once.
##
## This is a first pass, chosen by the owner for tier 0. It's meant to be replaced or added to: a game that needs AI simulated
## out of sight, such as ecology, migration or faction wars, can listen to ai_deactivated and ai_activated, and simulate those
## pawns some cheaper way while they're off. None of that exists yet.
##
## What a pawn needs:
##   - to call GameMode.ai_activation_manager.add_pawn(self) when it's an AI pawn, and remove_pawn(self) when it stops being one
##   - a method set_frozen(frozen: bool), which stops and restarts its ticks and leaves all its state as it is (Claude 2026-11-16:
##     was set_simulation_active(active), renamed in pawn M1)
##
## Claude 2026-11-16 (pawn spec 8.21, scaling spec 7.1, the owner's call): it also decides how often each AI pawn it leaves on runs,
## its Pawn.tick_step, which it rechecks with the rest:
##   - every tick within full_rate_within_chunks chunks of the nearest viewer, every 2nd tick up to every_4th_tick_beyond_chunks
##     chunks, and every 4th beyond that, measured flat. Viewers are pawns a player has, and this machine's player's camera (a
##     spectator, or the overview). With no viewer at all, distance changes nothing.
##   - and at least TickDriver.load_step, the load ladder: while the game is overloaded, every AI pawn runs every 2nd or 4th tick.
##   - a pawn a player has always runs every tick.
## So a pawn far from the action costs a half or a quarter as much, and still walks as far and fights as long (Pawn.ticks_elapsed).
## Only the server or offline does this; a client's pawns are told their step in snapshots, where it's rolled-back state.
##
## What happens in odd cases (all checked in game_mode/tests/game_mode_selftest.gd):
##   - No terrain in the scene: every pawn stays on.
##   - On a client: this does nothing, because AI only runs on the server.
##   - A pawn that's freed: it's dropped from the list.
##   - The module is removed: every pawn it switched off goes back on.
class_name AIActivationManager
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
## Claude 2026-11-16 (pawn spec 8.21): on, AI pawns far from every viewer run every 2nd or 4th tick. Off, distance changes nothing
## (the load ladder still applies).
@export var steps_by_distance := true
## Claude 2026-11-16: within this many chunks of the nearest viewer, an AI pawn runs every tick.
@export_range(0.25, 64.0, 0.25, "or_greater") var full_rate_within_chunks := 2.0
## Claude 2026-11-16: beyond this many chunks of the nearest viewer, every 4th tick; between the two, every 2nd.
@export_range(0.25, 64.0, 0.25, "or_greater") var every_4th_tick_beyond_chunks := 4.0

var _pawns: Array[Node3D] = []
var _inactive: Dictionary = {} # pawn -> true
var _next_pawn := 0
var _session: Node = null
var _terrains: Array[TerrainGenerator] = []
var _connected_terrains := {} # TerrainGenerator -> true
var _check_everyone := false
var _viewers := PackedVector3Array() # Claude 2026-11-16: where the viewers are this frame
var _chunk_size := 64.0 # Claude 2026-11-16: from the first terrain, for the distances


func _init() -> void:
	# After ChunkStreamer's -200, so new ground counts, and before TickDriver's -100, so nothing ticks over ground that's gone.
	process_physics_priority = -150


func _on_module_added(game_mode: GameModeSingleton) -> void:
	game_mode.ai_activation_manager = self
	_session = get_node_or_null("/root/NetworkSession")


func _on_module_removed(game_mode: GameModeSingleton) -> void:
	game_mode.ai_activation_manager = null
	for pawn: Node3D in _inactive.keys():
		if is_instance_valid(pawn):
			_set_active(pawn, true)
	_inactive.clear()
	for pawn: Node3D in _pawns: # Claude 2026-11-16: back to every tick
		if is_instance_valid(pawn) and &"tick_step" in pawn:
			pawn.tick_step = 1


## Claude 2026-11-16: the settings a start menu may offer (GameModeModule.get_match_options).
func get_match_options() -> PackedStringArray:
	return PackedStringArray(["steps_by_distance", "full_rate_within_chunks", "every_4th_tick_beyond_chunks"])


## Starts watching an AI pawn. Adding the same one twice does nothing.
func add_pawn(pawn: Node3D) -> void:
	if pawn != null and not _pawns.has(pawn):
		_pawns.append(pawn)
		# Claude 2026-11-16 (pawn M2): a pawn a player takes or lets go is checked at once, rather than at its next turn.
		# Claude 2026-11-16 (pawn M4): the signal is the ControllerManager's now.
		var controllers: Node = pawn.get(&"controller_manager")
		if controllers and not controllers.possession_changed.is_connected(_on_possession_changed):
			controllers.possession_changed.connect(_on_possession_changed)
		_refresh_terrains()
		_check_pawn(pawn) # at once, so a pawn spawned out where there's no ground never takes a tick there


## Stops watching a pawn, such as one a player has taken over. If it was off, it goes back on.
func remove_pawn(pawn: Node3D) -> void:
	_pawns.erase(pawn)
	var controllers: Node = pawn.get(&"controller_manager") if is_instance_valid(pawn) else null # Claude 2026-11-16 (pawn M4)
	if controllers and controllers.possession_changed.is_connected(_on_possession_changed):
		controllers.possession_changed.disconnect(_on_possession_changed)
	if _inactive.has(pawn):
		_inactive.erase(pawn)
		if is_instance_valid(pawn):
			_set_active(pawn, true)


func is_active(pawn: Node3D) -> bool:
	return not _inactive.has(pawn)


## Claude 2026-11-16 (pawn spec 8.21): how many watched pawns run at each step now, for diagnostics: {1: n, 2: n, 4: n}. Frozen
## pawns aren't counted.
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


func get_watched_count() -> int:
	return _pawns.size()


func _physics_process(_delta: float) -> void:
	var started := PerfScopes.begin() # Claude 2026-11-16: timed for diagnostics (PerfScopes)
	_check_pawns()
	PerfScopes.end(&"ai.activation", started)


# Claude 2026-11-16: the work itself, timed by _physics_process.
func _check_pawns() -> void:
	if _pawns.is_empty():
		return
	_refresh_terrains()
	_find_viewers() # Claude 2026-11-16 (pawn spec 8.21)
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
	# Claude 2026-11-16 (pawn M2): a pawn that keeps the world loaded always has ground.
	var keeps_loaded: bool = pawn.has_method(&"counts_on_this_machine") and pawn.counts_on_this_machine()
	var has_ground := keeps_loaded or _has_ground_around(pawn.global_position)
	if has_ground and _inactive.has(pawn):
		_inactive.erase(pawn)
		_set_active(pawn, true)
		ai_activated.emit(pawn)
	elif not has_ground and not _inactive.has(pawn):
		_inactive[pawn] = true
		_set_active(pawn, false)
		ai_deactivated.emit(pawn)
	# Claude 2026-11-16 (pawn spec 8.21): how often it runs, while it runs.
	if has_ground and &"tick_step" in pawn:
		pawn.tick_step = step_for(pawn)


## Claude 2026-11-16 (pawn spec 8.21): how often this pawn should run now: 1 (every tick), 2 or 4. See the top of the file.
func step_for(pawn: Node3D) -> int:
	var controllers: Node = pawn.get(&"controller_manager")
	if controllers and controllers.has_player():
		return 1
	var step := 1
	if steps_by_distance and not _viewers.is_empty():
		var nearest := INF
		for viewer in _viewers:
			nearest = minf(nearest, Vector2(viewer.x - pawn.global_position.x, viewer.z - pawn.global_position.z).length_squared())
		nearest = sqrt(nearest)
		if nearest >= every_4th_tick_beyond_chunks * _chunk_size:
			step = 4
		elif nearest >= full_rate_within_chunks * _chunk_size:
			step = 2
	return maxi(step, TickDriver.load_step) # Claude 2026-11-16 (wider audit): the autoload, where it was looked up by path for every pawn


# Claude 2026-11-16 (pawn spec 8.21): the viewers this frame: pawns a player has, and this machine's player's camera while it's in use.
func _find_viewers() -> void:
	_viewers.clear()
	_chunk_size = 64.0
	for terrain in _terrains:
		if is_instance_valid(terrain):
			_chunk_size = terrain.chunk_size
			break
	# Claude 2026-11-16 (wider audit): a pawn with a player is among the streaming sources (Pawn._update_source_group), so only those
	# few are looked at. This went through every watched pawn every frame.
	for node in get_tree().get_nodes_in_group(StreamingSource.GROUP):
		var pawn := node as Pawn
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


## A pawn could be standing on it. Its next tick can't wait for its turn in the staggered checks, so everyone gets checked
## before the next tick. At most one chunk unloads per frame.
func _on_chunk_removed(_key: Vector2i) -> void:
	_check_everyone = true


func _on_possession_changed(pawn: Node3D, _has_player: bool) -> void:
	if is_instance_valid(pawn) and _pawns.has(pawn):
		_check_pawn(pawn)


func _set_active(pawn: Node3D, active: bool) -> void:
	if pawn.has_method(&"set_frozen"): # Claude 2026-11-16 (pawn M1): renamed
		pawn.set_frozen(not active)
