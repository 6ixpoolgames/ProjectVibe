# Written by Claude (claude-opus-5-5), 2026-11-07. History: world/CHANGELOG.md.
## Puts a level together from its parts: terrain, streaming and the nav feeder.
##
## Add one to a level with these as children; it finds them by itself and wires them together, and builds nothing itself. Code reaches
## them as [code]world.terrain_generator[/code], [code]world.chunk_streamer[/code] and [code]world.nav_feeder[/code].
## [br]- [TerrainGenerator]: required. It generates the ground.
## [br]- [ChunkStreamer]: optional. It loads chunks around streaming sources; without it the terrain builds its fixed block.
## [br]- [TerrainNavFeeder]: optional. It feeds nav; without it there's no nav.
## [br]
## Tier 0 works with one terrain generator; interchangeable, eventually blended level generators are the end goal, not built.
## Design: world spec (docs/world/WORLD_SPEC.md).
class_name WorldCoordinator
extends Node3D

## The parts. Left empty, each is found among this node's children.
@export var terrain_generator: TerrainGenerator
@export var chunk_streamer: ChunkStreamer
@export var nav_feeder: TerrainNavFeeder


# A parent's _enter_tree runs before its children's, so this runs before any part has started.
func _enter_tree() -> void:
	for child in get_children():
		if terrain_generator == null and child is TerrainGenerator:
			terrain_generator = child
		elif chunk_streamer == null and child is ChunkStreamer:
			chunk_streamer = child
		elif nav_feeder == null and child is TerrainNavFeeder:
			nav_feeder = child
	if terrain_generator == null:
		push_warning("WorldCoordinator: no TerrainGenerator among its children, so it does nothing.")
		return
	if chunk_streamer:
		chunk_streamer.terrain = terrain_generator
		terrain_generator.build_on_start = false # chunks come from the streamer
	if nav_feeder:
		nav_feeder.terrain = terrain_generator
