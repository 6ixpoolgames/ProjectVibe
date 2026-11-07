## Written by Claude (claude-opus-5-5), 2026-11-06: marks something as keeping the world loaded around it. "Streaming
## source" is the usual name for this in game engines. It does nothing by itself: a ChunkStreamer finds every source
## and loads chunks around the active ones.
##
## How to use it: add this node as a child of whatever should keep the world loaded, such as a pawn or an RTS camera.
## It follows its parent because it's a Node3D, so it needs no code. Turn "active" off when that thing shouldn't count.
##
## It's a node of its own, not a setting on the controller, so that things without a pawn controller can use it too.
## Claude 2026-11-07: Pawn makes its own while a player possesses it, or while its ai_loads_chunks bool is on.
##
## In multiplayer, a source on a networked entity counts only where it should, with no setup needed:
##   - On the server, or offline: it counts, so the world stays loaded around every player, wherever they are.
##   - On a client: only on that client's own pawn. Another player's pawn doesn't make this machine load the world around it.
## Anything that isn't a networked entity, such as a camera, always counts on the machine it's on.
##
## What happens in odd cases (all checked in tests/chunk_streaming_selftest.gd):
##   - No ChunkStreamer in the scene: nothing happens, and nothing breaks.
##   - Removed from the scene or freed: it stops counting by itself, at the streamer's next refresh.
class_name StreamingSource
extends Node3D

## The name of the Godot group every source joins, which is how a ChunkStreamer finds them.
const GROUP := &"streaming_sources"

## Whether this source keeps the world loaded right now. It can be changed at any time.
@export var active := true
## Chunks within this distance are loaded, in metres, measured to the nearest edge of the chunk.
@export_range(0.0, 2000.0, 1.0, "or_greater") var load_distance := 320.0
## Nav is built within this distance, in metres. It's separate because nav has about 100 tiles per chunk at 128 m, so
## building it as far out as the ground would be slow. 0 means this source builds no nav. It can't exceed load_distance.
@export_range(0.0, 2000.0, 1.0, "or_greater") var nav_distance := 128.0

var _network_entity: NetworkEntity = null
var _last_checked_position := Vector3.ZERO
var _has_been_checked := false


# GDScript note: _init runs when the object is made, before it's in a scene. A node keeps its groups when it leaves the
# scene and comes back, so joining once here is enough.
func _init() -> void:
	add_to_group(GROUP)


## Whether this source should load chunks on this machine right now. ChunkStreamer asks this at every refresh.
# Claude 2026-11-07: added for multiplayer streaming. A pawn exists on every machine, so "active" alone would make each
# client load the world around every other player.
func counts_on_this_machine() -> bool:
	if not active or not is_inside_tree():
		return false
	var entity := _find_network_entity()
	if entity == null:
		return true
	return entity.role == NetworkEntity.Role.AUTHORITY or entity.is_local


## How far this has moved since the streamer last asked. The streamer uses it to judge how soon a chunk edge will be reached.
# A first call says 0, because arriving somewhere isn't moving. The chunk it's over gets built regardless.
func distance_moved_since_last_check() -> float:
	var at := global_position
	var moved := at.distance_to(_last_checked_position) if _has_been_checked else 0.0
	_last_checked_position = at
	_has_been_checked = true
	return moved


## The NetworkEntity of whatever this source is attached to, or null if it isn't on a networked entity.
func _find_network_entity() -> NetworkEntity:
	if is_instance_valid(_network_entity):
		return _network_entity
	var node: Node = get_parent()
	while node != null:
		# NetworkEntity marks its parent with this when it's set up.
		if node.has_meta(&"network_entity"):
			_network_entity = node.get_meta(&"network_entity")
			return _network_entity
		node = node.get_parent()
	return null
