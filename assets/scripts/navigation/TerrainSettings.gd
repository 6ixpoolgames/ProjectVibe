# Written by Claude (claude-opus-5-5), 2026-11-06. History: navigation/CHANGELOG.md.
## Where a terrain is and how big its chunks are, as plain values (nav spec 21.6).
##
## A [TerrainNavFeeder] gives NavMarkerManager a copy when it registers a terrain, and NavMarkerManager uses it to work out which
## chunk a position is in. It's a copy, so changing the terrain afterwards means registering again.
# REFACTOR: describes a terrain, not navigation, so it belongs in terrain/ or world/ (names say what things do). See CHANGELOG.md.
class_name TerrainSettings
extends RefCounted

## Where the terrain's chunk 0,0 starts in the world.
var origin := Vector3.ZERO
## How wide one chunk is, in metres.
var chunk_size := 128.0
