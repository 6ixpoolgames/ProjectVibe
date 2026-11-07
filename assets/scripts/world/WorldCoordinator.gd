## Written by Claude (claude-opus-5-5), 2026-11-07: combines terrain, streaming and nav in a level. Spec: docs/world/WORLD_SPEC.md.
## It wires its parts together and builds nothing itself, so that the terrain generator generates terrain and nav builds from what it's
## fed, with neither knowing the other exists. Tier 0 works with one Terrain. The owner's end goal, of interchangeable and eventually
## blended level generators, is in the spec, and isn't built.
##
## How to use it: add one to a level, and give it these as children. It finds them by itself:
##   Terrain         required. It generates the ground
##   ChunkStreamer   optional: loads chunks around sources. Without it, the terrain builds its fixed block
##   WorldNavLink    optional: feeds nav. Without it, there's no nav
##
## What happens in odd cases (all checked in tests/world_coordinator_selftest.gd):
##   - No terrain: it warns and does nothing.
class_name WorldCoordinator
extends Node3D

## The parts. Left empty, each is found among this node's children.
@export var terrain: Terrain
@export var streamer: ChunkStreamer
@export var nav_link: WorldNavLink


# GDScript note: a parent's _enter_tree runs before its children's, so this runs before any part has started.
func _enter_tree() -> void:
	for child in get_children():
		if terrain == null and child is Terrain:
			terrain = child
		elif streamer == null and child is ChunkStreamer:
			streamer = child
		elif nav_link == null and child is WorldNavLink:
			nav_link = child
	if terrain == null:
		push_warning("WorldCoordinator: no Terrain among its children, so it does nothing.")
		return
	if streamer:
		streamer.terrain = terrain
		terrain.build_on_start = false # chunks come from the streamer
	if nav_link:
		nav_link.terrain = terrain
