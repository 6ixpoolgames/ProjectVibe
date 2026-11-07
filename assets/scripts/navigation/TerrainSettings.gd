## Written by Claude (claude-opus-5-5), 2026-11-06: where a terrain is and how big its chunks are, as plain values (nav spec section 21.6).
## A WorldNavLink gives NavWorld a copy of this when it registers a terrain. NavWorld keeps it in its own memory, which outlives any chunk,
## and uses it to work out which chunk a position is in. It's a copy, so changing the terrain afterwards means registering again.
## Claude 2026-11-07: it held the noise settings too, for a terrain estimator that was never built, and only a test read them.
##
# GDScript note: RefCounted is the lightest kind of object. It isn't a node or a saved resource, and Godot frees it
# once nothing refers to it any more.
class_name TerrainSettings
extends RefCounted

## Where the terrain's chunk 0,0 starts in the world.
var origin := Vector3.ZERO
## How wide one chunk is, in metres.
var chunk_size := 128.0
