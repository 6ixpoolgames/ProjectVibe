## Written by Claude (claude-opus-5-5), 2026-11-06: a generator's settings, as plain values (nav spec section 21.6).
## A generator gives NavWorld a copy of this when it registers. NavWorld keeps it in its own memory, which outlives
## any chunk, and uses it to work out which chunk a position is in. The terrain estimator will use it too.
## It's a copy, so changing the generator afterwards means registering again.
##
# GDScript note: RefCounted is the lightest kind of object. It isn't a node or a saved resource, and Godot frees it
# once nothing refers to it any more.
class_name TerrainSettings
extends RefCounted

## Where the terrain's chunk 0,0 starts in the world.
var origin := Vector3.ZERO
## How wide one chunk is, in metres.
# Claude 2026-11-06: matches Terrain's new defaults of 128 m and 21 squares.
var chunk_size := 128.0
## The number of grid squares along each side of a chunk.
var chunk_resolution := 21
var height_scale := 12.0
var noise_seed := 0
var noise_scale := Vector2.ONE
var noise_type: FastNoiseLite.NoiseType = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
var frequency := 0.015
var fractal_type: FastNoiseLite.FractalType = FastNoiseLite.FRACTAL_FBM
var fractal_octaves := 3
var fractal_gain := 0.5
var fractal_lacunarity := 2.0
