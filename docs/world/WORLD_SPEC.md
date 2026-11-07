<!-- Written by Claude (claude-opus-5-5), 2026-11-07: the world coordinator: tier 0 plan and the owner's end goal. -->

# World Coordinator

**Status:** tier 0 is built, with `WorldCoordinator` and `TerrainNavFeeder` in `assets/scripts/world/`. To see it, open `assets/scenes/samples/pawn_sample.tscn` or `streaming_sample.tscn`. Test: `world/tests/world_coordinator_selftest`. Work in progress, and open to better ideas.

**The idea:** the terrain generator generates terrain. Navigation builds and stitches a nav mesh from the shapes it's fed. A world coordinator combines them, so that neither has to know the other exists.

## 1. Tier 0: terrain chunks only

Tier 0 stays simple. The coordinator works with one `TerrainGenerator` and its chunks. There's no generator contract, no list of generators and no blending yet.

```
WorldCoordinator       level node: decides what's loaded and in what order, builds nothing
├─ ChunkStreamer       sources, budget, ground guarantee
├─ TerrainNavFeeder        hands a chunk's triangles to nav, and passes on edits and unloads
└─ Terrain             generates ground, and knows nothing about nav or streaming
   ├─ TerrainEditLog
   └─ TerrainBodyLifter

NavMarkerManager               autoload: markers, as now
NavServer (C++)        builds and stitches the nav mesh, as now
```

**A chunk loading:**
1. `ChunkStreamer` says a chunk is wanted, and `TerrainGenerator` builds it.
2. `TerrainGenerator` says the chunk is built.
3. `TerrainNavFeeder` gives its triangles to nav, and announces its markers.

An edit takes the same path from step 2. Unloading takes it in reverse.

### Who does what

| Part | Responsible for | Not responsible for |
|---|---|---|
| `WorldCoordinator` | Holding the parts, and the order things happen in | Building anything |
| `ChunkStreamer` | Which chunks should exist, the per-frame budget, the ground guarantee | Nav |
| `TerrainNavFeeder` | Feeding nav from a chunk, announcing and releasing its markers, keeping nav built around sources, and optionally ticking nav | Deciding what's loaded |
| `TerrainGenerator` | Heights, meshes, collision, edits, height queries | Nav, networks, streaming, moving bodies |

**Rule:** the coordinator wires things together and sets the order, and real work lives in a module. If it grows past a few hundred lines, something's in the wrong place.

### Rules for keeping it optional

- A `TerrainGenerator` with no coordinator still builds a fixed block, as it does now.
- A coordinator with no `TerrainNavFeeder` has no nav.
- `TerrainNavFeeder` also has to work with a lone `TerrainGenerator`, because tests and samples use a terrain with nav and no streaming.

`TerrainGenerator` has no calls to `NavServer`, `NavMarkerManager` or the network, which the test checks by reading its source. It gets everything through three signals: `chunk_built`, `chunk_removed` and `generation_started`. The triangles in `chunk_built` are the ones made for collision, so nav doesn't pay to make them twice. Other nav users, such as `nav_bootstrap.gd` and `net_test_node.gd`, still tick `NavServer` themselves.

### Left out for now

- **`TerrainMeshBuilder`:** a clean cut of about 180 lines, but it only tidies `TerrainGenerator`. Do it if the file gets in the way.
- **`AIActivationManager` asking the coordinator:** it still finds terrains through their group. A `TerrainGenerator` with no coordinator has to work with it too, so asking the coordinator would add a second path and remove nothing. It belongs with generators, in section 2.
- **`TerrainCollision`:** about 15 lines, so `build_collision` is enough.
- **`TerrainGround`:** `_shape_height` already works as the way to customise ground.
- **A generator contract and a test generator:** see section 2.

## 2. The end goal

This is the owner's intent, at least for the first game prototype. It isn't tier 0, and nothing below is built.

**The coordinator takes arbitrary level generators,** such as `TerrainGenerator` or a procedural dungeon, uses them interchangeably, and eventually blends them together. `TerrainGenerator` stays a standalone thing.

### What tier 0 must not get in the way of

Tier 0 doesn't build any of this, but it shouldn't make it harder:
- `ChunkStreamer` calls about 10 things on `TerrainGenerator`, all generic except `uses_nav`, which goes away. Don't add height or noise questions to that list.
- Shared code asks "is this chunk built?", never "how high is the ground here?". A building with floors has no single height.
- A generator's edits stay inside it. "Raise the ground here" means nothing in a dungeon.

### A sketch of the contract

```gdscript
class_name LevelGenerator
extends Node3D

func prepare() -> void                          # whole-level work: a dungeon lays out its rooms here
func covers(chunk) -> bool                      # a dungeon only fills some chunks
func build_chunk_step(chunk) -> bool            # one budgeted step, true when finished
func unload_chunk(chunk) -> void
func has_chunk(chunk) -> bool
func get_nav_shapes(chunk) -> PackedVector3Array  # triangles for nav
func get_markers(chunk) -> Array[NavMarker]
func settings_hash() -> int                     # machines can compare what they're building
signal chunk_changed(chunk)                     # an edit: the link tells nav
```

What this implies:
- Each generator builds its own visuals and collision, and the coordinator never sees them.
- The coordinator owns the chunk grid, because interchangeable generators have to agree on it. It has to set the grid before a generator starts.
- Generators must be repeatable: the same seed gives the same result on every machine, because clients build their own world.
- The coordinator holds a list of generators, and never assumes one per chunk.
- A small test generator with stacked rooms, in `tests/`, would prove they're interchangeable. If it needs a change to the coordinator, the contract is wrong.

### Blending

| Kind | Example | What it needs |
|---|---|---|
| By region | This area is dungeon, the rest is terrain | The coordinator picks a generator per chunk |
| Layered | A dungeon under terrain, with both in one chunk | Several generators per chunk, with nav getting all their shapes |
| Surface blend | Terrain easing into a road or a plaza | Generators sharing a height field, so it only suits some kinds |

Openings between generators, like a dungeon entrance cut into a hillside, are the hard part, and aren't designed.

### Nav already supports this

The C++ library needs no changes for this, as far as it's been tested. Each generator can be its own input layer that adds, carves or recolours surfaces. Tiles build from whatever layers cover them, so nav doesn't care about chunks or which generator made what.

A temporary probe on 2026-11-07, Windows, offline, on `NavServer` directly:

| Test | Result |
|---|---|
| A floor 6 m above another | Both found separately |
| A path between them, up a ramp | 94 m, 7 corners, correct |
| The same shapes from two generators, meeting at the ramp | The same path, so they stitch |
| Removing the second generator | The upper floor and the path are gone |
| A carve layer cutting a box out of a roof | The hole is gone, and the rest of the roof stays |

**Limits:**
- Nav's heightmap input fills each column solid from the world floor, so it would wipe out a dungeon underneath. `TerrainGenerator` uses mesh input, so it's fine, and a generator meant to stack has to use mesh input too.
- 6 m is the only gap tried, and a tight ceiling could behave differently.
- The carve test was one box.
- `tile_manager` and the mesh adapter's code weren't read.
