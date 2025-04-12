extends MeshInstance3D

@export	var size: int = 50
@export var tile_size: float = 2.0
@export var lenght_scale: float = 0.5 #can be same as tile size, < 1 is "zoomed in"
@export var width_scale: float = 0.5 #can be same as tile size, < 1 is "zoomed in"
@export var height_scale: float = 3.0
@export var noise_seed: int = 135
@export var cellular_jitter: float = 0.0

var noise : FastNoiseLite

func _ready():
	
	noise = FastNoiseLite.new()
	noise.seed = noise_seed
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	noise.frequency = 0.1
	noise.fractal_octaves = 3
	noise.fractal_gain = 0.5
	
	generate_terrain()
	
func generate_height_map() -> Array:
	var height_map = []
	for x in range(size+1):
		height_map.append([])
		for z in range(size+1):
			var height = noise.get_noise_2d(x*lenght_scale,z*width_scale)
			height = (height+1)/2*height_scale
			height_map[x].append(height)
	return height_map
		
func generate_terrain():
	var height_map = generate_height_map()
	var mesh = ArrayMesh.new()
	var arrays = []
	arrays.resize(Mesh.ARRAY_MAX)
	
	var vertices = PackedVector3Array()
	var normals = PackedVector3Array()
	var indices = PackedInt32Array()
	var uvs = PackedVector2Array()
	var uvs2 = PackedVector2Array()
	
	#generate vertices with UVs
	for x in range(size+1):
		for z in range(size+1):
			var y = height_map[x][z]
			vertices.append(Vector3(x*tile_size,y*tile_size,z*tile_size))
			uvs.append(Vector2(x / float(size), z / float(size)))
			uvs2.append(Vector2(x / float(size), z / float(size)))
			
	#generate indices
	#for x in range(size):
	#	for z in range(size):
	#		var v0 = x + z * (size + 1)
	#		var v1 = v0 + 1
	#		var v2 = v0 + (size + 1)
	#		var v3 = v2 + 1
	#		indices.append(v0)
	#		indices.append(v2)
	#		indices.append(v1)
	#		indices.append(v1)
	#		indices.append(v2)
	#		indices.append(v3)
			
	#normals.resize(vertices.size())
	#for i in range(indices.size() / 3):
	#	var i0 = indices[i * 3]
	#	var i1 = indices[i*3 + 1]
	#	var i2 = indices[i*3 + 2]
	#	var normal = (vertices[i1] - vertices[i0]).cross(vertices[i2]-vertices[i0]).normalized()
	#	normals[i0] += normal
	#	normals[i1] += normal
	#	normals[i2] += normal
	##	
	#for i in range(normals.size()):
	#	normals[i] = normals[i].normalized()
	#
	
	# Generate indices
	for x in range(size):
		for z in range(size):
			var v0 = x + z * (size + 1)
			var v1 = v0 + 1
			var v2 = v0 + (size + 1)
			var v3 = v2 + 1
			indices.append(v0)
			indices.append(v2)
			indices.append(v1)
			indices.append(v1)
			indices.append(v2)
			indices.append(v3)
	
	# Initialize normals array with zeros
	normals.resize(vertices.size())
	for i in range(normals.size()):
		normals[i] = Vector3.ZERO
	
	# Calculate vertex normals (Substack method)
	for i in range(0, indices.size(), 3):  # Step by 3 for each triangle
		var i0 = indices[i]
		var i1 = indices[i + 1]
		var i2 = indices[i + 2]
		# Compute unnormalized face normal (magnitude proportional to area)
		var face_normal = (vertices[i1] - vertices[i0]).cross(vertices[i2] - vertices[i0])
		# Accumulate unnormalized normal for each vertex
		normals[i0] += face_normal
		normals[i1] += face_normal
		normals[i2] += face_normal
	
	# Normalize vertex normals after accumulation
	for i in range(normals.size()):
		if normals[i] != Vector3.ZERO:  # Avoid normalizing zero vectors
			normals[i] = normals[i].normalized()
		else:
			normals[i] = Vector3(0, 1, 0)  # Fallback for unused vertices (upward)	
			
			
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_INDEX] = indices
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_TEX_UV2] = uvs2
	
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var placeholder_material = self.mesh.surface_get_material(0) if self.mesh else null
	self.mesh = mesh  # Assign the procgen mesh
	if placeholder_material:
		mesh.surface_set_material(0, placeholder_material)  # Apply old material
	
	placeholder_material.cull_mode = StandardMaterial3D.CULL_BACK
	#placeholder_material.set_texture(StandardMaterial3D.TEXTURE_ALBEDO, load("res://assets/2d/grass.jpg"))
	#placeholder_material.set_texture(StandardMaterial3D.tex
