## Written by Claude (claude-opus-5-5), 2026-11-15: replay channel 4, "world": the loaded ground and what keeps it loaded (replay spec
## section 3). For seeing a pawn standing on a chunk that went away.
##
## Events (the pawn id is 0 for all of them):
##   "chunk_built"     data: terrain (its id here), chunk (Vector2i)       a terrain finished building a chunk
##   "chunk_collision" data: terrain, chunk                                its collision is in, so things can stand on it
##   "chunk_removed"   data: terrain, chunk
##   "source_added", "source_removed"
##                     data: source (its id here), position, load, nav    a chunk source started or stopped keeping the world loaded
##                     here. Claude 2026-11-16 (pawn M2): pawns are sources now, so only those that count on this machine are tracked
##                     (counts_on_this_machine), and a source switched off is "source_removed". "source_on" and "source_off"
##                     are still read in older recordings.
## A keyframe's snapshot: every terrain (id, name, chunk size, origin, built chunks) and every source (id, position, load and nav
## distances, on or off, and whether it counts on this machine).
##
## Reading: state["terrains"] is terrain id -> {name, chunk_size, origin, chunks: {Vector2i: true}}, and state["sources"] is source
## id -> {position, load, nav, active, counts}. Source positions are updated only by keyframes and their own events, so a moving
## source (a player's pawn, say) is up to a second out of date; the pawn's own motion record has the exact place.
class_name ReplayWorldChannel
extends ReplayEventChannel

const ID := 4

var _terrains: Array[TerrainGenerator] = [] # a terrain's id here is its index + 1
var _sources := {} # source instance id -> [source id here, the source (a StreamingSource or a Pawn)]
var _next_source_id := 1


func _init() -> void:
	channel_id = ID
	channel_name = "world"
	version = 1


func begin(for_recorder: ReplayRecorder) -> void:
	super(for_recorder)
	_find_terrains()


func end() -> void:
	for terrain in _terrains:
		if is_instance_valid(terrain):
			for connection in [[terrain.chunk_built, _on_chunk_built], [terrain.collision_built, _on_collision_built],
					[terrain.chunk_removed, _on_chunk_removed]]:
				if connection[0].is_connected(connection[1]):
					connection[0].disconnect(connection[1])
	_terrains.clear()
	_sources.clear()
	super()


func write_tick(tick: int, out: StreamPeerBuffer, keyframe: bool) -> void:
	_find_terrains()
	_check_sources()
	super(tick, out, keyframe)


func snapshot() -> Dictionary:
	var terrains := {}
	for i in _terrains.size():
		var terrain := _terrains[i]
		if is_instance_valid(terrain):
			terrains[i + 1] = {"name": String(terrain.name), "chunk_size": terrain.chunk_size, "origin": terrain.global_position,
				"chunks": terrain.get_loaded_chunks()}
	var sources := {}
	for entry: Array in _sources.values():
		var source: Node3D = entry[1]
		if is_instance_valid(source):
			sources[entry[0]] = _describe_source(source)
	return {"terrains": terrains, "sources": sources}


func read_snapshot(shot: Dictionary, state: Dictionary) -> void:
	var terrains := {}
	for id: int in shot.get("terrains", {}):
		var info: Dictionary = shot.terrains[id].duplicate()
		var chunks := {}
		for key: Vector2i in info.get("chunks", []):
			chunks[key] = true
		info["chunks"] = chunks
		terrains[id] = info
	state["terrains"] = terrains
	state["sources"] = (shot.get("sources", {}) as Dictionary).duplicate()


func apply_event(event: Dictionary, state: Dictionary) -> void:
	if not state.has("terrains"):
		state["terrains"] = {}
		state["sources"] = {}
	var data: Dictionary = event.data
	match event.kind:
		"chunk_built", "chunk_collision":
			var terrain: Variant = state.terrains.get(data.get("terrain"))
			if terrain != null:
				terrain.chunks[data.chunk] = true
		"chunk_removed":
			var terrain: Variant = state.terrains.get(data.get("terrain"))
			if terrain != null:
				terrain.chunks.erase(data.chunk)
		"source_added", "source_on", "source_off":
			state.sources[data.source] = data
		"source_removed":
			state.sources.erase(data.source)


func copy_state(state: Dictionary) -> Dictionary:
	var copy := state.duplicate()
	if state.has("terrains"):
		var terrains := {}
		for id: int in state.terrains:
			var info: Dictionary = state.terrains[id].duplicate()
			info["chunks"] = (info.chunks as Dictionary).duplicate() # changed in place by apply_event, so copied too
			terrains[id] = info
		copy["terrains"] = terrains
		copy["sources"] = (state.sources as Dictionary).duplicate()
	return copy


# Terrains can arrive after recording starts, so this looks again each tick. Cheap: one group lookup.
func _find_terrains() -> void:
	if recorder == null or not recorder.is_inside_tree():
		return
	for node in recorder.get_tree().get_nodes_in_group(TerrainGenerator.GROUP):
		var terrain := node as TerrainGenerator
		if terrain == null or _terrains.has(terrain):
			continue
		_terrains.append(terrain)
		var id := _terrains.size()
		# GDScript note: bind() adds the terrain's id to every call, after the signal's own arguments.
		terrain.chunk_built.connect(_on_chunk_built.bind(id))
		terrain.collision_built.connect(_on_collision_built.bind(id))
		terrain.chunk_removed.connect(_on_chunk_removed.bind(id))


func _on_chunk_built(key: Vector2i, _triangles: PackedVector3Array, terrain_id: int) -> void:
	add_event("chunk_built", 0, {"terrain": terrain_id, "chunk": key})


func _on_collision_built(key: Vector2i, _shape: CollisionShape3D, terrain_id: int) -> void:
	add_event("chunk_collision", 0, {"terrain": terrain_id, "chunk": key})


func _on_chunk_removed(key: Vector2i, terrain_id: int) -> void:
	add_event("chunk_removed", 0, {"terrain": terrain_id, "chunk": key})


# Sources have no signals, so each tick this compares them with last tick: new ones, gone ones, and ones switched on or off.
func _check_sources() -> void:
	if recorder == null or not recorder.is_inside_tree():
		return
	var seen := {}
	for node in recorder.get_tree().get_nodes_in_group(StreamingSource.GROUP):
		var source := node as Node3D
		if source == null or not source.counts_on_this_machine():
			continue
		var key := source.get_instance_id()
		seen[key] = true
		if not _sources.has(key):
			_sources[key] = [_next_source_id, source]
			_next_source_id += 1
			add_event("source_added", 0, _describe_source(source))
	for key: int in _sources.keys():
		if not seen.has(key):
			var gone: Array = _sources[key]
			_sources.erase(key)
			add_event("source_removed", 0, {"source": gone[0]})


func _describe_source(source: Node3D) -> Dictionary:
	var entry: Variant = _sources.get(source.get_instance_id())
	return {"source": entry[0] if entry != null else 0, "position": source.global_position, "load": source.load_distance,
		"nav": source.nav_distance, "active": true, "counts": true}
