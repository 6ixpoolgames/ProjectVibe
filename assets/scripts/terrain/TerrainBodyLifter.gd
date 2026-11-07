## Written by Claude (claude-opus-5-5), 2026-11-07: moves bodies up onto the ground when an edit raises it above them. An optional module:
## add it as a child of a Terrain. The ground's surface is one-sided, so a body left underneath would fall forever. A game that never
## raises the ground doesn't need this.
##
## How to use it: add this as a child of the Terrain, and put each body that needs it in the Godot group GROUP. Pawn joins by itself.
## A body's position has to be at its feet. Digging moves nothing, because a body just falls into the hole.
##
## What happens in odd cases (all checked in tests/terrain_edit_selftest.gd):
##   - The parent isn't a Terrain: it warns and does nothing.
##   - A body over a chunk that isn't built: left alone, because there's no ground there to compare with.
class_name TerrainBodyLifter
extends Node

## A body in this Godot group gets moved up if an edit leaves the ground above it.
const GROUP := &"stays_above_terrain"

var _terrain: Terrain = null


func _enter_tree() -> void:
	_terrain = get_parent() as Terrain
	if _terrain == null:
		push_warning("TerrainBodyLifter: its parent isn't a Terrain, so it does nothing.")
		return
	_terrain.ground_raised.connect(_on_ground_raised)


func _exit_tree() -> void:
	if _terrain != null:
		_terrain.ground_raised.disconnect(_on_ground_raised)
	_terrain = null


## center is the middle of the raised patch in the world, seen from above, as X and Z.
func _on_ground_raised(center: Vector2, radius: float) -> void:
	# A patch can move a grid point a little past its radius, so this reaches one square further.
	var reach := radius + _terrain.chunk_size / _terrain.chunk_resolution
	for node in get_tree().get_nodes_in_group(GROUP):
		var body := node as Node3D
		if body == null:
			continue
		var at := body.global_position
		if Vector2(at.x, at.z).distance_to(center) > reach or not _terrain.has_chunk(_terrain.chunk_of(at)):
			continue
		var ground := _terrain.height_at(at.x, at.z)
		if at.y < ground:
			body.global_position = Vector3(at.x, ground, at.z)
