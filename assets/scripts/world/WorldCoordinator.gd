## Written by Claude (claude-opus-5-5), 2026-11-07: combines terrain, streaming and nav in a level. Spec: docs/world/WORLD_SPEC.md.
## It wires its parts together and builds nothing itself, so that the terrain generator generates terrain and nav builds from what it's
## fed, with neither knowing the other exists. Tier 0 works with one TerrainGenerator. The owner's end goal, of interchangeable and eventually
## blended level generators, is in the spec, and isn't built.
##
## How to use it: add one to a level, and give it these as children. It finds them by itself:
##   TerrainGenerator   required. It generates the ground
##   ChunkStreamer      optional: loads chunks around sources. Without it, the terrain builds its fixed block
##   TerrainNavFeeder   optional: feeds nav. Without it, there's no nav
## Code reaches them as world.terrain_generator, world.chunk_streamer and world.nav_feeder.
##
## What happens in odd cases (all checked in tests/world_coordinator_selftest.gd):
##   - No terrain generator: it warns and does nothing.
class_name WorldCoordinator
extends Node3D

## The parts. Left empty, each is found among this node's children.
# Claude 2026-11-07: renamed from terrain, streamer and nav_link, so that each name says what the part does.
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
