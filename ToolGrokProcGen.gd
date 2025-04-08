@tool
extends MeshInstance3D

@export var size: int = 50
@export var tile_size: float = 2.0
@export var lenght_scale: float = 0.5  # Can be same as tile size, < 1 is "zoomed in"
@export var width_scale: float = 0.5   # Can be same as tile size, < 1 is "zoomed in"
@export var height_scale: float = 3.0
@export var noise_seed: int = 135
@export var cellular_jitter: float = 0.0

# Add a button to the Inspector to manually trigger mesh generation
@export var regenerate: bool:
	set(_value):
		if Engine.is_editor_hint():
			generate_terrain()

var noise: FastNoiseLite

func _ready():
	if Engine.is_editor_hint():
		initialize_noise()
		generate_terrain()
	else:
		initialize_noise()
		generate_terrain()

func initialize_noise():
	noise = FastNoiseLite.new()
	noise.seed = noise_seed
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	noise.frequency = 0.1
	noise.fractal_octaves = 3
	noise.fractal_gain = 0.5

func _set(property: StringName, value: Variant) -> bool:
	var changed = false
	match property:
		"size", "tile_size", "lenght_scale", "width_scale", "height_scale", "noise_seed", "cellular_jitter":
			changed = true
			set(property, value)
	if changed and Engine.is_editor_hint():
		initialize_noise()
		generate_terrain()
	return changed

func generate_terrain():
	# Generate height map
	var height_map = generate_height_map()
	var new_mesh = ArrayMesh.new()
	var shadow_mesh = ArrayMesh.new()
	var arrays = []
	arrays.resize(Mesh.ARRAY_MAX)
	
	# Initialize arrays
	var vertices = PackedVector3Array()
	var normals = PackedVector3Array()
	var indices = PackedInt32Array()
	var uvs = PackedVector2Array()
	var uvs2 = PackedVector2Array()
	
	# Generate vertices
	for x in range(size + 1):
		for z in range(size + 1):
			var y = height_map[x][z]
			vertices.append(Vector3(x * tile_size, y * tile_size, z * tile_size))
			uvs.append(Vector2(x / float(size), z / float(size)))
			uvs2.append(Vector2(x / float(size), z / float(size)))
	
	# Generate indices (counterclockwise winding)
	for x in range(size):
		for z in range(size):
			var v0 = x + z * (size + 1)
			var v1 = v0 + 1
			var v2 = v0 + (size + 1)
			var v3 = v2 + 1
			# Triangle 1: v0 -> v2 -> v1
			indices.append(v0)
			indices.append(v2)
			indices.append(v1)
			# Triangle 2: v1 -> v2 -> v3
			indices.append(v1)
			indices.append(v2)
			indices.append(v3)
	

	# Initialize normals with zeros
	normals.resize(vertices.size())
	for i in range(normals.size()):
		normals[i] = Vector3.ZERO
	
	# Compute angle-weighted normals with area contribution
	for i in range(0, indices.size(), 3):
		var i0 = indices[i]
		var i1 = indices[i + 1]
		var i2 = indices[i + 2]
		var v0 = vertices[i0]
		var v1 = vertices[i1]
		var v2 = vertices[i2]
		
		# Triangle edges
		var edge0 = v1 - v0
		var edge1 = v2 - v0
		var edge2 = v2 - v1
		
		# Face normal (unnormalized, magnitude reflects area)
		var face_normal = edge0.cross(edge1)
		
		# Compute angles at each vertex
		var angle0 = acos(edge0.normalized().dot(edge1.normalized()))
		var angle1 = acos((-edge0.normalized()).dot(edge2.normalized()))
		var angle2 = acos(edge1.normalized().dot(edge2.normalized()))
		
		# Accumulate weighted normals (area * angle)
		normals[i0] += face_normal * angle0
		normals[i1] += face_normal * angle1
		normals[i2] += face_normal * angle2
	
	# First normalization pass
	for i in range(normals.size()):
		if normals[i] != Vector3.ZERO:
			normals[i] = normals[i].normalized()
		else:
			normals[i] = Vector3(0, 1, 0)  # Fallback for degenerate cases
	
	# Smoothing pass: average with neighboring vertices
	var smoothed_normals = PackedVector3Array()
	smoothed_normals.resize(vertices.size())
	for x in range(size + 1):
		for z in range(size + 1):
			var idx = x + z * (size + 1)
			var normal_sum = normals[idx]
			var count = 1.0
			
			# Add neighboring normals (if they exist)
			if x > 0:
				normal_sum += normals[(x-1) + z * (size + 1)]
				count += 1.0
			if x < size:
				normal_sum += normals[(x+1) + z * (size + 1)]
				count += 1.0
			if z > 0:
				normal_sum += normals[x + (z-1) * (size + 1)]
				count += 1.0
			if z < size:
				normal_sum += normals[x + (z+1) * (size + 1)]
				count += 1.0
			
			# Average and normalize
			smoothed_normals[idx] = (normal_sum / count).normalized()
	
	
	# Assign arrays to mesh
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = smoothed_normals
	shadow_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	arrays[Mesh.ARRAY_INDEX] = indices
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_TEX_UV2] = uvs2
	
	new_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var placeholder_material = self.mesh.surface_get_material(0) if self.mesh else null
	self.mesh = new_mesh
	self.mesh.shadow_mesh = shadow_mesh
	if placeholder_material:
		self.mesh.surface_set_material(0, placeholder_material)
		placeholder_material.cull_mode = StandardMaterial3D.CULL_BACK

func generate_height_map() -> Array:
	var height_map = []
	for x in range(size + 1):
		height_map.append([])
		for z in range(size + 1):
			var height = noise.get_noise_2d(x * lenght_scale, z * width_scale)
			height = (height + 1) / 2 * height_scale
			height_map[x].append(height)
	return height_map



func _get_configuration_warnings() -> PackedStringArray:
	var warnings = PackedStringArray()
	if size < 1:
		warnings.append("Size must be at least 1 for terrain generation.")
	if tile_size <= 0:
		warnings.append("Tile size must be positive.")
	return warnings
