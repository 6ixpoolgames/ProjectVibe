## Written by Claude (claude-opus-5-5), 2026-11-03: chunked, editable heightmap terrain for testing the nav system.
## Not a replacement for procgen_tile.gd. It exists to exercise NavHooks (spec 5.1): seamless chunks
## (heights come from world positions, so neighbours share edge rows exactly) and live edits.
## It also builds a test course: a flat plaza in the middle and a 3 m wall with a narrow gap,
## so the clearance tiers are easy to see (small pawns fit through the gap, big ones go around).
class_name NavTestTerrain
extends Node3D

@export var nav_hooks: NavHooks ## leave empty = this terrain is invisible to nav
@export var chunk_radius := 2 ## builds (2r+1)^2 chunks around the origin
@export var quads_per_chunk := 32
@export var spacing := 1.0
@export var height_scale := 10.0
@export var noise_seed := 250
@export_range(0.001, 0.5, 0.001) var frequency := 0.015
@export_range(1, 8) var octaves := 4
@export var build_test_wall := true

var _noise := FastNoiseLite.new()
var _heights := {} # Vector2i -> PackedFloat32Array, (quads_per_chunk + 1)^2 samples
var _mesh_nodes := {} # Vector2i -> MeshInstance3D
var _nav_layer := -1
var _material := StandardMaterial3D.new()


func _ready() -> void:
	_noise.seed = noise_seed
	_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_noise.frequency = frequency
	_noise.fractal_octaves = octaves
	_material.albedo_color = Color(0.46, 0.43, 0.37)
	_material.roughness = 1.0

	if nav_hooks:
		_nav_layer = NavServer.add_input_layer(self, nav_hooks, NavServer.ADAPTER_HEIGHTMAP)

	for cz in range(-chunk_radius, chunk_radius + 1):
		for cx in range(-chunk_radius, chunk_radius + 1):
			_generate_chunk(Vector2i(cx, cz))


func _exit_tree() -> void:
	if nav_hooks and _nav_layer >= 0:
		NavServer.remove_input_layer(_nav_layer)


func samples_per_edge() -> int:
	return quads_per_chunk + 1


func chunk_world() -> float:
	return quads_per_chunk * spacing


## Height at a world position, using the same two triangles per square as the mesh and the nav system.
func height_at(wx: float, wz: float) -> float:
	var key := Vector2i(floori(wx / chunk_world()), floori(wz / chunk_world()))
	if not _heights.has(key):
		return 0.0
	var h: PackedFloat32Array = _heights[key]
	var n := samples_per_edge()
	var fx := (wx - key.x * chunk_world()) / spacing
	var fz := (wz - key.y * chunk_world()) / spacing
	var ix := clampi(floori(fx), 0, n - 2)
	var iz := clampi(floori(fz), 0, n - 2)
	var u := clampf(fx - ix, 0.0, 1.0)
	var v := clampf(fz - iz, 0.0, 1.0)
	var a := h[ix + iz * n]
	var b := h[ix + 1 + iz * n]
	var c := h[ix + (iz + 1) * n]
	var d := h[ix + 1 + (iz + 1) * n]
	if u + v <= 1.0:
		return a + (b - a) * u + (c - a) * v
	return d + (c - d) * (1.0 - u) + (b - d) * (1.0 - v)


## Ray against the terrain by marching, then bisecting. Returns Vector3 or null.
func raycast(origin: Vector3, dir: Vector3, max_dist := 600.0) -> Variant:
	var step := spacing * 0.25
	var prev := origin
	var t := 0.0
	while t < max_dist:
		t += step
		var p := origin + dir * t
		if p.y <= height_at(p.x, p.z):
			var lo := prev
			var hi := p
			for i in 12:
				var mid := (lo + hi) * 0.5
				if mid.y <= height_at(mid.x, mid.z):
					hi = mid
				else:
					lo = mid
			return hi
		prev = p
	return null


## Raise (amount > 0) or dig (amount < 0) a round patch, then resubmit only what changed.
func edit(center: Vector3, radius: float, amount: float) -> void:
	var n := samples_per_edge()
	var cw := chunk_world()
	for key in _heights.keys():
		var origin := Vector2(key.x * cw, key.y * cw)
		if center.x + radius < origin.x or center.x - radius > origin.x + cw:
			continue
		if center.z + radius < origin.y or center.z - radius > origin.y + cw:
			continue
		var h: PackedFloat32Array = _heights[key]
		var touched := false
		for z in n:
			for x in n:
				var d := Vector2(origin.x + x * spacing - center.x, origin.y + z * spacing - center.z).length()
				if d < radius:
					h[x + z * n] += amount * (1.0 - smoothstep(radius * 0.5, radius, d))
					touched = true
		if touched:
			_heights[key] = h
			_rebuild_mesh(key)
			var r := radius + spacing
			_submit(key, AABB(Vector3(center.x - r, -1000.0, center.z - r), Vector3(2.0 * r, 2000.0, 2.0 * r)))


func _base_height(wx: float, wz: float) -> float:
	# Flat plaza within ~10 m of the origin, rolling noise further out.
	var flat := smoothstep(10.0, 30.0, Vector2(wx, wz).length())
	var y := _noise.get_noise_2d(wx, wz) * height_scale * flat
	if build_test_wall and absf(wz - 9.0) <= 1.0 and absf(wx) >= 2.0 and absf(wx) <= 40.0:
		y += 3.0 # wall along x at z = 8..10, with a gap of about 2 m at x = 0
	return y


func _generate_chunk(key: Vector2i) -> void:
	var n := samples_per_edge()
	var h := PackedFloat32Array()
	h.resize(n * n)
	for z in n:
		for x in n:
			h[x + z * n] = _base_height(key.x * chunk_world() + x * spacing, key.y * chunk_world() + z * spacing)
	_heights[key] = h
	_rebuild_mesh(key)
	_submit(key, AABB())


func _submit(key: Vector2i, dirty_bounds: AABB) -> void:
	if nav_hooks:
		var n := samples_per_edge()
		NavServer.submit_heightmap(_nav_layer, key, _heights[key], Vector2i(n, n), spacing, PackedByteArray(), dirty_bounds)


func _rebuild_mesh(key: Vector2i) -> void:
	var n := samples_per_edge()
	var h: PackedFloat32Array = _heights[key]
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for z in n:
		for x in n:
			st.add_vertex(Vector3(key.x * chunk_world() + x * spacing, h[x + z * n], key.y * chunk_world() + z * spacing))
	for z in n - 1:
		for x in n - 1:
			var a := z * n + x # a --- b   same split as procgen_tile.gd
			var b := a + 1 #     |  /  |   and as HeightChunk::height_at in C++
			var c := a + n #     c --- d
			var d := c + 1
			st.add_index(a); st.add_index(b); st.add_index(c)
			st.add_index(b); st.add_index(d); st.add_index(c)
	st.generate_normals()
	var mi: MeshInstance3D = _mesh_nodes.get(key)
	if mi == null:
		mi = MeshInstance3D.new()
		mi.material_override = _material
		add_child(mi)
		_mesh_nodes[key] = mi
	mi.mesh = st.commit()
