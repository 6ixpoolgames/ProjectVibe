# Written by Claude (claude-opus-5-5), 2026-11-06. History: navigation/CHANGELOG.md.
## Where a terrain is and how big its chunks are, as plain values (nav spec section 21.6).
##
## A TerrainNavFeeder gives NavMarkerManager a copy of this when it registers a terrain. NavMarkerManager keeps it in its own memory,
## which outlives any chunk, and uses it to work out which chunk a position is in. It's a copy, so changing the terrain afterwards
## means registering again.
# REFACTOR: describes a terrain, not navigation, so it belongs in terrain/ or world/ (names say what things do). See CHANGELOG.md.
#
# GDScript note: RefCounted is the lightest kind of object. It isn't a node or a saved resource, and Godot frees it
# once nothing refers to it any more.
class_name TerrainSettings
extends RefCounted

## Where the terrain's chunk 0,0 starts in the world.
var origin := Vector3.ZERO
## How wide one chunk is, in metres.
var chunk_size := 128.0
