## Written by Claude (claude-opus-5-5), 2026-11-05: one terrain generator with the features of procgen_tile.gd and
## nav_test_terrain.gd, built alongside them. Both originals stay as they are.
##
## The look it goes for is low poly without a visible square grid. The four settings that shape that are noise_scale,
## grid_jitter, chunk_resolution (how fine the grid is) and chunk_size (how big a chunk is in metres), plus smooth_shading.
##
## From procgen_tile.gd: the noise settings, UVs, a Generate button in the editor, and a signal when collision is ready.
## From nav_test_terrain.gd: seamless chunks, height_at(), raycast(), live edit(), and feeding the nav system.
##
## How it holds together: _chunk_triangles() makes one list of triangles for each chunk. The flat-shaded mesh, the
## collision and the nav system all use that list, so what you see, what you stand on and what nav walks on are the same.
##
## Claude 2026-11-07: renamed from HeightmapTerrain, because this is becoming the coordinator for a terrain's chunks and
## modules, and other ways of making ground could join later. tile_size became chunk_size and grid_size chunk_resolution,
## because "tile" means nav's 12.8 m tiles everywhere else.
##
## How to use it: add a Node3D to a scene, attach this script, and press Play or the Generate button in the inspector.
## To see it working, open terrain_sample.tscn. The test is tests/terrain_selftest.tscn.
## For a world that loads around the player instead of one fixed block, see ChunkStreamer and streaming_sample.tscn.
##
## Claude 2026-11-07: it knows nothing about nav, networks or streaming. It says when a chunk is built or removed, and a WorldNavLink, if
## there is one, feeds nav from that. So it stands alone, and works with or without a WorldCoordinator. See docs/world/WORLD_SPEC.md.
##
## How to read this file, if you're getting back into GDScript: "GDScript note:" comments explain a language feature
## the first time it comes up. The other comments explain what this terrain does and why.
##
## GDScript note: a comment starting with ## is a documentation comment. Above a class, function or variable, it shows
## up in the editor's help, and above an @export it becomes the tooltip in the inspector. A # comment is just a note.

# GDScript note: @tool makes this script run inside the editor as well as in the game. That's what lets the terrain
# appear in the 3D view and the Generate button work. Engine.is_editor_hint() tells the two cases apart.
@tool
# GDScript note: class_name makes "Terrain" a global name. Other scripts can use it as a type, and it appears
# in the editor's Add Node list.
class_name Terrain
# GDScript note: extends says what this script builds on. A Node3D has a position in the world and can have children.
extends Node3D

## Sent once for each chunk whenever its collision is built or rebuilt.
# GDScript note: a signal lets other code react without this script knowing who is listening. Someone connects with
# terrain.collision_built.connect(my_function), and emit() below calls every connected function.
# The parameters are the chunk's grid position and the node holding its collision shape.
signal collision_built(chunk: Vector2i, collision_node: CollisionShape3D)
## Sent when a chunk has just been removed. Claude 2026-11-07: AI on it needs to know before its next tick.
signal chunk_removed(chunk: Vector2i)
## Sent when an edit has just raised the ground. center is the middle of the patch in the world, seen from above, as X and Z.
## Claude 2026-11-07: TerrainBodyLifter uses it, so moving bodies isn't this script's job.
signal ground_raised(center: Vector2, radius: float)
## Sent when a chunk has been built or rebuilt, with its triangles, measured from this node. Claude 2026-11-07: WorldNavLink uses it.
signal chunk_built(chunk: Vector2i, triangles: PackedVector3Array)
## Sent when generate() or start_empty() begins, with the settings it's about to use already in place.
signal generation_started

# GDScript note: a const is a value that never changes.
# How far a point can move at full jitter, as a share of one grid square. Any further, and a triangle could flip inside
# out: its shortest height is about 0.7 of a square, and two of its corners can move toward each other.
const MAX_JITTER_REACH := 0.34
# Means "there's no ground here". INF is GDScript's name for infinity, which no real height will ever be.
const NO_GROUND := INF

# GDScript note: @export_group puts the @export settings below it under a collapsible heading in the inspector.
@export_group("Size")
# GDScript note: @export shows a variable in the inspector and saves its value in the scene.
# := means "work out the type from the value", so chunk_radius is an int. Writing it out as "var chunk_radius: int = 1"
# means the same thing. Once a variable has a type, GDScript refuses to put a different type in it.
## How many chunks to build around center_chunk. 0 builds one chunk, 1 builds 3×3, and 2 builds 5×5.
@export var chunk_radius := 1
## The chunk in the middle. With a radius of 0, this picks which one tile of a larger world to build.
## Chunks with different numbers line up exactly, because heights come from positions in the world.
@export var center_chunk := Vector2i.ZERO
## How wide one chunk is, in metres.
# Claude 2026-11-05: in procgen_tile.gd, tile_size was the size of one square, so a finer grid also made a bigger tile.
# Here it's the whole chunk, so chunk_resolution can change without changing how big the terrain is.
# GDScript note: @export_range gives the inspector a slider. "or_greater" still lets you type a larger value by hand.
# Claude 2026-11-06: defaults raised from 72 and 12, keeping squares of about 6 m as before. First 256 m, then lowered to
# 128 m by the owner after the stress test: its worst single step is about a third of 256 m's, which suits slower machines.
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

@export_group("Noise")
@export var noise_seed := 250
## Multiplies positions before reading the noise, with X and Z separate. Above 1 squeezes hills together, and below 1
## spreads them out. Different values for X and Z stretch hills in one direction. It doesn't move any grid points.
@export var noise_scale := Vector2.ONE
## The kind of noise.
# Claude 2026-11-05: procgen_tile.gd used its own list of names, and they didn't match Godot's numbers, so "Simplex"
# really gave Cellular. Using Godot's own enum as the type means the names always match. fractal_type below does the
# same, which matters there too: the first entry in Godot's list means no fractal at all, not FBM.
# GDScript note: an enum is a list of named numbers. When an @export has an enum as its type, the inspector shows a menu.
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
# Claude 2026-11-06: added for ChunkStreamer. On is the default, so every existing scene behaves as before.
@export var build_on_start := true
## Off: no meshes are built, only collision, which saves time and memory on a machine nobody looks at.
## A build exported with Godot's dedicated_server feature never builds meshes, whatever this says.
# Claude 2026-11-07: added for multiplayer streaming. A mesh was about 1.9 ms of the 6.5 ms a 256 m chunk cost.
@export var build_meshes := true

@export_group("")
## Rebuilds the terrain from the current settings. Any edits are lost, including ones in a TerrainEditLog.
# GDScript note: @export_tool_button draws a button in the inspector that calls this function. It needs @tool.
# Writing "generate" without brackets doesn't call the function. It refers to the function itself, as a value.
@export_tool_button("Generate") var generate_button := generate

# GDScript note: variables without @export don't show in the inspector and aren't saved. A leading underscore is a
# convention meaning "private to this script". GDScript doesn't enforce it.
var _noise := FastNoiseLite.new()
# GDScript note: a Dictionary maps keys to values, like a lookup table. Each of these uses the chunk's grid position,
# a Vector2i, as its key. A PackedVector3Array is a compact array that can only hold Vector3s.
var _points := {} # Vector2i -> PackedVector3Array, with (chunk_resolution + 1)^2 grid points, row by row, measured from this node
var _mesh_nodes := {} # Vector2i -> MeshInstance3D
var _collision_nodes := {} # Vector2i -> CollisionShape3D, each one inside its own StaticBody3D
var _plain_material := StandardMaterial3D.new() # used when the material setting is empty
var _has_generated := false
# Claude 2026-11-06: the next three are for building and unloading one chunk at a time.
var _building := {} # Vector2i -> _ChunkBuild, the chunks that are partly built
var _edited_chunks := {} # Vector2i -> true, used only to warn when an unload is about to lose an edit
var _warned_about_lost_edits := false
# Claude 2026-11-07: the two below are for TerrainEditLog, an optional module.
var _edit_log: TerrainEditLog = null
var _rebuild_queue: Array[Vector2i] = [] # chunks to rebuild, one per frame, because the log changed


## Everything a half-built chunk needs to remember between steps.
# Claude 2026-11-06: added so a chunk can be built over several frames, for slower machines.
# GDScript note: a class inside a script is a small helper type that only this script normally uses.
class _ChunkBuild:
	var stage := Stage.POINTS
	var next_row := 0 # the next row to work on in the current stage
	var points := PackedVector3Array()
	var mesh := _MeshData.new()
	var triangles := PackedVector3Array()
	var next_edit := 0 # Claude 2026-11-07: how far through this chunk's edits it has got


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
# How much one build step does. Measured 2026-11-06 at about 0.4 ms on a fast desktop, so slower machines stay near
# their budget too. Collision can't be split, so it's the largest single step.
const POINTS_PER_STEP := 350
const SQUARES_PER_STEP := 700
const SMOOTH_POINTS_PER_STEP := 120
# Claude 2026-11-07: measured at about 24 microseconds an edit on a 128 m chunk.
const EDITS_PER_STEP := 20


## Every Terrain joins this Godot group, which is how other systems find them.
const GROUP := &"terrains"


# --- Godot calls these by itself ---
# GDScript note: functions starting with an underscore that Godot knows by name are callbacks. For a node, Godot calls
# _enter_tree when it joins the scene, _ready once after its children are ready, and _exit_tree when it leaves.


func _ready() -> void:
	set_process(false) # Claude 2026-11-07: only runs while chunks are waiting to be rebuilt
	# Claude 2026-11-06: a streamed terrain starts empty. The editor still builds the block, as a preview.
	if build_on_start or Engine.is_editor_hint():
		_build_block()
	else:
		start_empty()


# If this node is taken out of the scene and put back, _ready won't run again.
func _enter_tree() -> void:
	add_to_group(GROUP) # Claude 2026-11-07: see GROUP
	if _has_generated:
		# GDScript note: looping over a Dictionary gives you its keys.
		for key in _points:
			_rebuild_solid(key)


# Claude 2026-11-07: a change to the edit log rebuilds chunks a few at a time, so it doesn't stall a frame.
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
		_edit_log.clear() # Claude 2026-11-07: as this function's description says
	_build_block()


func _build_block() -> void:
	_prepare()

	# All the points go first, because smooth lighting at a chunk's edge needs its neighbours' points.
	# GDScript note: range(a, b) counts from a up to, but not including, b. That's why these have + 1.
	for z in range(center_chunk.y - chunk_radius, center_chunk.y + chunk_radius + 1):
		for x in range(center_chunk.x - chunk_radius, center_chunk.x + chunk_radius + 1):
			_generate_points(Vector2i(x, z))
	for key in _points:
		_rebuild_mesh(key)
		_rebuild_solid(key)
	_has_generated = true


## Clears everything and applies the current settings, leaving no chunks built. A terrain with build_on_start off does
## this by itself. After this, build_chunk_step and load_chunk add chunks.
# Claude 2026-11-06: added for ChunkStreamer.
func start_empty() -> void:
	_prepare()
	_has_generated = true


## Which chunk a position in the world is over.
func chunk_of(world_position: Vector3) -> Vector2i:
	var local := world_position - _terrain_origin()
	return Vector2i(floori(local.x / chunk_size), floori(local.z / chunk_size))


## True once a chunk is completely built, including its collision. A chunk that's partly built doesn't count.
func has_chunk(key: Vector2i) -> bool:
	# Claude 2026-11-07: reads the points, because a chunk with build_meshes off has no mesh node.
	return _points.has(key) and not _building.has(key)


## True if every chunk within margin metres of this position is completely built. Quick, because AI checks it often:
## a position in the middle of a chunk only needs that one chunk.
# Claude 2026-11-07: added for AIActivityModule.
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


## Does one small piece of building a chunk, and returns true once the chunk is finished. Call it again with the same
## chunk to continue. ChunkStreamer uses this to spread a chunk over several frames. Several chunks can be partly built
## at once. The result is exactly the same as generate() would make, because both use the same functions.
# Claude 2026-11-06: added so slower machines don't stall while a chunk loads. See POINTS_PER_STEP above.
func build_chunk_step(key: Vector2i) -> bool:
	if has_chunk(key):
		return true
	if not _has_generated:
		start_empty()
	var build: _ChunkBuild = _building.get(key)
	if build == null:
		build = _ChunkBuild.new()
		build.points.resize(_points_per_edge() * _points_per_edge())
		_building[key] = build

	# GDScript note: match compares a value against each option below, like a list of "if" checks.
	match build.stage:
		Stage.POINTS:
			var rows := maxi(1, POINTS_PER_STEP / _points_per_edge())
			var end_row := mini(build.next_row + rows, _points_per_edge())
			_fill_point_rows(build.points, key, build.next_row, end_row)
			build.next_row = end_row
			if end_row == _points_per_edge():
				build.next_row = 0
				build.stage = Stage.EDITS
		Stage.EDITS:
			# Claude 2026-11-07: a much-dug chunk can have a long list, so this is split up too.
			if _edit_log != null and build.next_edit < _edit_log.get_chunk_edit_count(key):
				build.next_edit = _edit_log.apply_some_to_chunk(key, build.points, build.next_edit, EDITS_PER_STEP)
				return false
			# The points are only made public once they're complete, so height_at never reads half a chunk.
			_points[key] = build.points
			if _wants_meshes():
				_start_mesh_data(build.mesh)
				build.stage = Stage.MESH_ROWS
			else:
				build.stage = Stage.COLLISION
		Stage.MESH_ROWS:
			var end_row := mini(build.next_row + _mesh_rows_per_step(), _mesh_row_count())
			_fill_mesh_rows(build.mesh, key, build.next_row, end_row)
			build.next_row = end_row
			if end_row == _mesh_row_count():
				build.stage = Stage.MESH_NODE
		Stage.MESH_NODE:
			_set_chunk_mesh(key, build.mesh.as_arrays())
			build.stage = Stage.COLLISION
		Stage.COLLISION:
			build.triangles = _chunk_triangles(key)
			if build_collision and not Engine.is_editor_hint():
				_rebuild_collision(key, build.triangles)
			build.stage = Stage.ANNOUNCE
		Stage.ANNOUNCE:
			_building.erase(key)
			chunk_built.emit(key, build.triangles)
			return true
	return false


## Builds a chunk completely, right now. Simple, but it takes several milliseconds, so it can show up as a stutter.
func load_chunk(key: Vector2i) -> void:
	# GDScript note: "pass" means do nothing. All the work here happens in the loop's condition.
	while not build_chunk_step(key):
		pass


## Removes a chunk: its mesh, collision, nav data and markers, or whatever part of them has been built.
## With no TerrainEditLog, any edits on this chunk are lost, and it warns the first time that happens.
func unload_chunk(key: Vector2i) -> void:
	if _edit_log == null and _edited_chunks.has(key) and not _warned_about_lost_edits:
		_warned_about_lost_edits = true
		push_warning("Terrain: unloading a chunk that was edited, so its edits are lost. Add a TerrainEditLog child to keep them. Shown once.")
	_forget_chunk(key)


## A built chunk's triangles, measured from this node. Claude 2026-11-07: for something that arrives after the chunk was built.
func get_chunk_triangles(key: Vector2i) -> PackedVector3Array:
	return _chunk_triangles(key) if _points.has(key) else PackedVector3Array()


## A chunk's markers, placed in the world. See _make_chunk_markers. Claude 2026-11-07: WorldNavLink announces them.
func get_chunk_markers(key: Vector2i) -> Array[NavMarker]:
	var markers := _make_chunk_markers(key)
	var origin := _terrain_origin()
	for marker in markers:
		if marker != null: # NavWorld refuses a null one and warns, so it's left in the list for that
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
# GDScript note: Variant means "any type". It's needed here because the result is either a Vector3 or null, so whoever
# calls this should check for null first.
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
			# GDScript note: "for i in 12" repeats 12 times, with i counting from 0 to 11.
			for i in 12:
				var middle := (above + below) * 0.5
				if _is_under_ground(middle):
					below = middle
				else:
					above = middle
			return below
		previous = point
	return null


## Raises (amount above 0) or digs (amount below 0) a round patch centred on a position in the world, then rebuilds
## only the chunks it touched. The middle moves by the full amount, and the outer half of the radius fades to nothing.
## With a TerrainEditLog child, the edit outlasts its chunk. Without one, it's gone when the chunk unloads.
## In multiplayer, add a TerrainEditLog: it tells the clients, and keeps them from editing on their own. Without one, an edit stays on
## the machine that made it, and machines end up on different ground.
# Claude 2026-11-07: the network rule moved to TerrainEditLog, so this script doesn't need to know about networks.
func edit(center: Vector3, radius: float, amount: float) -> void:
	if radius <= 0.0 or (_edit_log != null and _edit_log.refuses_edit()):
		return
	# Claude 2026-11-06: a half-built chunk would finish with a mesh made from the heights before this edit, so finish
	# them first. It costs a stutter only if an edit lands while a chunk is loading.
	for key: Vector2i in _building.keys():
		load_chunk(key)
	var local_center := center - _terrain_origin()
	# Claude 2026-11-07: rounded to 32 bits first, the same as what the log stores, so that every machine gets identical ground.
	var rounded := PackedFloat32Array([local_center.x, local_center.z, radius, amount])
	if _edit_log != null:
		_edit_log.record(rounded[0], rounded[1], rounded[2], rounded[3])
	_apply_edit_to_loaded_chunks(rounded[0], rounded[1], rounded[2], rounded[3])


## An edit from the server has reached this client, and the log has it already.
func _apply_edit_from_log(x: float, z: float, radius: float, amount: float) -> void:
	for key: Vector2i in _building.keys():
		load_chunk(key)
	_apply_edit_to_loaded_chunks(x, z, radius, amount)


## Changes the heights of the chunks that are built, and rebuilds them. The log isn't touched here.
func _apply_edit_to_loaded_chunks(x: float, z: float, radius: float, amount: float) -> void:
	var flat_center := Vector2(x, z)
	# The patch, plus two squares: enough to reach any chunk whose smooth lighting reads a point that moved.
	var margin := radius + 2.0 * _square_size()
	# GDScript note: a typed array, Array[Vector2i], can only hold that type, and GDScript checks it for you.
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
			_edited_chunks[key] = true # Claude 2026-11-06: so unloading it can warn that the edit is lost

	# Then rebuild. A chunk next to the patch can need new smooth lighting even when none of its own points moved.
	# Collision and nav only care about its own points.
	for key in nearby_chunks:
		_rebuild_mesh(key)
	for key in changed_chunks:
		_rebuild_solid(key)
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
			# smoothstep goes smoothly from 0 to 1 between its first two numbers, so 1 minus it fades out.
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


## A number that changes if the settings that decide the ground change. TerrainEditLog uses it to refuse edits made for
## different ground.
func ground_settings_hash() -> int:
	return hash([chunk_size, chunk_resolution, height_scale, grid_jitter, noise_seed, noise_scale, int(noise_type), frequency, int(fractal_type), fractal_octaves, fractal_gain, fractal_lacunarity])


# --- For scripts that extend this one ---


## Change this to shape the ground beyond the noise, such as a flat plaza or a wall. Copy tests/terrain_test_course.gd
## to see how. noise_height is the height so far, and the position is measured from this node.
# GDScript note: another script can say "extends Terrain" and write its own _shape_height. GDScript then uses
# that version everywhere, including in the calls made from this file. That script also needs @tool to show its shapes
# in the editor preview.
func _shape_height(_x: float, _z: float, noise_height: float) -> float:
	# GDScript note: an underscore at the start of a parameter says "not used here on purpose", which stops a warning.
	return noise_height


## Change this to give a chunk its links and points of interest. Copy tests/terrain_marker_example.gd to see how.
## A WorldNavLink announces them to NavWorld when the chunk is built and after an edit, so they can't float or get buried, and
## releases them when it's gone. By default a chunk has none and pays nothing. Rules for what you return:
##   - Make new markers every time, because get_chunk_markers moves them into place.
##   - Set each marker's position measured from this node, as _shape_height does. _point_at gives grid points.
##   - Build the list from the chunk's numbers, not random numbers, so every machine gets the same list. A marker's
##     id comes from its place in the list. That's also why an edit shouldn't change the list, only the heights,
##     or a change remembered for one marker could land on another.
##   - Declare the markers' tags in nav_tag_declarations.tres, or they're refused.
# Claude 2026-11-06: the nav spec's section 21.6. The generator knows its own terrain, so it says what's there.
func _make_chunk_markers(_key: Vector2i) -> Array[NavMarker]:
	return []


# --- The edit log module ---
# Claude 2026-11-07: everything the terrain does about edits outlasting their chunks goes through here, and stops if the
# module isn't there.


func _edit_log_arrived(log_module: TerrainEditLog) -> void:
	_edit_log = log_module


func _edit_log_left(log_module: TerrainEditLog) -> void:
	if _edit_log == log_module:
		_edit_log = null
		# Deferred, so that this can tell the module being deleted apart from the whole terrain leaving the scene.
		_return_to_default_ground.call_deferred()


## The module is gone, so anything it put on the ground goes too. Chunks with no edits don't change.
func _return_to_default_ground() -> void:
	if _edit_log != null or not is_inside_tree():
		return
	_rebuild_chunks_for_log(_edited_chunks.keys())
	_edited_chunks.clear()


## Queues the built ones among these chunks to be rebuilt from scratch, with whatever the log now says.
func _rebuild_chunks_for_log(chunks: Array) -> void:
	for key: Vector2i in _building.keys():
		load_chunk(key) # so a half-built chunk can't finish with what it read before
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


## Works out some rows of a chunk's grid points. Claude 2026-11-06: split out so a build can stop between rows.
func _fill_point_rows(points: PackedVector3Array, key: Vector2i, from_row: int, to_row: int) -> void:
	var n := _points_per_edge()
	for z in range(from_row, to_row):
		for x in n:
			# Points are numbered across the whole world, not within the chunk, and everything about a point comes from
			# that number. The last point of one chunk has the same number as the first point of the next, so both
			# chunks get exactly the same position and height. That's what makes the terrain seamless.
			# Claude 2026-11-05: procgen_tile.gd used positions within the tile, so every tile came out the same.
			points[x + z * n] = _make_point(key.x * chunk_resolution + x, key.y * chunk_resolution + z)


## Where a grid point is, and how high, from its number across the whole world.
func _make_point(world_x_number: int, world_z_number: int) -> Vector3:
	var x := world_x_number * _square_size()
	var z := world_z_number * _square_size()
	if grid_jitter > 0.0:
		# hash() turns anything into a big number that looks random, but is always the same for the same input. So
		# every machine gets the same terrain, with no random numbers to keep in step.
		# GDScript note: Vector3i is three whole numbers. Here it just bundles the three things that decide the shift.
		var random := hash(Vector3i(world_x_number, world_z_number, noise_seed))
		# Split the big number into two numbers from 0 to 1. "&" keeps only some of its bits, and ">>" slides them along.
		var random_1 := (random & 0xFFFF) / 65535.0
		var random_2 := ((random >> 16) & 0xFFFF) / 65535.0
		# Pick a direction, and a distance inside a circle. The square root spreads points evenly over the circle,
		# instead of bunching them near the middle. A circle looks more natural than shifting X and Z separately.
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


## Every triangle in a chunk, as one long list with three corners each. Each square is two triangles, a-b-c and b-d-c:
##     a --- b
##     |  /  |
##     c --- d
## Godot treats a triangle as facing you if its corners run clockwise, so this order makes them all face up.
func _chunk_triangles(key: Vector2i) -> PackedVector3Array:
	var points: PackedVector3Array = _points[key]
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
	# GDScript note: get() on a Dictionary returns null, rather than an error, when the key isn't there.
	var mesh_node: MeshInstance3D = _mesh_nodes.get(key)
	if mesh_node == null:
		mesh_node = MeshInstance3D.new()
		# These nodes have no "owner", so Godot doesn't save them in the scene file. The terrain is rebuilt on load.
		add_child(mesh_node)
		_mesh_nodes[key] = mesh_node
	# GDScript note: "x if condition else y" picks one of two values. An empty object counts as false.
	mesh_node.material_override = material if material else _plain_material
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh_node.mesh = mesh


## Sets up a chunk's triangles, UVs and normals. A normal is the direction the surface faces at a vertex, and lighting
## is worked out from it. This is separate from _rebuild_mesh so the test can read the result without a mesh.
##
## The one idea behind normals: a vertex has one normal, so how you share vertices decides the look. A flat look needs
## each triangle to have its own three vertices, with one normal between them. A smooth look needs triangles to share
## one vertex at each corner, with a normal blended from every triangle touching that corner.
# Claude 2026-11-05: both normals are worked out here, not with SurfaceTool.generate_normals(). That only sees one
# chunk's triangles, so the two sides of a chunk border got different lighting and showed a faint line. Its smooth
# groups are also the reason slope_smoothing did nothing in procgen_tile.gd: SurfaceTool reads the group when a vertex
# is added, and that code set it later, while adding indices.
# Claude 2026-11-06: this fills arrays directly instead of using SurfaceTool. SurfaceTool took 5.6 ms of the 10.7 ms a
# 256 m chunk cost, because it needs several script calls per vertex. The vertices, normals, UVs and indices are unchanged.
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
		return maxi(1, SMOOTH_POINTS_PER_STEP / _points_per_edge())
	return maxi(1, SQUARES_PER_STEP / chunk_resolution)


func _fill_mesh_rows(data: _MeshData, key: Vector2i, from_row: int, to_row: int) -> void:
	if smooth_shading:
		_fill_smooth_rows(data, key, from_row, to_row)
	else:
		_fill_flat_rows(data, key, from_row, to_row)


func _fill_flat_rows(data: _MeshData, key: Vector2i, from_row: int, to_row: int) -> void:
	# GDScript note: packed arrays are shared, not copied, when assigned like this, so writing to these local names
	# fills the lists in data. Going through local names is also quicker than writing data.vertices[i] each time.
	var vertices := data.vertices
	var normals := data.normals
	var uvs := data.uvs
	var points: PackedVector3Array = _points[key]
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
			# A cross product gives a direction square-on to two others, which makes it the way a triangle faces.
			# The order of the two matters: this way round points up, and the other way would point into the ground.
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


func _fill_smooth_rows(data: _MeshData, key: Vector2i, from_row: int, to_row: int) -> void:
	var vertices := data.vertices
	var normals := data.normals
	var uvs := data.uvs
	var indices := data.indices
	var points: PackedVector3Array = _points[key]
	var n := _points_per_edge()
	for z in range(from_row, to_row):
		for x in n:
			var i := x + z * n
			normals[i] = _smooth_normal(key.x * chunk_resolution + x, key.y * chunk_resolution + z)
			uvs[i] = _uv_of(key, points[i])
			vertices[i] = points[i]
		# With shared vertices, a triangle is three vertex numbers instead of three positions. This is the same a-b-c
		# and b-d-c split as _chunk_triangles. The last row of vertices has no squares below it.
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
		# "%" is the remainder after dividing. It makes the last neighbour wrap around to the first one.
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


func _rebuild_collision(key: Vector2i, triangles: PackedVector3Array) -> void:
	var collision_node: CollisionShape3D = _collision_nodes.get(key)
	if collision_node == null:
		# Godot's physics needs a body, with a collision shape inside it. A static body is one that never moves.
		collision_node = CollisionShape3D.new()
		collision_node.shape = ConcavePolygonShape3D.new()
		var body := StaticBody3D.new()
		body.add_child(collision_node)
		add_child(body)
		_collision_nodes[key] = collision_node
	# GDScript note: "as" converts the type, here so that set_faces is known to exist on the shape.
	(collision_node.shape as ConcavePolygonShape3D).set_faces(triangles)
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
	# GDScript note: keys() makes a separate list, which makes it safe to remove items from the Dictionary while looping.
	for key: Vector2i in _points.keys():
		_forget_chunk(key)
	_building.clear() # any left have no points yet, so nothing else has been made for them
	_edited_chunks.clear()


## Removes whatever exists of one chunk.
# Claude 2026-11-06: split out of _clear, so one chunk can go on its own.
func _forget_chunk(key: Vector2i) -> void:
	_building.erase(key)
	if _mesh_nodes.has(key):
		var mesh_node: MeshInstance3D = _mesh_nodes[key]
		remove_child(mesh_node)
		mesh_node.queue_free() # queue_free deletes a node safely at the end of the frame
		_mesh_nodes.erase(key)
	if _collision_nodes.has(key):
		var body: Node = _collision_nodes[key].get_parent()
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
		# Claude 2026-11-07: a neighbour that isn't built still has its edits, so lighting at the border matches.
		return _edit_log.apply_to_point(key, point) if _edit_log != null else point
	var index := posmod(world_x_number, chunk_resolution) + posmod(world_z_number, chunk_resolution) * _points_per_edge()
	return _points[key][index]


## UVs come from the position within the chunk, so a texture lines up across borders even when points are shifted.
func _uv_of(key: Vector2i, point: Vector3) -> Vector2:
	return Vector2(point.x - key.x * chunk_size, point.z - key.y * chunk_size) / chunk_size * uv_scale


# Asking for a global position outside the scene is an error, so treat that case as the world origin.
func _terrain_origin() -> Vector3:
	return global_position if is_inside_tree() else Vector3.ZERO
