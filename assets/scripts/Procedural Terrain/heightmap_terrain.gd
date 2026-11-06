## Written by Claude (claude-opus-5-5), 2026-11-05: one terrain generator with the features of procgen_tile.gd and
## nav_test_terrain.gd, built alongside them. Both originals stay as they are, and nothing uses this one yet except its
## sample scene and test.
##
## The look it goes for is low poly without a visible square grid. The four settings that shape that are noise_scale,
## grid_jitter, grid_size (how fine the grid is) and tile_size (how big a chunk is in metres), plus smooth_shading.
##
## From procgen_tile.gd: the noise settings, UVs, a Generate button in the editor, and a signal when collision is ready.
## From nav_test_terrain.gd: seamless chunks, height_at(), raycast(), live edit(), and feeding the nav system.
##
## How it holds together: _chunk_triangles() makes one list of triangles for each chunk. The flat-shaded mesh, the
## collision and the nav system all use that list, so what you see, what you stand on and what nav walks on are the same.
##
## How to use it: add a Node3D to a scene, attach this script, and press Play or the Generate button in the inspector.
## To see it working, open terrain_sample.tscn. The test is tests/heightmap_terrain_selftest.tscn.
##
## How to read this file, if you're getting back into GDScript: "GDScript note:" comments explain a language feature
## the first time it comes up. The other comments explain what this terrain does and why.
##
## GDScript note: a comment starting with ## is a documentation comment. Above a class, function or variable, it shows
## up in the editor's help, and above an @export it becomes the tooltip in the inspector. A # comment is just a note.

# GDScript note: @tool makes this script run inside the editor as well as in the game. That's what lets the terrain
# appear in the 3D view and the Generate button work. Engine.is_editor_hint() tells the two cases apart.
@tool
# GDScript note: class_name makes "HeightmapTerrain" a global name. Other scripts can use it as a type, and it appears
# in the editor's Add Node list.
class_name HeightmapTerrain
# GDScript note: extends says what this script builds on. A Node3D has a position in the world and can have children.
extends Node3D

## Sent once for each chunk whenever its collision is built or rebuilt.
# GDScript note: a signal lets other code react without this script knowing who is listening. Someone connects with
# terrain.collision_built.connect(my_function), and emit() below calls every connected function.
# The parameters are the chunk's grid position and the node holding its collision shape.
signal collision_built(chunk: Vector2i, collision_node: CollisionShape3D)

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
# Here it's the whole chunk, so grid_size can change without changing how big the terrain is.
# GDScript note: @export_range gives the inspector a slider. "or_greater" still lets you type a larger value by hand.
# Claude 2026-11-06: defaults raised from 72 and 12, so a chunk is about 256 m with squares of about 6 m as before.
@export_range(1.0, 1000.0, 0.5, "or_greater") var tile_size := 256.0
## How fine the grid is: the number of squares along each side of a chunk. Fewer squares look more low poly.
@export_range(1, 256, 1, "or_greater") var grid_size := 43
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

@export_group("Navigation")
## Give this a NavHooks resource to make the nav system see this terrain. Leave it empty to keep it invisible to nav.
# Claude 2026-11-05: typed as Resource instead of NavHooks, and NavServer is looked up by name in _connect_to_nav.
# Writing either name directly would stop this script compiling on a build without the nav DLL. This way, a terrain
# that doesn't use nav always works.
# GDScript note: @export_custom sets the inspector hint by hand. This one offers only NavHooks in the picker.
@export_custom(PROPERTY_HINT_RESOURCE_TYPE, "NavHooks") var nav_hooks: Resource

@export_group("")
## Rebuilds the terrain from the current settings. Any edits made with edit() are lost.
# GDScript note: @export_tool_button draws a button in the inspector that calls this function. It needs @tool.
# Writing "generate" without brackets doesn't call the function. It refers to the function itself, as a value.
@export_tool_button("Generate") var generate_button := generate

# GDScript note: variables without @export don't show in the inspector and aren't saved. A leading underscore is a
# convention meaning "private to this script". GDScript doesn't enforce it.
var _noise := FastNoiseLite.new()
# GDScript note: a Dictionary maps keys to values, like a lookup table. Each of these uses the chunk's grid position,
# a Vector2i, as its key. A PackedVector3Array is a compact array that can only hold Vector3s.
var _points := {} # Vector2i -> PackedVector3Array, with (grid_size + 1)^2 grid points, row by row, measured from this node
var _mesh_nodes := {} # Vector2i -> MeshInstance3D
var _collision_nodes := {} # Vector2i -> CollisionShape3D, each one inside its own StaticBody3D
var _plain_material := StandardMaterial3D.new() # used when the material setting is empty
var _nav: Object = null # the NavServer, or null when this terrain isn't using nav
var _nav_layer := -1 # our layer's number in the NavServer, or -1 for none
var _terrain_id := 0 # our id in NavWorld, or 0 when not registered, such as in the editor preview
var _has_generated := false


# --- Godot calls these by itself ---
# GDScript note: functions starting with an underscore that Godot knows by name are callbacks. For a node, Godot calls
# _enter_tree when it joins the scene, _ready once after its children are ready, and _exit_tree when it leaves.


func _ready() -> void:
	generate()


# If this node is taken out of the scene and put back, _exit_tree has removed it from nav, and _ready won't run again.
func _enter_tree() -> void:
	if _has_generated:
		_connect_to_nav()
		_register_with_nav_world()
		# GDScript note: looping over a Dictionary gives you its keys.
		for key in _points:
			_rebuild_solid(key)
			_announce_markers(key)


func _exit_tree() -> void:
	if _nav and _nav_layer >= 0:
		_nav.remove_input_layer(_nav_layer)
	_nav_layer = -1
	_release_all_markers()
	if _terrain_id != 0:
		NavWorld.unregister_terrain(_terrain_id)
		_terrain_id = 0


# --- Things other scripts can call ---


## Builds the terrain from the current settings, replacing anything already built. Call this again after changing
## settings from code. It runs by itself once when the node enters the scene.
func generate() -> void:
	_clear()
	_fix_bad_settings()
	_apply_noise_settings()
	_plain_material.albedo_color = Color(0.46, 0.43, 0.37)
	_plain_material.roughness = 1.0
	if _nav_layer < 0:
		_connect_to_nav()
	_register_with_nav_world()

	# All the points go first, because smooth lighting at a chunk's edge needs its neighbours' points.
	# GDScript note: range(a, b) counts from a up to, but not including, b. That's why these have + 1.
	for z in range(center_chunk.y - chunk_radius, center_chunk.y + chunk_radius + 1):
		for x in range(center_chunk.x - chunk_radius, center_chunk.x + chunk_radius + 1):
			_generate_points(Vector2i(x, z))
	for key in _points:
		_rebuild_mesh(key)
		_rebuild_solid(key)
		_announce_markers(key)
	_has_generated = true


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
func edit(center: Vector3, radius: float, amount: float) -> void:
	if radius <= 0.0:
		return
	var local_center := center - _terrain_origin()
	var flat_center := Vector2(local_center.x, local_center.z)
	# The patch, plus two squares: enough to reach any chunk whose smooth lighting reads a point that moved.
	var margin := radius + 2.0 * _square_size()
	# GDScript note: a typed array, Array[Vector2i], can only hold that type, and GDScript checks it for you.
	var nearby_chunks: Array[Vector2i] = []
	var changed_chunks: Array[Vector2i] = []

	# First, change every height.
	for key: Vector2i in _points.keys():
		# Skip this chunk if the patch can't reach it. Checking is much cheaper than visiting every point.
		var chunk_start := Vector2(key.x * tile_size, key.y * tile_size)
		if flat_center.x + margin < chunk_start.x or flat_center.x - margin > chunk_start.x + tile_size:
			continue
		if flat_center.y + margin < chunk_start.y or flat_center.y - margin > chunk_start.y + tile_size:
			continue
		nearby_chunks.append(key)

		var points: PackedVector3Array = _points[key]
		var touched := false
		for i in points.size():
			var distance := Vector2(points[i].x, points[i].z).distance_to(flat_center)
			if distance < radius:
				# smoothstep goes smoothly from 0 to 1 between its first two numbers, so 1 minus it fades out.
				points[i].y += amount * (1.0 - smoothstep(radius * 0.5, radius, distance))
				touched = true
		if touched:
			_points[key] = points # store it back, so there's no doubt the Dictionary has the changed points
			changed_chunks.append(key)

	# Then rebuild. A chunk next to the patch can need new smooth lighting even when none of its own points moved.
	# Collision and nav only care about its own points.
	for key in nearby_chunks:
		_rebuild_mesh(key)
	for key in changed_chunks:
		_rebuild_solid(key)
		# Claude 2026-11-06: the ground moved, so the chunk announces its markers again, or they'd float or get buried.
		_announce_markers(key)


# --- For scripts that extend this one ---


## Change this to shape the ground beyond the noise, such as a flat plaza or a wall. Copy tests/terrain_test_course.gd
## to see how. noise_height is the height so far, and the position is measured from this node.
# GDScript note: another script can say "extends HeightmapTerrain" and write its own _shape_height. GDScript then uses
# that version everywhere, including in the calls made from this file. That script also needs @tool to show its shapes
# in the editor preview.
func _shape_height(_x: float, _z: float, noise_height: float) -> float:
	# GDScript note: an underscore at the start of a parameter says "not used here on purpose", which stops a warning.
	return noise_height


## Change this to give a chunk its links and points of interest. Copy tests/terrain_marker_example.gd to see how.
## This terrain announces them to NavWorld when the chunk is built and after an edit, and releases them when it's gone.
## By default a chunk has none and pays nothing. Rules for what you return:
##   - Make new markers every time, because this terrain moves them into place.
##   - Set each marker's position measured from this node, as _shape_height does. _point_at gives grid points.
##   - Build the list from the chunk's numbers, not random numbers, so every machine gets the same list. A marker's
##     id comes from its place in the list. That's also why an edit shouldn't change the list, only the heights,
##     or a change remembered for one marker could land on another.
##   - Declare the markers' tags in nav_tag_declarations.tres, or they're refused.
# Claude 2026-11-06: the nav spec's section 21.6. The generator knows its own terrain, so it says what's there.
func _make_chunk_markers(_key: Vector2i) -> Array[NavMarker]:
	return []


# --- Building: the grid points ---


func _generate_points(key: Vector2i) -> void:
	var n := _points_per_edge()
	var points := PackedVector3Array()
	points.resize(n * n) # sized up front, because that's quicker than growing it one item at a time
	for z in n:
		for x in n:
			# Points are numbered across the whole world, not within the chunk, and everything about a point comes from
			# that number. The last point of one chunk has the same number as the first point of the next, so both
			# chunks get exactly the same position and height. That's what makes the terrain seamless.
			# Claude 2026-11-05: procgen_tile.gd used positions within the tile, so every tile came out the same.
			points[x + z * n] = _make_point(key.x * grid_size + x, key.y * grid_size + z)
	_points[key] = points


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
	triangles.resize(grid_size * grid_size * 6)
	var next := 0
	for z in grid_size:
		for x in grid_size:
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
	# GDScript note: get() on a Dictionary returns null, rather than an error, when the key isn't there.
	var mesh_node: MeshInstance3D = _mesh_nodes.get(key)
	if mesh_node == null:
		mesh_node = MeshInstance3D.new()
		# These nodes have no "owner", so Godot doesn't save them in the scene file. The terrain is rebuilt on load.
		add_child(mesh_node)
		_mesh_nodes[key] = mesh_node
	# GDScript note: "x if condition else y" picks one of two values. An empty object counts as false.
	mesh_node.material_override = material if material else _plain_material
	mesh_node.mesh = _make_surface(key).commit()


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
func _make_surface(key: Vector2i) -> SurfaceTool:
	# SurfaceTool is Godot's helper for building a mesh a piece at a time. Calls like set_uv and set_normal apply to
	# the next add_vertex, so they come first.
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	if smooth_shading:
		_add_smooth_triangles(surface, key)
	else:
		_add_flat_triangles(surface, key)
	return surface


func _add_flat_triangles(surface: SurfaceTool, key: Vector2i) -> void:
	var triangles := _chunk_triangles(key)
	# GDScript note: range's third number is the step, so this visits the start of each triangle.
	for i in range(0, triangles.size(), 3):
		var first := triangles[i]
		var second := triangles[i + 1]
		var third := triangles[i + 2]
		# A cross product gives a direction square-on to two others, which makes it the way this triangle faces.
		# The order of the two matters: this way round points up, and the other way would point into the ground.
		var normal := (third - first).cross(second - first).normalized()
		for corner in [first, second, third]:
			surface.set_normal(normal)
			surface.set_uv(_uv_of(key, corner))
			surface.add_vertex(corner)


func _add_smooth_triangles(surface: SurfaceTool, key: Vector2i) -> void:
	var points: PackedVector3Array = _points[key]
	var n := _points_per_edge()
	for z in n:
		for x in n:
			surface.set_normal(_smooth_normal(key.x * grid_size + x, key.y * grid_size + z))
			surface.set_uv(_uv_of(key, points[x + z * n]))
			surface.add_vertex(points[x + z * n])
	# With shared vertices, a triangle is three vertex numbers instead of three positions. This is the same a-b-c and
	# b-d-c split as _chunk_triangles.
	for z in grid_size:
		for x in grid_size:
			var a := x + z * n
			var b := a + 1
			var c := a + n
			var d := c + 1
			surface.add_index(a)
			surface.add_index(b)
			surface.add_index(c)
			surface.add_index(b)
			surface.add_index(d)
			surface.add_index(c)


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


# --- Building: what you stand on, and what nav walks on ---


## Sends a chunk's triangles to collision and nav together, so they can't disagree.
func _rebuild_solid(key: Vector2i) -> void:
	var triangles := _chunk_triangles(key)
	if build_collision and not Engine.is_editor_hint():
		_rebuild_collision(key, triangles)
	if _nav and _nav_layer >= 0:
		# Nav works in world positions, so it's told where this node is. If the node moves later, nav won't know until
		# the next generate() or edit().
		_nav.submit_mesh(_nav_layer, _nav_mesh_id(key), triangles, global_transform)


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


func _connect_to_nav() -> void:
	# No hooks means nav isn't wanted. The editor preview never uses it either.
	if nav_hooks == null or Engine.is_editor_hint():
		return
	if not Engine.has_singleton("NavServer"):
		push_warning("HeightmapTerrain: nav_hooks is set, but the nav library isn't loaded. Nav won't see this terrain.")
		return
	_nav = Engine.get_singleton("NavServer")
	# Mesh input, not heightmap input: nav's heightmap input needs a regular grid, and jitter moves the points off it.
	# Measured 2026-11-05 on 25 chunks of 1 m squares: the first build takes about the same as heightmap input (about
	# 95 ms against 90 ms), and rebuilding after an edit takes about twice as long (17 ms against 8 ms).
	var adapter := ClassDB.class_get_integer_constant("NavServer", "ADAPTER_MESH")
	_nav_layer = _nav.add_input_layer(self, nav_hooks, adapter)


# --- Markers: telling NavWorld what's in each chunk ---
# Claude 2026-11-06: added for nav spec section 21.6. NavWorld is plain GDScript, so all of this works without the
# nav library. It stays out of the editor preview, because the autoload only exists while the game runs.


## Gives NavWorld a copy of this terrain's settings, and gets the id its chunks' markers use.
func _register_with_nav_world() -> void:
	if Engine.is_editor_hint() or not is_inside_tree():
		return
	_terrain_id = NavWorld.register_terrain(str(get_path()), _make_nav_settings())


func _make_nav_settings() -> NavTerrainSettings:
	var settings := NavTerrainSettings.new()
	settings.origin = _terrain_origin()
	settings.tile_size = tile_size
	settings.grid_size = grid_size
	settings.height_scale = height_scale
	settings.noise_seed = noise_seed
	settings.noise_scale = noise_scale
	settings.noise_type = noise_type
	settings.frequency = frequency
	settings.fractal_type = fractal_type
	settings.fractal_octaves = fractal_octaves
	settings.fractal_gain = fractal_gain
	settings.fractal_lacunarity = fractal_lacunarity
	return settings


## Replaces whatever this chunk has announced with a fresh list. Takes effect on NavWorld's next tick.
func _announce_markers(key: Vector2i) -> void:
	if _terrain_id == 0:
		return
	NavWorld.release_markers(_terrain_id, key)
	var markers := _make_chunk_markers(key)
	if markers.is_empty():
		return
	if String(name).begins_with("@"):
		push_warning("HeightmapTerrain: %s has an automatic name, so machines may disagree on its marker ids. Give it a name of its own." % get_path())
	var origin := _terrain_origin()
	for marker in markers:
		if marker != null: # NavWorld refuses a null one and warns, so it's left in the list for that
			marker.position += origin
	NavWorld.request_markers(_terrain_id, key, markers)


func _release_all_markers() -> void:
	if _terrain_id == 0:
		return
	for key in _points:
		NavWorld.release_markers(_terrain_id, key)


## Nav knows each mesh by one number, so this packs the chunk's two grid numbers into one. Adding 2^20 keeps negative
## chunk numbers positive, and "<<" slides the first number along so the two don't overlap.
func _nav_mesh_id(key: Vector2i) -> int:
	return ((key.x + (1 << 20)) << 21) | (key.y + (1 << 20))


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
	var key := Vector2i(floori(float(square_x) / grid_size), floori(float(square_z) / grid_size))
	if not _points.has(key):
		return NO_GROUND
	var points: PackedVector3Array = _points[key]
	var n := _points_per_edge()
	# posmod is a remainder that stays positive for negative numbers, which gives the square's number within its chunk.
	var local_x := posmod(square_x, grid_size)
	var local_z := posmod(square_z, grid_size)
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


func _clear() -> void:
	# GDScript note: values() gives every value in a Dictionary as a list.
	for mesh_node in _mesh_nodes.values():
		remove_child(mesh_node)
		mesh_node.queue_free() # queue_free deletes a node safely at the end of the frame
	for collision_node in _collision_nodes.values():
		var body: Node = collision_node.get_parent()
		remove_child(body)
		body.queue_free()
	if _nav and _nav_layer >= 0:
		for key in _points:
			_nav.remove_mesh(_nav_layer, _nav_mesh_id(key))
	_release_all_markers()
	_mesh_nodes.clear()
	_collision_nodes.clear()
	_points.clear()


# The sliders stop bad values in the inspector, but code can still set them. Carry on with something sensible rather
# than crashing or dividing by zero.
func _fix_bad_settings() -> void:
	if grid_size < 1:
		push_warning("HeightmapTerrain: grid_size must be at least 1. Using 1.")
		grid_size = 1
	if tile_size <= 0.0:
		push_warning("HeightmapTerrain: tile_size must be above 0. Using 1.")
		tile_size = 1.0
	if chunk_radius < 0:
		push_warning("HeightmapTerrain: chunk_radius can't be negative. Using 0.")
		chunk_radius = 0
	if grid_jitter < 0.0 or grid_jitter > 1.0:
		push_warning("HeightmapTerrain: grid_jitter must be from 0 to 1. Using the nearest allowed value.")
		grid_jitter = clampf(grid_jitter, 0.0, 1.0)


func _points_per_edge() -> int:
	return grid_size + 1


func _square_size() -> float:
	return tile_size / grid_size


## A grid point from its number across the whole world. If that chunk isn't built, this works out where the point would
## be, so the outer edge of the terrain and a single tile are lit like part of a larger world.
func _point_at(world_x_number: int, world_z_number: int) -> Vector3:
	var key := Vector2i(floori(float(world_x_number) / grid_size), floori(float(world_z_number) / grid_size))
	if not _points.has(key):
		return _make_point(world_x_number, world_z_number)
	var index := posmod(world_x_number, grid_size) + posmod(world_z_number, grid_size) * _points_per_edge()
	return _points[key][index]


## UVs come from the position within the chunk, so a texture lines up across borders even when points are shifted.
func _uv_of(key: Vector2i, point: Vector3) -> Vector2:
	return Vector2(point.x - key.x * tile_size, point.z - key.y * tile_size) / tile_size * uv_scale


# Asking for a global position outside the scene is an error, so treat that case as the world origin.
func _terrain_origin() -> Vector3:
	return global_position if is_inside_tree() else Vector3.ZERO
