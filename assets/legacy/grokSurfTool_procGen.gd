@tool
extends MeshInstance3D

@export var tile_size: float = 1.0
@export var grid_size: int = 24
var xSize: int = grid_size
var zSize: int = grid_size
@export var xScale: float = 1.0  # Lateral scale
@export var zScale: float = 1.0  # Depth scale
@export var yScale: float = 1.0  # Height scale
@export var noise_seed: int = 250
@export_enum("Value", "Perlin", "Simplex", "Cellular") var noise_type: int = 2
@export_range(0.001, 0.5, 0.001) var frequency: float = 0.1
@export_range(1, 8, 1) var fractal_octaves: int = 3
@export_range(0.0, 2.0, 0.1) var fractal_gain: float = 0.5
@export_range(0.0, 2.0, 0.1) var fractal_lacunarity: float = 2.0
@export var uv_scale: float = 1.0
@export var generate: bool = false:
	set(value):
		generate = true
		if Engine.is_editor_hint():
			xSize = grid_size
			zSize = grid_size
			generate_terrain()
			generate = false

@onready var collisionMesh = $"../TerrainCollision" as CollisionShape3D  # Adjust path if needed
var noise = FastNoiseLite.new()
var collisionShape = ConcavePolygonShape3D.new()
var heightMap: Array = []
var isThereTerrain: bool = false

func _ready():
	if not isThereTerrain:
		generate_terrain()

func generate_terrain():
	generate_height_map()
	generate_mesh()
	apply_collision_shape()
	isThereTerrain = true

func apply_collision_shape():
	collisionMesh.shape = collisionShape

func generate_noise():
	noise.seed = noise_seed
	noise.noise_type = noise_type
	noise.frequency = frequency
	noise.fractal_octaves = fractal_octaves
	noise.fractal_gain = fractal_gain
	noise.fractal_lacunarity = fractal_lacunarity

func generate_height_map():
	heightMap.clear()
	generate_noise()
	for z in range(zSize + 1):
		var row: Array = []
		for x in range(xSize + 1):
			var y = noise.get_noise_2d(x * xScale, z * zScale) * yScale
			row.append(y)
		heightMap.append(row)

func generate_mesh():
	var surfTool = SurfaceTool.new()
	surfTool.begin(Mesh.PRIMITIVE_TRIANGLES)

	for z in range(zSize + 1):
		for x in range(xSize + 1):
			var y = heightMap[z][x]
			var uv = Vector2(x / float(xSize) * uv_scale, z / float(zSize) * uv_scale)
			surfTool.add_uv(uv)
			surfTool.set_smooth_group(-1)
			surfTool.add_vertex(Vector3(x * tile_size, y, z * tile_size))

	var collisionFaces = PackedVector3Array()
	for z in range(zSize):
		for x in range(xSize):
			var a = z * (xSize + 1) + x
			var b = z * (xSize + 1) + x + 1
			var c = (z + 1) * (xSize + 1) + x
			var d = (z + 1) * (xSize + 1) + x + 1

			# Triangle 1: a, b, c
			surfTool.add_index(a)
			surfTool.add_index(b)
			surfTool.add_index(c)
			collisionFaces.append(surfTool.get_vertex(a))
			collisionFaces.append(surfTool.get_vertex(b))
			collisionFaces.append(surfTool.get_vertex(c))

			# Triangle 2: b, d, c
			surfTool.add_index(b)
			surfTool.add_index(d)
			surfTool.add_index(c)
			collisionFaces.append(surfTool.get_vertex(b))
			collisionFaces.append(surfTool.get_vertex(d))
			collisionFaces.append(surfTool.get_vertex(c))

	surfTool.generate_normals()
	self.mesh = surfTool.commit()
	collisionShape.set_faces(collisionFaces)
