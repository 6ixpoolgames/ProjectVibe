# Written by Claude (claude-opus-5-5), 2026-11-06. History: streaming/CHANGELOG.md.
## Marks something as keeping the world loaded around it.
##
## A [ChunkStreamer] finds every source and loads chunks around the active ones. Add this as a child of whatever should keep the world
## loaded (an RTS camera, a spawner); it follows its parent, so it needs no code. Turn [member active] off when it shouldn't count. A
## pawn's is a [PawnStreamingSource], a default part, which counts while a player has the pawn.
## [br]
## [b]The source contract.[/b] Anything in [constant GROUP] with these counts as a source; the chunk streamer, [TerrainNavFeeder],
## AIActivationManager and the replay read sources only through them:
## [br]- [code]global_position[/code], [code]load_distance[/code], [code]nav_distance[/code] (metres).
## [br]- [code]counts_on_this_machine() -> bool[/code] and [code]distance_moved_since_last_check() -> float[/code].
## [br]
## In multiplayer a source counts on the server or offline, and on a client only for that client's own pawn.
class_name StreamingSource
extends Node3D

## The name of the Godot group every source joins, which is how a ChunkStreamer finds them.
const GROUP := &"streaming_sources"

## Whether this source keeps the world loaded right now. It can be changed at any time.
@export var active := true:
	set(value):
		active = value
		_update_group()
## Chunks within this distance are loaded, in metres, measured to the nearest edge of the chunk.
@export_range(0.0, 2000.0, 1.0, "or_greater") var load_distance := 320.0:
	get:
		# What _distance_in_use picks; setting it still sets this node's own value, which a plain source uses.
		return _distance_in_use(load_distance, false)
## Nav is built within this distance, in metres. It's separate because nav has about 100 tiles per chunk at 128 m, so building it as
## far out as the ground would be slow. 0 means this source builds no nav. It can't exceed [member load_distance].
@export_range(0.0, 2000.0, 1.0, "or_greater") var nav_distance := 128.0:
	get:
		return _distance_in_use(nav_distance, true)

var _network_entity: NetworkEntity = null
var _last_checked_position := Vector3.ZERO
var _has_been_checked := false


# A node keeps its groups when it leaves the scene and comes back, so joining here is enough; _update_group changes it after.
func _init() -> void:
	_update_group()


## Whether this source should load chunks on this machine right now. ChunkStreamer asks this at every refresh. A pawn exists on every
## machine, so [member active] alone would make each client load the world around every other player.
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


# In GROUP exactly while it might count ([method _might_count]), so the streamer and the others look through few nodes.
func _update_group() -> void:
	var wanted := _might_count()
	if wanted == is_in_group(GROUP):
		return
	if wanted:
		add_to_group(GROUP)
	else:
		remove_from_group(GROUP)


# Whether it belongs in GROUP: always for a plain source, inactive ones included (they're asked and say no). A subclass that
# counts only some of the time says when.
func _might_count() -> bool:
	return true


# The distance a reader gets: its own setting here. A subclass may use another (a pawn's source uses the game's).
func _distance_in_use(own: float, _for_nav: bool) -> float:
	return own


# The NetworkEntity of whatever this source is attached to, or null if it isn't on a networked entity.
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
