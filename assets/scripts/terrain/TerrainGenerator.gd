# Written by Claude (claude-opus-5-5), 2026-11-05. History: terrain/CHANGELOG.md.
## Generates ground in square chunks, with a low-poly look and no visible square grid.
##
## The look comes from [member noise_scale], [member grid_jitter], [member chunk_resolution] (squares along a chunk's side),
## [member chunk_size] (metres) and [member smooth_shading]. One list of triangles per chunk feeds the mesh, the collision and
## [signal chunk_built] (nav, through a [TerrainNavFeeder]), so what you see, stand on and what nav walks on are the same. Heights come
## from world positions, so chunks line up and every machine makes the same ground from the settings alone.
## [br]
## It knows nothing about nav building, networks or streaming, so it works with or without a [WorldCoordinator]. Optional children
## add to it: [TerrainEditLog] (edits outlast their chunks, reach clients, go into save files) and [TerrainBodyLifter]. To use it, add
## a Node3D, attach this script and press Play or Generate. For ground that loads around the player, see [ChunkStreamer].
## Design: world spec (docs/world/WORLD_SPEC.md).

# @tool: the terrain shows in the editor and the Generate button works there.
@tool
class_name TerrainGenerator
extends Node3D

## Sent once for each chunk whenever its collision is built or rebuilt.
signal collision_built(chunk: Vector2i, collision_node: CollisionShape3D)
## Sent when a chunk has just been removed, straight away, so anything on it knows before its next tick.
signal chunk_removed(chunk: Vector2i)
## Sent when an edit has just raised the ground. center is the middle of the patch in the world, seen from above, as X and Z.
## TerrainBodyLifter uses it, so moving bodies isn't this script's job.
signal ground_raised(center: Vector2, radius: float)
## Sent when a chunk has been built or rebuilt, with its triangles, measured from this node. TerrainNavFeeder uses it. While it goes
## out for an edit, [member edit_area] says which part changed.
signal chunk_built(chunk: Vector2i, triangles: PackedVector3Array)
## Sent when generate() or start_empty() begins, with the settings it's about to use already in place.
signal generation_started

## While [signal chunk_built] goes out for an edit, the part of the ground it changed, measured from this node: X and Z only (Y and
## height are 0). Empty when a chunk is built whole. TerrainNavFeeder passes it on, so nav rebuilds only the tiles the edit touched.
var edit_area := AABB()

# How far a point can move at full jitter, as a share of one grid square. Any further, and a triangle could flip inside
# out: its shortest height is about 0.7 of a square, and two of its corners can move toward each other.
const MAX_JITTER_REACH := 0.34
# No ground here: no real height is INF.
const NO_GROUND := INF

@export_group("Size")
## How many chunks to build around center_chunk. 0 builds one chunk, 1 builds 3×3, and 2 builds 5×5.
@export var chunk_radius := 1
## The chunk in the middle. With a radius of 0, this picks which one tile of a larger world to build.
## Chunks with different numbers line up exactly, because heights come from positions in the world.
@export var center_chunk := Vector2i.ZERO
## How wide one chunk is, in metres.
# The whole chunk, not one square, so chunk_resolution can change without changing how big the terrain is. Squares are about 6 m.
# 128 m because its worst single build step is about a third of a 256 m chunk's (stress test), which suits slower machines.
@export_range(1.0, 1000.0, 0.5, "or_greater") var chunk_size := 128.0
## How fine the grid is: the number of squares along each side of a chunk. Fewer squares look more low poly.
@export_range(1, 256, 1, "or_greater") var chunk_resolution := 21
## How far the noise moves up and down, in metres. Noise values are between about -1 and 1.
@export var height_scale := 12.0

@export_group("Grid look")
## How far grid points move at random, which hides the square grid. 0 is a perfect grid. 1 is as far as they can go
## without triangles flipping over.
@export_range(0.0, 1.0, 0.01) var grid_jitter := 0.8
## Off: every triangle is one flat colour, which is the low-poly look. On: lighting blends smoothly across triangles.
@export var smooth_shading := false

## Raise it when the ground changes in a way the settings don't show (a subclass changing _shape_height). It's part of
## ground_settings_hash, so old saved edits and other machines' ground are refused rather than applied to different ground.
@export var generator_version := 1

@export_group("Noise")
@export var noise_seed := 250
## Multiplies positions before reading the noise, with X and Z separate. Above 1 squeezes hills together, and below 1
## spreads them out. Different values for X and Z stretch hills in one direction. It doesn't move any grid points.
@export var noise_scale := Vector2.ONE
## The kind of noise.
# Godot's own enum as the type keeps the names matching its numbers. Same for fractal_type: its first entry means no fractal, not FBM.
@export var noise_type: FastNoiseLite.NoiseType = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
## How big the hills are. Lower values give wide, gentle hills, and higher values give small, frequent bumps.
@export_range(0.001, 0.5, 0.001) var frequency := 0.015
## How the layers of noise are combined. None uses one layer, so the three settings below do nothing.
@export var fractal_type: FastNoiseLite.FractalType = FastNoiseLite.FRACTAL_FBM
## How many layers of noise to stack. More layers add finer detail.
@export_range(1, 12, 1) var fractal_octaves := 3
## How strong each layer is compared with the one before. Higher is rougher.
@export_range(0.0, 2.0, 0.05) var fractal_gain := 0.5
## How much finer each layer is than the one before.
@export_range(0.0, 4.0, 0.1) var fractal_lacunarity := 2.0

@export_group("Looks")
## The material for the ground. Leave it empty for a plain brown one.
@export var material: Material
## How many times a texture repeats across each chunk.
@export var uv_scale := 1.0

@export_group("Collision")
## Makes the ground solid, so bodies can walk on it. It's skipped in the editor preview.
@export var build_collision := true

@export_group("Streaming")
## On: the terrain builds its chunk_radius block when it starts. Off: it starts empty, and something else asks for
## chunks, which is normally a ChunkStreamer. The editor preview always builds the block, so you can see the ground.
# ChunkStreamer needs it off; the WorldCoordinator turns it off when there's a streamer.
@export var build_on_start := true
## Off: no meshes are built, only collision, which saves time and memory on a machine nobody looks at.
## A build exported with Godot's dedicated_server feature never builds meshes, whatever this says.
# For servers, which build ground nobody looks at. A mesh was about 1.9 ms of the 6.5 ms a 256 m chunk cost.
@export var build_meshes := true

@export_group("")
## Rebuilds the terrain from the current settings. Any edits are lost, including ones in a TerrainEditLog.
@export_tool_button("Generate") var generate_button := generate

var _noise := FastNoiseLite.new()
var _points := {} # Vector2i -> PackedVector3Array, with (chunk_resolution + 1)^2 grid points, row by row, measured from this node
var _mesh_nodes := {} # Vector2i -> MeshInstance3D
var _collision_nodes := {} # Vector2i -> CollisionShape3D, each one inside its own StaticBody3D
var _plain_material := StandardMaterial3D.new() # used when the material setting is empty
var _has_generated := false
# The next three are for building chunks in steps (several at once, some held for their landing tick) and unloading them.
var _building := {} # Vector2i -> _ChunkBuild, the chunks that are partly built
var _edited_chunks := {} # Vector2i -> true, used only to warn when an unload is about to lose an edit
var _warned_about_lost_edits := false
# The two below are for TerrainEditLog, an optional module.
var _edit_log: TerrainEditLog = null
var _rebuild_queue: Array[Vector2i] = [] # chunks to rebuild, one per frame, because the log changed


## Everything a half-built chunk needs to remember between steps.
# So a chunk can be built over several frames, for slower machines.
class _ChunkBuild:
	var stage := Stage.POINTS
	var next_row := 0 # the next row to work on in the current stage
	var points := PackedVector3Array()
	var mesh := _MeshData.new()
	var triangles := PackedVector3Array()
	var next_edit := 0 # how far through this chunk's edits it has got
	var held := false # stops before publishing: its points, collision and chunk_built wait for its landing tick (ChunkStreamer)


## The lists a mesh is made from. Each index of the first three describes one vertex.
class _MeshData:
	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var uvs := PackedVector2Array()
	var indices := PackedInt32Array() # stays empty for flat shading, where no vertices are shared

	## Godot wants these in one Array, with each list at a set position.
	func as_arrays() -> Array:
		var arrays := []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = vertices
		arrays[Mesh.ARRAY_NORMAL] = normals
		arrays[Mesh.ARRAY_TEX_UV] = uvs
		if not indices.is_empty():
			arrays[Mesh.ARRAY_INDEX] = indices
		return arrays


# The order a chunk's build goes through, one stage at a time.
enum Stage { POINTS, EDITS, MESH_ROWS, MESH_NODE, COLLISION, ANNOUNCE }
# How much one build step does. Measured at about 0.4 ms on a fast desktop, so slower machines stay near
# their budget too. Collision can't be split, so it's the largest single step.
const POINTS_PER_STEP := 350
const SQUARES_PER_STEP := 700
const SMOOTH_POINTS_PER_STEP := 120
# Measured at about 24 microseconds an edit on a 128 m chunk.
const EDITS_PER_STEP := 20


## Every TerrainGenerator joins this Godot group, which is how other systems find them.
const GROUP := &"terrains"


# --- Godot calls these by itself ---


func _ready() -> void:
	set_process(false) # only runs while chunks are waiting to be rebuilt
	# A streamed terrain starts empty. The editor still builds the block, as a preview.
	if build_on_start or Engine.is_editor_hint():
		_build_block()
	else:
		start_empty()


# If this node is taken out of the scene and put back, _ready won't run again.
func _enter_tree() -> void:
	add_to_group(GROUP) # see GROUP
	if _has_generated:
		for key in _points:
			_rebuild_solid(key)


# A change to the edit log rebuilds chunks one a frame, so it doesn't stall a frame.
func _process(_delta: float) -> void:
	if _rebuild_queue.is_empty():
		set_process(false)
		return
	_rebuild_chunk_now(_rebuild_queue.pop_back())


# --- Things other scripts can call ---


## Builds the terrain from the current settings, replacing anything already built. Call this again after changing
## settings from code. It runs by itself once when the node enters the scene.
func generate() -> void:
	if _edit_log != null:
		_edit_log.clear() # as this function's description says
	_build_block()


func _build_block() -> void:
	_prepare()

	# All the points go first, because smooth lighting at a chunk's edge needs its neighbours' points.
	for z in range(center_chunk.y - chunk_radius, center_chunk.y + chunk_radius + 1):
		for x in range(center_chunk.x - chunk_radius, center_chunk.x + chunk_radius + 1):
			_generate_points(Vector2i(x, z))
	for key in _points:
		_rebuild_mesh(key)
		_rebuild_solid(key)
	_has_generated = true


## Clears everything and applies the current settings, leaving no chunks built. A terrain with build_on_start off does
## this by itself. After this, build_chunk_step and load_chunk add chunks.
# ChunkStreamer relies on it.
func start_empty() -> void:
	_prepare()
	_has_generated = true


## Which chunk a position in the world is over.
func chunk_of(world_position: Vector3) -> Vector2i:
	var local := world_position - _terrain_origin()
	return Vector2i(floori(local.x / chunk_size), floori(local.z / chunk_size))


## True once a chunk is completely built, including its collision. A chunk that's partly built doesn't count.
func has_chunk(key: Vector2i) -> bool:
	# Reads the points, because a chunk with build_meshes off has no mesh node.
	return _points.has(key) and not _building.has(key)


## True if every chunk within margin metres of this position is completely built. Quick, because AI checks it often:
## a position in the middle of a chunk only needs that one chunk.
# AIActivationManager uses it.
func has_ground_around(world_position: Vector3, margin: float) -> bool:
	var origin := _terrain_origin()
	var x := (world_position.x - origin.x) / chunk_size
	var z := (world_position.z - origin.z) / chunk_size
	var chunk_x := floori(x)
	var chunk_z := floori(z)
	if not has_chunk(Vector2i(chunk_x, chunk_z)):
		return false
	var reach := margin / chunk_size
	var low_x := floori(x - reach)
	var high_x := floori(x + reach)
	var low_z := floori(z - reach)
	var high_z := floori(z + reach)
	if low_x == chunk_x and high_x == chunk_x and low_z == chunk_z and high_z == chunk_z:
		return true
	for check_z in [low_z, high_z]:
		for check_x in [low_x, high_x]:
			if not has_chunk(Vector2i(check_x, check_z)):
				return false
	return true


## Every completely built chunk.
func get_loaded_chunks() -> Array[Vector2i]:
	var loaded: Array[Vector2i] = []
	for key: Vector2i in _points:
		if not _building.has(key):
			loaded.append(key)
	return loaded


## Does one small piece of building a chunk, and returns true once it's finished; call again with the same chunk to continue.
## ChunkStreamer uses it to spread a chunk over frames; several can be partly built at once. The result matches generate()'s.
## [br]With hold, it stops just before publishing (the chunk's points, which height_at reads, its collision and [signal chunk_built])
## and returns true once it's ready to publish; the chunk lands later, on its landing tick, through [method load_chunk] (state store
## spec 13.12). Its mesh is only a picture, so it may show before.
# So slower machines don't stall while a chunk loads. See POINTS_PER_STEP above.
func build_chunk_step(key: Vector2i, hold := false) -> bool:
	if has_chunk(key):
		return true
	if not _has_generated:
		start_empty()
	var build: _ChunkBuild = _building.get(key)
	if build == null:
		build = _ChunkBuild.new()
		build.points.resize(_points_per_edge() * _points_per_edge())
		_building[key] = build
	build.held = hold # a call without hold publishes it, however it was started

	match build.stage:
		Stage.POINTS:
			@warning_ignore("integer_division") # whole numbers on purpose
			var rows := maxi(1, POINTS_PER_STEP / _points_per_edge())
			var end_row := mini(build.next_row + rows, _points_per_edge())
			_fill_point_rows(build.points, key, build.next_row, end_row)
			build.next_row = end_row
			if end_row == _points_per_edge():
				build.next_row = 0
				build.stage = Stage.EDITS
		Stage.EDITS:
			# A much-dug chunk can have a long list, so this is split up too.
			if _edit_log != null and build.next_edit < _edit_log.get_chunk_edit_count(key):
				build.next_edit = _edit_log.apply_some_to_chunk(key, build.points, build.next_edit, EDITS_PER_STEP)
				return false
			# The points are only made public once they're complete, so height_at never reads half a chunk; a held chunk's wait
			# for its landing tick.
			if not build.held:
				_points[key] = build.points
			if _wants_meshes():
				_start_mesh_data(build.mesh)
				build.stage = Stage.MESH_ROWS
			else:
				build.stage = Stage.COLLISION
		Stage.MESH_ROWS:
			var end_row := mini(build.next_row + _mesh_rows_per_step(), _mesh_row_count())
			_fill_mesh_rows(build.mesh, key, build.next_row, end_row, build.points)
			build.next_row = end_row
			if end_row == _mesh_row_count():
				build.stage = Stage.MESH_NODE
		Stage.MESH_NODE:
			_set_chunk_mesh(key, build.mesh.as_arrays())
			build.stage = Stage.COLLISION
		Stage.COLLISION:
			build.triangles = _chunk_triangles(key, build.points)
			if build_collision and not Engine.is_editor_hint():
				# Built now, the slow part, but switched off until it's published.
				_rebuild_collision(key, build.triangles, not build.held)
			build.stage = Stage.ANNOUNCE
		Stage.ANNOUNCE:
			if build.held:
				return true # ready, waiting for its landing tick
			_publish(key, build)
			return true
	return false


## Builds a chunk completely, right now, and publishes it; a held chunk ([method build_chunk_step]) is finished and published. Simple,
## but building takes several milliseconds, so it can show up as a stutter.
func load_chunk(key: Vector2i) -> void:
	while not build_chunk_step(key):
		pass


## True if a held chunk is built up to publishing, waiting for its landing tick.
func is_chunk_ready_to_publish(key: Vector2i) -> bool:
	var build: _ChunkBuild = _building.get(key)
	return build != null and build.held and build.stage == Stage.ANNOUNCE


# Makes a finished chunk part of play: its points (height_at), its collision, and chunk_built (nav, markers).
func _publish(key: Vector2i, build: _ChunkBuild) -> void:
	if not _points.has(key) and _edit_log != null and build.next_edit < _edit_log.get_chunk_edit_count(key):
		# Dug while it waited for its landing tick (edits only reach published chunks): it catches up, and lands as edited.
		build.next_edit = _edit_log.apply_some_to_chunk(key, build.points, build.next_edit, _edit_log.get_chunk_edit_count(key))
		_points[key] = build.points
		_building.erase(key)
		_rebuild_mesh(key)
		_rebuild_solid(key) # its collision, switched on, and chunk_built
		return
	if not _points.has(key):
		_points[key] = build.points
	var held_body: Node = _collision_nodes[key].get_parent() if _collision_nodes.has(key) else null
	if held_body and held_body.get_parent() == null:
		_add_collision_to_scene(key)
	_building.erase(key)
	chunk_built.emit(key, build.triangles)


## Removes a chunk: its mesh and collision, or what's built of them. [signal chunk_removed] goes out, so its nav data and markers go too.
## With no TerrainEditLog its edits are lost, and it warns the first time.
func unload_chunk(key: Vector2i) -> void:
	if _edit_log == null and _edited_chunks.has(key) and not _warned_about_lost_edits:
		_warned_about_lost_edits = true
		push_warning("Terrain: unloading a chunk that was edited, so its edits are lost. Add a TerrainEditLog child to keep them. Shown once.")
	_forget_chunk(key)


## A built chunk's triangles, measured from this node, for something that arrives after the chunk was built.
func get_chunk_triangles(key: Vector2i) -> PackedVector3Array:
	return _chunk_triangles(key) if _points.has(key) else PackedVector3Array()


## A chunk's markers, placed in the world. See _make_chunk_markers. TerrainNavFeeder announces them.
func get_chunk_markers(key: Vector2i) -> Array[NavMarker]:
	var markers := _make_chunk_markers(key)
	var origin := _terrain_origin()
	for marker in markers:
		if marker != null: # NavMarkerManager refuses a null one and warns, so it's left in the list for that
			marker.position += origin
	return markers


## The ground's height at a position in the world, read from the same triangles as the mesh, collision and nav.
## Where there's no ground, it returns this node's own height. It follows this node if it's moved, but not if it's
## rotated or scaled.
func height_at(world_x: float, world_z: float) -> float:
	var height := _ground_at(world_x, world_z)
	return _terrain_origin().y if height == NO_GROUND else height


## Finds where a ray meets the ground, without using physics, so it works with collision off. Returns the point as a
## Vector3, or null if the ray doesn't hit within max_distance.
func raycast(origin: Vector3, direction: Vector3, max_distance := 600.0) -> Variant:
	# Walk along the ray in short steps until we end up under the ground.
	var step := _square_size() * 0.25
	var previous := origin
	var travelled := 0.0
	while travelled < max_distance:
		travelled += step
		var point := origin + direction * travelled
		if _is_under_ground(point):
			# The hit is between the last two points. Keep halving that gap to narrow it down.
			var above := previous
			var below := point
			for i in 12:
				var middle := (above + below) * 0.5
				if _is_under_ground(middle):
					below = middle
				else:
					above = middle
			return below
		previous = point
	return null


## Raises (amount above 0) or digs (below 0) a round patch centred on a world position, and rebuilds only the chunks it touched: the
## middle moves by the full amount and the outer half of the radius fades out.
## Add a TerrainEditLog so it outlasts its chunk and, in multiplayer, reaches clients; without one it's gone when the chunk unloads
## and machines end up on different ground.
# The network rule is in TerrainEditLog, so this script doesn't need to know about networks.
func edit(center: Vector3, radius: float, amount: float) -> void:
	if radius <= 0.0 or (_edit_log != null and _edit_log.refuses_edit()):
		return
	# A half-built chunk would finish with a mesh made from the heights before this edit, so finish them first (a stutter only if an
	# edit lands while a chunk loads).
	finish_building_chunks() # a helper, which the client's path uses too
	var local_center := center - _terrain_origin()
	# Rounded to 32 bits first, the same as what the log stores, so that every machine gets identical ground.
	var rounded := PackedFloat32Array([local_center.x, local_center.z, radius, amount])
	if _edit_log != null:
		_edit_log.record(rounded[0], rounded[1], rounded[2], rounded[3])
	_apply_edit_to_loaded_chunks(rounded[0], rounded[1], rounded[2], rounded[3])


## An edit from the server has reached this client, and the log has it already.
# TerrainEditLog finishes half-built chunks BEFORE it records the edit. Finishing them here, after recording, would make them read
# the edit from the log and get it again below: the ground would rise twice. No underscore, because TerrainEditLog calls it.
func apply_edit_from_log(x: float, z: float, radius: float, amount: float) -> void:
	_apply_edit_to_loaded_chunks(x, z, radius, amount)


## Finishes every half-built chunk right now, before an edit is recorded: a chunk either finished first and gets the edit from the
## loaded-chunk pass, or starts later and reads it from the log. Never both. Held chunks are left to land on their tick (see below).
# No underscore, because another class (TerrainEditLog) calls it.
func finish_building_chunks() -> void:
	for key: Vector2i in _building.keys():
		_finish_unless_held(key)


# A held chunk waits for its landing tick: its points aren't public, so the loaded-chunk pass never touches it, and it reads the edit
# from the log while building or catches up when it lands (_publish). Finishing it here would publish it before its tick, at a moment
# that depends on how far this machine had got with it.
func _finish_unless_held(key: Vector2i) -> void:
	var build: _ChunkBuild = _building.get(key)
	if build == null or not build.held:
		load_chunk(key)


## Changes the heights of the chunks that are built, and rebuilds them. The log isn't touched here.
func _apply_edit_to_loaded_chunks(x: float, z: float, radius: float, amount: float) -> void:
	# See edit_area. Points move within radius; the triangles using them reach one square further.
	var reach := radius + _square_size()
	edit_area = AABB(Vector3(x - reach, 0.0, z - reach), Vector3(reach * 2.0, 0.0, reach * 2.0))
	var flat_center := Vector2(x, z)
	# The patch, plus two squares: enough to reach any chunk whose smooth lighting reads a point that moved.
	var margin := radius + 2.0 * _square_size()
	var nearby_chunks: Array[Vector2i] = []
	var changed_chunks: Array[Vector2i] = []

	# First, change every height.
	for key: Vector2i in _points.keys():
		# Skip this chunk if the patch can't reach it. Checking is much cheaper than visiting every point.
		var chunk_start := Vector2(key.x * chunk_size, key.y * chunk_size)
		if flat_center.x + margin < chunk_start.x or flat_center.x - margin > chunk_start.x + chunk_size:
			continue
		if flat_center.y + margin < chunk_start.y or flat_center.y - margin > chunk_start.y + chunk_size:
			continue
		nearby_chunks.append(key)

		var points: PackedVector3Array = _points[key]
		var touched := apply_edit_to_points(points, x, z, radius, amount)
		if touched:
			_points[key] = points # store it back, so there's no doubt the Dictionary has the changed points
			changed_chunks.append(key)
			_edited_chunks[key] = true # so unloading it can warn that the edit is lost

	# Then rebuild. A chunk next to the patch can need new smooth lighting even when none of its own points moved.
	# Collision and nav only care about its own points.
	for key in nearby_chunks:
		_rebuild_mesh(key)
	for key in changed_chunks:
		_rebuild_solid(key)
	edit_area = AABB() # the edit's chunk_built signals have gone out
	if amount > 0.0:
		var origin := _terrain_origin()
		ground_raised.emit(Vector2(flat_center.x + origin.x, flat_center.y + origin.z), radius)


## Adds one edit to a list of grid points, and returns true if any of them moved. Its position is measured from the terrain.
## The chunk's own edit and a chunk built later both come through here, which is what makes them match.
static func apply_edit_to_points(points: PackedVector3Array, x: float, z: float, radius: float, amount: float) -> bool:
	var flat_center := Vector2(x, z)
	var touched := false
	for i in points.size():
		var distance := Vector2(points[i].x, points[i].z).distance_to(flat_center)
		if distance < radius:
			points[i].y += amount * (1.0 - smoothstep(radius * 0.5, radius, distance))
			touched = true
	return touched


## Every chunk an edit could touch, built or not. A grid point can sit up to a square outside its chunk's plain edges.
func chunks_touched_by_edit(x: float, z: float, radius: float) -> Array[Vector2i]:
	var reach := radius + _square_size()
	var touched: Array[Vector2i] = []
	for chunk_z in range(floori((z - reach) / chunk_size), floori((z + reach) / chunk_size) + 1):
		for chunk_x in range(floori((x - reach) / chunk_size), floori((x + reach) / chunk_size) + 1):
			touched.append(Vector2i(chunk_x, chunk_z))
	return touched


## A number that changes if the settings that decide the ground change; TerrainEditLog uses it to refuse edits made for different
## ground. [member generator_version] is part of it, since a subclass's _shape_height changes the ground without changing a setting.
func ground_settings_hash() -> int:
	return hash([chunk_size, chunk_resolution, height_scale, grid_jitter, noise_seed, noise_scale, int(noise_type), frequency, int(fractal_type), fractal_octaves, fractal_gain, fractal_lacunarity, generator_version])


# --- For scripts that extend this one ---


## Change this to shape the ground beyond the noise, such as a flat plaza or a wall. Copy tests/terrain_test_course.gd
## to see how. noise_height is the height so far, and the position is measured from this node.
# A subclass needs @tool for its shapes to show in the editor preview.
func _shape_height(_x: float, _z: float, noise_height: float) -> float:
	return noise_height


## Override to give a chunk its links and points of interest (copy tests/terrain_marker_example.gd). A TerrainNavFeeder announces them
## when the chunk is built and after an edit, and releases them when it's gone. Return new markers each call, positioned from this
## node, built from the chunk's numbers (not random ones), with tags declared in resources/tag_declarations.tres.
# The nav spec's section 21.6. The generator knows its own terrain, so it says what's there.
func _make_chunk_markers(_key: Vector2i) -> Array[NavMarker]:
	return []


# --- The edit log module ---
# Everything the terrain does about edits outlasting their chunks goes through here, and stops if the
# module isn't there.


# No underscore, because another class (TerrainEditLog) calls it.
func edit_log_arrived(log_module: TerrainEditLog) -> void:
	_edit_log = log_module


# No underscore, because another class (TerrainEditLog) calls it.
func edit_log_left(log_module: TerrainEditLog) -> void:
	if _edit_log == log_module:
		_edit_log = null
		# Deferred, so that this can tell the module being deleted apart from the whole terrain leaving the scene.
		_return_to_default_ground.call_deferred()


## The module is gone, so anything it put on the ground goes too. Chunks with no edits don't change.
func _return_to_default_ground() -> void:
	if _edit_log != null or not is_inside_tree():
		return
	rebuild_chunks_for_log(_edited_chunks.keys())
	_edited_chunks.clear()


## Queues the built ones among these chunks to be rebuilt from scratch, with whatever the log now says.
# No underscore, because another class (TerrainEditLog) calls it.
func rebuild_chunks_for_log(chunks: Array) -> void:
	for key: Vector2i in _building.keys():
		_finish_unless_held(key) # so a half-built chunk can't finish with what it read before
	for key: Vector2i in chunks:
		if has_chunk(key) and not _rebuild_queue.has(key):
			_rebuild_queue.append(key)
	if not _rebuild_queue.is_empty():
		set_process(true)


func _rebuild_chunk_now(key: Vector2i) -> void:
	if not has_chunk(key):
		return
	_generate_points(key)
	_rebuild_mesh(key)
	_rebuild_solid(key)
	if smooth_shading:
		for neighbour: Vector2i in [key + Vector2i.LEFT, key + Vector2i.RIGHT, key + Vector2i.UP, key + Vector2i.DOWN]:
			if has_chunk(neighbour):
				_rebuild_mesh(neighbour)


## Finishes any rebuilds still waiting, for a test or a loading screen.
func finish_rebuilds() -> void:
	while not _rebuild_queue.is_empty():
		_rebuild_chunk_now(_rebuild_queue.pop_back())


# --- Building: the grid points ---


func _generate_points(key: Vector2i) -> void:
	var n := _points_per_edge()
	var points := PackedVector3Array()
	points.resize(n * n) # sized up front, because that's quicker than growing it one item at a time
	_fill_point_rows(points, key, 0, n)
	if _edit_log != null:
		_edit_log.apply_to_chunk(key, points)
	_points[key] = points


## Works out some rows of a chunk's grid points, so a build can stop between rows.
func _fill_point_rows(points: PackedVector3Array, key: Vector2i, from_row: int, to_row: int) -> void:
	var n := _points_per_edge()
	for z in range(from_row, to_row):
		for x in n:
			# Points are numbered across the whole world, not within the chunk. The last point of one chunk has the same number as the
			# first of the next, so both get the same position and height: that's what makes the terrain seamless.
			points[x + z * n] = _make_point(key.x * chunk_resolution + x, key.y * chunk_resolution + z)


## Where a grid point is, and how high, from its number across the whole world.
func _make_point(world_x_number: int, world_z_number: int) -> Vector3:
	var x := world_x_number * _square_size()
	var z := world_z_number * _square_size()
	if grid_jitter > 0.0:
		# hash() gives the same big number for the same input on every machine, so the terrain agrees with no random numbers to
		# keep in step.
		var random := hash(Vector3i(world_x_number, world_z_number, noise_seed))
		# Split it into two numbers from 0 to 1.
		var random_1 := (random & 0xFFFF) / 65535.0
		var random_2 := ((random >> 16) & 0xFFFF) / 65535.0
		# A direction, and a distance inside a circle; the square root spreads points evenly over it.
		var direction := random_1 * TAU # TAU is a full circle in radians
		var reach := sqrt(random_2) * grid_jitter * MAX_JITTER_REACH * _square_size()
		x += cos(direction) * reach
		z += sin(direction) * reach
	return Vector3(x, _height_from_noise(x, z), z)


func _height_from_noise(x: float, z: float) -> float:
	var noise_height := _noise.get_noise_2d(x * noise_scale.x, z * noise_scale.y) * height_scale
	return _shape_height(x, z, noise_height)


func _apply_noise_settings() -> void:
	_noise.seed = noise_seed
	_noise.noise_type = noise_type
	_noise.frequency = frequency
	_noise.fractal_type = fractal_type
	_noise.fractal_octaves = fractal_octaves
	_noise.fractal_gain = fractal_gain
	_noise.fractal_lacunarity = fractal_lacunarity


## Every triangle in a chunk, three corners each; a square is a-b-c and b-d-c, clockwise so they face up.
# a --- b
# |  /  |
# c --- d
func _chunk_triangles(key: Vector2i, own_points := PackedVector3Array()) -> PackedVector3Array:
	var points: PackedVector3Array = own_points if not own_points.is_empty() else _points[key]
	var n := _points_per_edge()
	var triangles := PackedVector3Array()
	triangles.resize(chunk_resolution * chunk_resolution * 6)
	var next := 0
	for z in chunk_resolution:
		for x in chunk_resolution:
			var a := points[x + z * n]
			var b := points[x + 1 + z * n]
			var c := points[x + (z + 1) * n]
			var d := points[x + 1 + (z + 1) * n]
			triangles[next] = a
			triangles[next + 1] = b
			triangles[next + 2] = c
			triangles[next + 3] = b
			triangles[next + 4] = d
			triangles[next + 5] = c
			next += 6
	return triangles


# --- Building: what you see ---


func _rebuild_mesh(key: Vector2i) -> void:
	if _wants_meshes():
		_set_chunk_mesh(key, _make_mesh_arrays(key))


## Whether this machine should build meshes. The editor preview always does, or there'd be nothing to see.
func _wants_meshes() -> bool:
	if Engine.is_editor_hint():
		return true
	return build_meshes and not OS.has_feature("dedicated_server")


## Puts a finished mesh on the chunk's node, making the node if the chunk doesn't have one yet.
func _set_chunk_mesh(key: Vector2i, arrays: Array) -> void:
	var mesh_node: MeshInstance3D = _mesh_nodes.get(key)
	if mesh_node == null:
		mesh_node = MeshInstance3D.new()
		# These nodes have no "owner", so Godot doesn't save them in the scene file. The terrain is rebuilt on load.
		add_child(mesh_node)
		_mesh_nodes[key] = mesh_node
	mesh_node.material_override = material if material else _plain_material
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh_node.mesh = mesh


## Sets up a chunk's triangles, UVs and normals (the direction a surface faces, which lighting uses). Separate from _rebuild_mesh so
## the test can read the result without a mesh.
# Flat: each triangle has its own three vertices and one normal. Smooth: triangles share a vertex per corner, with a normal blended
# from every triangle touching it.
# Normals are worked out here, not by SurfaceTool.generate_normals(): that sees one chunk, so the two sides of a border would light
# differently and show a faint line. Filling arrays directly also skips SurfaceTool's script calls per vertex (5.6 of a 256 m chunk's 10.7 ms).
func _make_mesh_arrays(key: Vector2i) -> Array:
	var data := _MeshData.new()
	_start_mesh_data(data)
	_fill_mesh_rows(data, key, 0, _mesh_row_count())
	return data.as_arrays()


## Sizes the lists up front, which is quicker than growing them one item at a time. Each row then fills its own part.
func _start_mesh_data(data: _MeshData) -> void:
	var vertex_count := _points_per_edge() * _points_per_edge() if smooth_shading else chunk_resolution * chunk_resolution * 6
	data.vertices.resize(vertex_count)
	data.normals.resize(vertex_count)
	data.uvs.resize(vertex_count)
	if smooth_shading:
		data.indices.resize(chunk_resolution * chunk_resolution * 6)


## How many rows _fill_mesh_rows works through for a whole chunk. Smooth shading has one vertex row more than squares.
func _mesh_row_count() -> int:
	return _points_per_edge() if smooth_shading else chunk_resolution


func _mesh_rows_per_step() -> int:
	if smooth_shading:
		@warning_ignore("integer_division") # whole numbers on purpose
		return maxi(1, SMOOTH_POINTS_PER_STEP / _points_per_edge())
	@warning_ignore("integer_division") # whole numbers on purpose
	return maxi(1, SQUARES_PER_STEP / chunk_resolution)


# own_points: the chunk's points while it isn't published yet; empty reads the published ones.
func _fill_mesh_rows(data: _MeshData, key: Vector2i, from_row: int, to_row: int, own_points := PackedVector3Array()) -> void:
	if smooth_shading:
		_fill_smooth_rows(data, key, from_row, to_row, own_points)
	else:
		_fill_flat_rows(data, key, from_row, to_row, own_points)


func _fill_flat_rows(data: _MeshData, key: Vector2i, from_row: int, to_row: int, own_points := PackedVector3Array()) -> void:
	# Packed arrays are shared, not copied, when assigned like this, so writing to these locals fills the lists in data (and is quicker).
	var vertices := data.vertices
	var normals := data.normals
	var uvs := data.uvs
	var points: PackedVector3Array = own_points if not own_points.is_empty() else _points[key]
	var n := _points_per_edge()
	var start_x := key.x * chunk_size
	var start_z := key.y * chunk_size
	for z in range(from_row, to_row):
		var next := z * chunk_resolution * 6
		for x in chunk_resolution:
			# The same a-b-c and b-d-c split as _chunk_triangles.
			var a := points[x + z * n]
			var b := points[x + 1 + z * n]
			var c := points[x + (z + 1) * n]
			var d := points[x + 1 + (z + 1) * n]
			# The order of the two matters: this way round points up.
			var normal_1 := (c - a).cross(b - a).normalized()
			var normal_2 := (c - b).cross(d - b).normalized()
			# The same sum as _uv_of, written out here because this loop runs thousands of times per chunk.
			var uv_a := Vector2(a.x - start_x, a.z - start_z) / chunk_size * uv_scale
			var uv_b := Vector2(b.x - start_x, b.z - start_z) / chunk_size * uv_scale
			var uv_c := Vector2(c.x - start_x, c.z - start_z) / chunk_size * uv_scale
			var uv_d := Vector2(d.x - start_x, d.z - start_z) / chunk_size * uv_scale
			vertices[next] = a
			vertices[next + 1] = b
			vertices[next + 2] = c
			vertices[next + 3] = b
			vertices[next + 4] = d
			vertices[next + 5] = c
			normals[next] = normal_1
			normals[next + 1] = normal_1
			normals[next + 2] = normal_1
			normals[next + 3] = normal_2
			normals[next + 4] = normal_2
			normals[next + 5] = normal_2
			uvs[next] = uv_a
			uvs[next + 1] = uv_b
			uvs[next + 2] = uv_c
			uvs[next + 3] = uv_b
			uvs[next + 4] = uv_d
			uvs[next + 5] = uv_c
			next += 6


func _fill_smooth_rows(data: _MeshData, key: Vector2i, from_row: int, to_row: int, own_points := PackedVector3Array()) -> void:
	var vertices := data.vertices
	var normals := data.normals
	var uvs := data.uvs
	var indices := data.indices
	var points: PackedVector3Array = own_points if not own_points.is_empty() else _points[key]
	var n := _points_per_edge()
	for z in range(from_row, to_row):
		for x in n:
			var i := x + z * n
			normals[i] = _smooth_normal(key.x * chunk_resolution + x, key.y * chunk_resolution + z)
			uvs[i] = _uv_of(key, points[i])
			vertices[i] = points[i]
		# With shared vertices a triangle is three vertex numbers: the same a-b-c and b-d-c split as _chunk_triangles. The last row has no squares below it.
		if z < chunk_resolution:
			var next := z * chunk_resolution * 6
			for x in chunk_resolution:
				var a := x + z * n
				var b := a + 1
				var c := a + n
				var d := c + 1
				indices[next] = a
				indices[next + 1] = b
				indices[next + 2] = c
				indices[next + 3] = b
				indices[next + 4] = d
				indices[next + 5] = c
				next += 6


## The blended normal at a grid point: the average of the six triangles that touch it. Bigger triangles count for more.
## Both chunks at a border read the same points, so their normals match, and no line shows there.
func _smooth_normal(world_x_number: int, world_z_number: int) -> Vector3:
	var center := _point_at(world_x_number, world_z_number)
	# The six neighbours that share a triangle with this point, going around it in order. Only two of the four diagonal
	# neighbours are included, because every square's diagonal runs the same way.
	var around := [
		_point_at(world_x_number + 1, world_z_number),
		_point_at(world_x_number, world_z_number + 1),
		_point_at(world_x_number - 1, world_z_number + 1),
		_point_at(world_x_number - 1, world_z_number),
		_point_at(world_x_number, world_z_number - 1),
		_point_at(world_x_number + 1, world_z_number - 1),
	]
	var total := Vector3.ZERO
	for i in around.size():
		var this_one: Vector3 = around[i]
		var next_one: Vector3 = around[(i + 1) % around.size()]
		# A cross product's length is twice the triangle's area, so adding them up gives bigger triangles more say.
		total += (next_one - center).cross(this_one - center)
	return total.normalized()


# --- Building: what you stand on ---


## Makes a chunk's collision, and announces its triangles, so that collision and anything listening can't disagree.
func _rebuild_solid(key: Vector2i) -> void:
	var triangles := _chunk_triangles(key)
	if build_collision and not Engine.is_editor_hint():
		_rebuild_collision(key, triangles)
	chunk_built.emit(key, triangles)


# live off: built but kept out of the scene, for a held chunk, until it's published (_add_collision_to_scene). Out of the scene rather
# than switched off, because whatever follows the scene's bodies (physics, SightGeometryFeeder) then sees it arrive.
func _rebuild_collision(key: Vector2i, triangles: PackedVector3Array, live := true) -> void:
	var collision_node: CollisionShape3D = _collision_nodes.get(key)
	if collision_node == null:
		# Godot's physics needs a body, with a collision shape inside it. A static body is one that never moves.
		collision_node = CollisionShape3D.new()
		collision_node.shape = ConcavePolygonShape3D.new()
		var body := StaticBody3D.new()
		body.add_child(collision_node)
		_collision_nodes[key] = collision_node
	(collision_node.shape as ConcavePolygonShape3D).set_faces(triangles)
	if live:
		_add_collision_to_scene(key)


# Puts a chunk's collision body in the scene, if it isn't, and announces it.
func _add_collision_to_scene(key: Vector2i) -> void:
	var collision_node: CollisionShape3D = _collision_nodes.get(key)
	if collision_node == null:
		return
	var body := collision_node.get_parent()
	if body.get_parent() == null:
		add_child(body)
	collision_built.emit(key, collision_node)


# --- Reading the ground ---


func _is_under_ground(point: Vector3) -> bool:
	var height := _ground_at(point.x, point.z)
	return height != NO_GROUND and point.y <= height


## The ground's height at a position in the world, or NO_GROUND if nothing is built there.
func _ground_at(world_x: float, world_z: float) -> float:
	var origin := _terrain_origin()
	var x := world_x - origin.x
	var z := world_z - origin.z
	# Which square would this be in with no jitter? Jitter moves corners by less than half a square, so the triangle
	# we want is in that square or one touching it. The middle one comes first, as it's the most likely.
	var square_x := floori(x / _square_size())
	var square_z := floori(z / _square_size())
	for offset_z in [0, -1, 1]:
		for offset_x in [0, -1, 1]:
			var height := _height_in_square(square_x + offset_x, square_z + offset_z, x, z)
			if height != NO_GROUND:
				return origin.y + height
	return NO_GROUND


func _height_in_square(square_x: int, square_z: int, x: float, z: float) -> float:
	var key := Vector2i(floori(float(square_x) / chunk_resolution), floori(float(square_z) / chunk_resolution))
	if not _points.has(key):
		return NO_GROUND
	var points: PackedVector3Array = _points[key]
	var n := _points_per_edge()
	# posmod is a remainder that stays positive for negative numbers, which gives the square's number within its chunk.
	var local_x := posmod(square_x, chunk_resolution)
	var local_z := posmod(square_z, chunk_resolution)
	var a := points[local_x + local_z * n]
	var b := points[local_x + 1 + local_z * n]
	var c := points[local_x + (local_z + 1) * n]
	var d := points[local_x + 1 + (local_z + 1) * n]
	var height := _height_in_triangle(a, b, c, x, z)
	if height == NO_GROUND:
		height = _height_in_triangle(b, d, c, x, z)
	return height


## The height of a triangle at x, z, or NO_GROUND if x, z is outside it when seen from above.
func _height_in_triangle(a: Vector3, b: Vector3, c: Vector3, x: float, z: float) -> float:
	# Describe the position as "start at a, go some share of the way to b, and some share of the way to c".
	var to_b := Vector2(b.x - a.x, b.z - a.z)
	var to_c := Vector2(c.x - a.x, c.z - a.z)
	var to_point := Vector2(x - a.x, z - a.z)
	var area := to_b.cross(to_c)
	if is_zero_approx(area):
		return NO_GROUND
	var share_b := to_point.cross(to_c) / area
	var share_c := to_b.cross(to_point) / area
	# Inside the triangle, both shares are at least 0 and they add up to at most 1. The small allowance stops rounding
	# from opening a crack exactly along an edge.
	const ALLOWANCE := 0.000001
	if share_b < -ALLOWANCE or share_c < -ALLOWANCE or share_b + share_c > 1.0 + ALLOWANCE:
		return NO_GROUND
	return a.y + (b.y - a.y) * share_b + (c.y - a.y) * share_c


# --- Small helpers ---


## Settings, noise and connections, shared by generate() and start_empty().
func _prepare() -> void:
	_clear()
	_fix_bad_settings()
	_apply_noise_settings()
	_plain_material.albedo_color = Color(0.46, 0.43, 0.37)
	_plain_material.roughness = 1.0
	generation_started.emit()


func _clear() -> void:
	for key: Vector2i in _points.keys():
		_forget_chunk(key)
	_building.clear() # any left have no points yet, so nothing else has been made for them
	_edited_chunks.clear()


## Removes whatever exists of one chunk.
# Shared by _clear and unload_chunk, so one chunk can go on its own.
func _forget_chunk(key: Vector2i) -> void:
	_building.erase(key)
	if _mesh_nodes.has(key):
		var mesh_node: MeshInstance3D = _mesh_nodes[key]
		remove_child(mesh_node)
		mesh_node.queue_free() # queue_free deletes a node safely at the end of the frame
		_mesh_nodes.erase(key)
	if _collision_nodes.has(key):
		var body: Node = _collision_nodes[key].get_parent()
		if body.get_parent() == self:
			remove_child(body)
		body.queue_free()
		_collision_nodes.erase(key)
	_points.erase(key)
	_edited_chunks.erase(key)
	chunk_removed.emit(key)


# The sliders stop bad values in the inspector, but code can still set them. Carry on with something sensible rather
# than crashing or dividing by zero.
func _fix_bad_settings() -> void:
	if chunk_resolution < 1:
		push_warning("Terrain: chunk_resolution must be at least 1. Using 1.")
		chunk_resolution = 1
	if chunk_size <= 0.0:
		push_warning("Terrain: chunk_size must be above 0. Using 1.")
		chunk_size = 1.0
	if chunk_radius < 0:
		push_warning("Terrain: chunk_radius can't be negative. Using 0.")
		chunk_radius = 0
	if grid_jitter < 0.0 or grid_jitter > 1.0:
		push_warning("Terrain: grid_jitter must be from 0 to 1. Using the nearest allowed value.")
		grid_jitter = clampf(grid_jitter, 0.0, 1.0)


func _points_per_edge() -> int:
	return chunk_resolution + 1


func _square_size() -> float:
	return chunk_size / chunk_resolution


## A grid point from its number across the whole world. If that chunk isn't built, this works out where the point would
## be, so the outer edge of the terrain and a single tile are lit like part of a larger world.
func _point_at(world_x_number: int, world_z_number: int) -> Vector3:
	var key := Vector2i(floori(float(world_x_number) / chunk_resolution), floori(float(world_z_number) / chunk_resolution))
	if not _points.has(key):
		var point := _make_point(world_x_number, world_z_number)
		# A neighbour that isn't built still has its edits, so lighting at the border matches.
		return _edit_log.apply_to_point(key, point) if _edit_log != null else point
	var index := posmod(world_x_number, chunk_resolution) + posmod(world_z_number, chunk_resolution) * _points_per_edge()
	return _points[key][index]


## UVs come from the position within the chunk, so a texture lines up across borders even when points are shifted.
func _uv_of(key: Vector2i, point: Vector3) -> Vector2:
	return Vector2(point.x - key.x * chunk_size, point.z - key.y * chunk_size) / chunk_size * uv_scale


# Asking for a global position outside the scene is an error, so treat that case as the world origin.
func _terrain_origin() -> Vector3:
	return global_position if is_inside_tree() else Vector3.ZERO
