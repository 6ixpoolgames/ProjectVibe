extends MeshInstance3D


@export var size: int = 32
@export var tile_size: float = 1.0
@export var height_scale: float = 5.0
@export var noise_seed: int = 42

var noise: FastNoiseLite

func _ready():
	noise = FastNoiseLite.new()
	noise.seed = noise_seed
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	noise.frequency = 0.05
	noise.fractal_octaves = 4
	noise.fractal_gain = 0.5
	generate_terrain()

func generate_height_map() -> Array:
	var height_map = []
	for x in range(size + 1):
		height_map.append([])
		for z in range(size + 1):
			var height = noise.get_noise_2d(x * tile_size, z * tile_size)
			height = (height + 1) / 2 * height_scale
			height_map[x].append(height)
	return height_map

func flatten_height_map(height_map: Array) -> PackedFloat32Array:
	var flat = PackedFloat32Array()
	for x in range(size + 1):
		for z in range(size + 1):
			flat.append(height_map[x][z])
	return flat

func generate_terrain():
	var height_map = generate_height_map()
	var mesh = ArrayMesh.new()
	var arrays = []
	arrays.resize(Mesh.ARRAY_MAX)
	
	var vertices = PackedVector3Array()
	var normals = PackedVector3Array()
	var indices = PackedInt32Array()
	var uvs = PackedVector2Array()
	
	for x in range(size + 1):
		for z in range(size + 1):
			var y = height_map[x][z]
			vertices.append(Vector3(x * tile_size, y, z * tile_size))
			uvs.append(Vector2(x / float(size), z / float(size)))
	
	for x in range(size):
		for z in range(size):
			var v0 = x + z * (size + 1)  # Bottom-left
			var v1 = v0 + 1              # Bottom-right
			var v2 = v0 + (size + 1)     # Top-left
			var v3 = v2 + 1              # Top-right
			
			# First triangle (v0, v1, v2) - counterclockwise
			indices.append(v0)
			indices.append(v1)
			indices.append(v2)
			
			# Second triangle (v1, v3, v2) - counterclockwise
			indices.append(v1)
			indices.append(v3)
			indices.append(v2)
	
	normals.resize(vertices.size())
	for i in range(indices.size() / 3):
		var i0 = indices[i * 3]
		var i1 = indices[i * 3 + 1]
		var i2 = indices[i * 3 + 2]
		var normal = (vertices[i1] - vertices[i0]).cross(vertices[i2] - vertices[i0]).normalized()
		normals[i0] += normal
		normals[i1] += normal
		normals[i2] += normal
	
	for i in range(normals.size()):
		normals[i] = normals[i].normalized()
	
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_INDEX] = indices
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	self.mesh = mesh
	
	var material = StandardMaterial3D.new()
	material.albedo_color = Color(0.2, 0.8, 0.2)
	mesh.surface_set_material(0, material)
	
	# Add collision using flattened height map
	var flat_height_map = flatten_height_map(height_map)
	var shape = HeightMapShape3D.new()
	shape.map_width = size + 1
	shape.map_depth = size + 1
	shape.map_data = flat_height_map
	
	# Create a StaticBody3D for physics
	var static_body = StaticBody3D.new()
	var collision = CollisionShape3D.new()
	collision.shape = shape
	
	# Center the collision shape to match the mesh
	collision.position = Vector3(size * tile_size / 2.0, 0, size * tile_size / 2.0)
	
	static_body.add_child(collision)
	add_child(static_body)
