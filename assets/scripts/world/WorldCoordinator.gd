# Written by Claude (claude-opus-5-5), 2026-11-07. History: world/CHANGELOG.md.
## Puts a level together from its parts: terrain, streaming and the nav feeder.
##
## Spec: docs/world/WORLD_SPEC.md. It wires its parts together and builds nothing itself, so that the terrain generator generates
## terrain and nav builds from what it's fed, with neither knowing the other exists. Tier 0 works with one TerrainGenerator. The
## owner's end goal, interchangeable and eventually blended level generators, is in the spec and isn't built.
## [br]
## How to use it: add one to a level and give it these as children. It finds them by itself:
## [br]- [TerrainGenerator]: required. It generates the ground.
## [br]- [ChunkStreamer]: optional. It loads chunks around streaming sources. Without it, the terrain builds its fixed block.
## [br]- [TerrainNavFeeder]: optional. It feeds nav. Without it, there's no nav.
## [br]
## Code reaches them as [code]world.terrain_generator[/code], [code]world.chunk_streamer[/code] and [code]world.nav_feeder[/code].
## [br]
## What happens in odd cases (all checked in tests/world_coordinator_selftest.gd):
## [br]- No terrain generator: it warns and does nothing.
class_name WorldCoordinator
extends Node3D

## The parts. Left empty, each is found among this node's children.
@export var terrain_generator: TerrainGenerator
@export var chunk_streamer: ChunkStreamer
@export var nav_feeder: TerrainNavFeeder


# GDScript note: a parent's _enter_tree runs before its children's, so this runs before any part has started.
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
