@tool
extends MeshInstance3D

signal terrain_collision_generated(terrainCollision)

@export var generate: bool = false:
	set(value):
		generate = true
		xSize = grid_size
		zSize = grid_size
		if Engine.is_editor_hint():
			print(atan2(1,1))
			generate_terrain_final()
			generate = false
@export var tile_size: float = 1.0
@export var grid_size: int = 24
var xSize: int = grid_size
var zSize: int = grid_size
@export var xScale: float = 1.0 #lateral scale
@export var zScale: float = 1.0 #depth Scale
@export var yScale: float = 1.0 #height Scale
@export var noise_seed: int = 250
@export_enum("Value", "Perlin", "Simplex", "Cellular") var noise_type: int = 2  # Noise algorithm to use
@export_range(0.001, 0.5, 0.001) var frequency: float = 0.1  # Base frequency of noise (lower = broader features, higher = more detail)
@export_range(1, 8, 1) var fractal_octaves: int = 3  # Number of noise layers (higher = more detailed, rugged terrain)
@export_range(0.0, 2.0, 0.1) var fractal_gain: float = 0.5  # Amplitude multiplier per octave (higher = sharper contrasts)
@export_range(0.0, 2.0, 0.1) var fractal_lacunarity: float = 2.0  # Frequency multiplier per octave (higher = finer details per layer)
@export_enum("FBM", "Billow", "Rigid") var fractal_type: int = 0
@export var slope_smoothing: float = 0.3 #max height diff to apply normals smoothing
@export var uv_scale: float = 1
@export var chunk_x: int
@export var chunk_z: int

@onready var procGenTile = $".." as StaticBody3D
@onready var terrainCollision = $"../TerrainCollision" as CollisionShape3D
var noise = FastNoiseLite.new()
var collisionShape = ConcavePolygonShape3D.new()
var heightMap: Array = []
var genMesh:ArrayMesh
var isThereTerrain: bool = false

var isReadyTrigger = false
func _ready():
	#if isThereTerrain == false:
	#	generate_terrain()
	#apply_collision_shape()
	generate_terrain_final()

func generate_terrain():
	generate_height_map()
	generate_mesh()	
	isThereTerrain = true
	
func generate_terrain_final():
	generate_terrain()
	apply_collision_shape()
	self.global_transform = procGenTile.global_transform
	terrainCollision.global_transform = procGenTile.global_transform
	
func apply_collision_shape():
	terrainCollision.shape = collisionShape
	print(terrainCollision)
	print(collisionShape)
	emit_signal("terrain_collision_generated", terrainCollision)
	print("TCG signal emitted")
	

func generate_noise():
	# Apply exported noise settings
	noise.seed = noise_seed
	noise.noise_type = noise_type  # 0=Value, 1=Perlin, 2=Simplex, 3=Cellular
	noise.frequency = frequency
	noise.fractal_octaves = fractal_octaves
	noise.fractal_gain = fractal_gain
	noise.fractal_lacunarity = fractal_lacunarity
	noise.fractal_type = fractal_type
	# Default fractal type is FBM (Fractional Brownian Motion), good for natural terrain

func generate_height_map():
	heightMap.clear()
	generate_noise()
	for z in range(zSize + 1):
		var row: Array = []
		for x in range(xSize + 1):
			var y = noise.get_noise_2d(x * xScale,z * zScale) * yScale
			row.append(y)
		heightMap.append(row)
	
func generate_mesh():
	var surfTool= SurfaceTool.new()
	surfTool.begin(Mesh.PRIMITIVE_TRIANGLES)
	
	for z in range(zSize+1):
		for x in range(xSize+1):
			var y = 0
			if not heightMap == []:
				y = heightMap[z][x]
		
			var uv = Vector2()
			uv.x = inverse_lerp(0,xSize,x)
			uv.y = inverse_lerp(0,zSize,z)
			surfTool.set_uv(uv)
			surfTool.add_vertex(Vector3(x * tile_size,y * tile_size,z * tile_size))
	
	#create tris
	var a: int        # Generic Square to Define as Triangle(abc) and Triangle(bdc)
	var b: int        #        a --- b
	var c: int        #        |  /  |
	var d: int        #        c --- d
	for z in range(zSize):
		for x in range(xSize):
			a = z * (xSize + 1) + x
			b = z * (xSize + 1) + x + 1
			c = (z + 1) * (xSize + 1) + x
			d = (z + 1) * (xSize + 1) + x + 1
			
			#Smooth only gentle slopes
			var height_diff = abs(heightMap[z][x] - heightMap[z+1][x+1])
			if height_diff < slope_smoothing:  # Threshold for smoothness
				surfTool.set_smooth_group(0)
			else:
				surfTool.set_smooth_group(-1)
			
			#tri 1
			surfTool.add_index(a)
			surfTool.add_index(b)
			surfTool.add_index(c)
			
			#tri 2
			surfTool.add_index(b)
			surfTool.add_index(d)
			surfTool.add_index(c)
	
	#surfTool.set_smooth_group(-1)
	surfTool.generate_normals()
	genMesh = surfTool.commit()
	collisionShape = genMesh.create_trimesh_shape()
	self.mesh = genMesh



func documentation() ->void:
	print("look inside")
#just some documentation on noise manipulation

"""
	noise_seed: int
		Description: Sets the random seed for the noise pattern.
		Effect: Changing the seed generates a completely different terrain layout. Use the same seed for consistent results (e.g., 42), or randomize it with randi() for variety.
	
	noise_type: int
		Options: 0 (Perlin), 1 (Simplex), 2 (Cellular), 3 (Value).
		Effect:
			Perlin: Produces smooth, organic noise—ideal for gentle hills.
			Simplex: Smoother and faster than Perlin, great for natural landscapes.
			Cellular: Creates cell-like patterns—useful for rocky or fractured terrain.
			Value: Simpler, less smooth noise—can appear blocky or artificial.
	
	frequency: float
		Range: 0.001 to 1.0.
		Effect: Controls the base scale of noise features. Lower values (e.g., 0.05) create broad, expansive hills; higher values (e.g., 0.2) produce smaller, more frequent bumps.
	
	fractal_octaves: int
		Range: 1 to 8.
		Effect: Sets the number of noise layers stacked together. Increasing this (e.g., 5) adds finer details, making the terrain more rugged and complex; fewer octaves (e.g., 2) keep it smoother.
	
	fractal_lacunarity: float
		Range: 0.1 to 4.0.
		Effect: Determines how much the frequency increases with each octave. Higher values (e.g., 3.0) make successive layers have smaller, tighter features, enhancing detail; lower values (e.g., 1.5) keep features more uniform.
	
	fractal_gain: float
		Range: 0.1 to 2.0.
		Effect: Adjusts the strength (amplitude) of each octave. Lower values (e.g., 0.3) reduce the impact of higher-frequency details, smoothing the terrain; higher values (e.g., 0.8) emphasize details, making it rougher.
	
	fractal_type: int
		Options: 0 (FBM), 1 (Billow), 2 (Rigid).
		Effect:
			FBM (Fractional Brownian Motion): Standard layering for smooth, natural hills.
			Billow: Produces rounded, cloud-like peaks—good for softer terrain.
			Rigid: Inverts noise for sharp ridges and canyons—ideal for mountains.

Additional Parameters

	noise_scale: float
		Effect: Scales the input coordinates before sampling noise. Higher values (e.g., 2.0) “zoom out,” making features larger; lower values (e.g., 0.5) “zoom in,” making them smaller and more detailed.
	
	height_scale: float
		Effect: Multiplies the noise output to control terrain height. Increase (e.g., 10.0) for taller peaks and deeper valleys; decrease (e.g., 2.0) for flatter terrain.
"""
