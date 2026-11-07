## Claude 2026-11-07: renamed from WorldNavLink, so that the name says what it does: it feeds nav from a terrain generator.
## Written by Claude (claude-opus-5-5), 2026-11-07: connects a TerrainGenerator to nav, so that neither has to know the other exists. Spec:
## docs/world/WORLD_SPEC.md. TerrainGenerator says when a chunk is built or removed. This hands its triangles to NavServer and announces its markers
## to NavMarkerManager. It also keeps nav built around every StreamingSource, and can tick NavServer.
##
## How to use it: normally it's a child of a WorldCoordinator, which tells it which terrain to use. It also works as a child of a TerrainGenerator
## with no coordinator at all. Give it a NavHooks to feed nav. With none, it only announces markers, which need no C++ library.
##
## What happens in odd cases (all checked in world/tests/world_coordinator_selftest.gd):
##   - No terrain: it warns and does nothing.
##   - It arrives after chunks are built: it catches up on them.
##   - The nav library isn't loaded: it warns, and markers still work.
##   - It leaves the scene: nav and NavMarkerManager forget everything it told them, and it tells them again if it comes back.
class_name TerrainNavFeeder
extends Node

## The terrain to feed from. If it's empty and this node's parent is a terrain, it uses the parent.
@export var terrain: TerrainGenerator
## Give this a NavHooks resource to feed nav. Leave it empty to keep the terrain invisible to nav.
# Typed as Resource instead of NavHooks, and NavServer is looked up by name below. Writing either name directly would stop this script
# compiling on a build without the nav DLL. This way, a game that doesn't use nav always works.
# GDScript note: @export_custom sets the inspector hint by hand. This one offers only NavHooks in the picker.
@export_custom(PROPERTY_HINT_RESOURCE_TYPE, "NavHooks") var nav_hooks: Resource
## The nav system needs one tick per physics frame from somewhere. Turn this on if nothing else in the scene does it.
@export var tick_nav := false
## How often to check where the sources are, in seconds.
@export_range(0.0, 2.0, 0.01, "or_greater") var refresh_seconds := 0.2
## How far past a source's nav distance its nav stays built, in metres, so hovering around the edge doesn't rebuild it.
@export_range(0.0, 1000.0, 1.0, "or_greater") var unload_margin := 64.0

var _nav: Object = null # the NavServer, or null when this isn't feeding nav
var _nav_layer := -1 # our layer's number in the NavServer, or -1 for none
var _terrain_id := 0 # our id in NavMarkerManager, or 0 when not registered
var _fed := {} # Vector2i -> true, the chunks nav and NavMarkerManager have been told about
var _nav_interests := {} # a source's instance id -> its interest id in NavServer
var _refresh_timer := 0.0
var _listening_to: TerrainGenerator = null


func _init() -> void:
	# The same as ChunkStreamer: before TickDriver's -100, so nav is up to date before anything ticks in a physics frame.
	process_physics_priority = -200


func _enter_tree() -> void:
	if terrain == null:
		terrain = get_parent() as TerrainGenerator # GDScript note: "as" gives null when the parent isn't a terrain, rather than an error
	if terrain == null:
		push_warning("TerrainNavFeeder: no terrain to feed from, so this does nothing. Set its terrain.")
		return
	_listening_to = terrain
	terrain.chunk_built.connect(_on_chunk_built)
	terrain.chunk_removed.connect(_on_chunk_removed)
	terrain.generation_started.connect(_register_terrain)
	_connect_to_nav()
	_register_terrain()
	for key: Vector2i in terrain.get_loaded_chunks():
		_on_chunk_built(key, terrain.get_chunk_triangles(key))


func _exit_tree() -> void:
	# GDScript note: is_instance_valid is false for a freed object, which a plain null check wouldn't catch.
	if is_instance_valid(_listening_to):
		_listening_to.chunk_built.disconnect(_on_chunk_built)
		_listening_to.chunk_removed.disconnect(_on_chunk_removed)
		_listening_to.generation_started.disconnect(_register_terrain)
	_listening_to = null
	_remove_all_nav_interests()
	if _nav and _nav_layer >= 0:
		_nav.remove_input_layer(_nav_layer) # this removes everything the layer held
	_nav_layer = -1
	if _terrain_id != 0:
		for key: Vector2i in _fed:
			NavMarkerManager.release_markers(_terrain_id, key)
		NavMarkerManager.unregister_terrain(_terrain_id)
		_terrain_id = 0
	_fed.clear()


## True if this is feeding nav right now.
func uses_nav() -> bool:
	return _nav != null and _nav_layer >= 0


## Checks the sources now, instead of waiting for the next refresh.
func refresh_now() -> void:
	_refresh_timer = refresh_seconds
	_update_nav_interests()


func _physics_process(delta: float) -> void:
	if tick_nav and Engine.has_singleton("NavServer"):
		Engine.get_singleton("NavServer").tick(delta)


func _process(delta: float) -> void:
	_refresh_timer -= delta
	if _refresh_timer <= 0.0:
		refresh_now()


# --- Chunks ---


func _on_chunk_built(key: Vector2i, triangles: PackedVector3Array) -> void:
	_fed[key] = true
	if uses_nav():
		# Nav works in world positions, so it's told where the terrain is. If the terrain moves later, nav won't know until the next
		# generate() or edit().
		_nav.submit_mesh(_nav_layer, _nav_mesh_id(key), triangles, terrain.global_transform)
	_announce_markers(key)


func _on_chunk_removed(key: Vector2i) -> void:
	if not _fed.has(key):
		return
	_fed.erase(key)
	if uses_nav():
		_nav.remove_mesh(_nav_layer, _nav_mesh_id(key))
	if _terrain_id != 0:
		NavMarkerManager.release_markers(_terrain_id, key)


## Nav knows each mesh by one number, so this packs the chunk's two grid numbers into one. Adding 2^20 keeps negative chunk numbers
## positive, and "<<" slides the first number along so the two don't overlap.
func _nav_mesh_id(key: Vector2i) -> int:
	return ((key.x + (1 << 20)) << 21) | (key.y + (1 << 20))


func _connect_to_nav() -> void:
	if nav_hooks == null:
		return
	if not Engine.has_singleton("NavServer"):
		push_warning("TerrainNavFeeder: nav_hooks is set, but the nav library isn't loaded. Nav won't see this terrain.")
		return
	_nav = Engine.get_singleton("NavServer")
	# Mesh input, not heightmap input: nav's heightmap input needs a regular grid, and jitter moves the points off it. It also fills each
	# column solid from the world floor, which would wipe out anything built underneath. Measured 2026-11-05 on 25 chunks of 1 m squares:
	# the first build takes about the same as heightmap input (about 95 ms against 90 ms), and rebuilding after an edit takes about twice
	# as long (17 ms against 8 ms).
	var adapter := ClassDB.class_get_integer_constant("NavServer", "ADAPTER_MESH")
	_nav_layer = _nav.add_input_layer(terrain, nav_hooks, adapter)


# --- Markers: telling NavMarkerManager what's in each chunk ---
# NavMarkerManager is plain GDScript, so all of this works without the nav library.


## Gives NavMarkerManager a copy of where the terrain is and how big its chunks are, and gets the id its chunks' markers use. The id comes from
## the terrain's path, so it matches on every machine.
func _register_terrain() -> void:
	if not terrain.is_inside_tree():
		return # it does this again when its generation starts
	var settings := TerrainSettings.new()
	settings.origin = terrain.global_position
	settings.chunk_size = terrain.chunk_size
	_terrain_id = NavMarkerManager.register_terrain(str(terrain.get_path()), settings)


## Replaces whatever this chunk has announced with a fresh list. Takes effect on NavMarkerManager's next tick.
func _announce_markers(key: Vector2i) -> void:
	if _terrain_id == 0:
		return
	NavMarkerManager.release_markers(_terrain_id, key)
	var markers := terrain.get_chunk_markers(key)
	if markers.is_empty():
		return
	if String(terrain.name).begins_with("@"):
		push_warning("TerrainNavFeeder: %s has an automatic name, so machines may disagree on its marker ids. Give it a name of its own." % terrain.get_path())
	NavMarkerManager.request_markers(_terrain_id, key, markers)


# --- Keeping nav built around sources ---
# The nav library builds tiles only near an "interest". Each active source with a nav_distance gets one here.


func _update_nav_interests() -> void:
	if not uses_nav():
		_remove_all_nav_interests()
		return
	var still_active := {}
	for node in get_tree().get_nodes_in_group(StreamingSource.GROUP):
		var source := node as StreamingSource
		if source == null or not source.counts_on_this_machine() or source.nav_distance <= 0.0:
			continue
		var id := source.get_instance_id()
		still_active[id] = true
		if _nav_interests.has(id):
			_nav.move_interest(_nav_interests[id], source.global_position)
		else:
			# There's no ground to build nav on past load_distance, so it can't ask for more than that.
			var load_radius := minf(source.nav_distance, source.load_distance)
			_nav_interests[id] = _nav.add_interest(source.global_position, load_radius, load_radius + unload_margin, 1)
	for id: int in _nav_interests.keys():
		if not still_active.has(id):
			_nav.remove_interest(_nav_interests[id])
			_nav_interests.erase(id)


func _remove_all_nav_interests() -> void:
	if _nav_interests.is_empty() or not Engine.has_singleton("NavServer"):
		return
	var nav: Object = Engine.get_singleton("NavServer")
	for id: int in _nav_interests:
		nav.remove_interest(_nav_interests[id])
	_nav_interests.clear()
