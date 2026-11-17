<!-- Written by Claude (claude-opus-5-5), 2026-11-17: the world system's overview, beside its code. -->

# World

Puts a level together: the ground, the streaming that loads it, and the feeders that hand it to nav, without any of them knowing each other. Also the level-wide rules that belong to no one part, such as the kill floor.

**Status:** partly built, tier 0. The coordinator takes one terrain generator; interchangeable and, later, blended level generators are the end goal (world spec, section 2) and aren't built.

| File | What it's for |
|---|---|
| [README.md](README.md) | This overview: what's here and how to use it |
| [REFERENCE.md](REFERENCE.md) | Every class, setting and function, generated from the code's doc comments (`python tools/docs/make_reference.py world`) |
| [CHANGELOG.md](CHANGELOG.md) | What changed and why, newest first, and the refactor candidates |
| [WORLD_SPEC.md](../../../docs/world/WORLD_SPEC.md) | The design: who does what in tier 0, and the end goal |

## The pieces

```
 WorldCoordinator (finds its children, wires them, builds nothing)
   ├── TerrainGenerator ── chunk_built / chunk_removed ──► TerrainNavFeeder ──► NavServer, NavMarkerManager
   ├── ChunkStreamer ──► asks the terrain for chunks around streaming sources
   └── TerrainNavFeeder   (also keeps nav built around each source's nav_distance)

 StaticBody3D ── BodyNavFeeder ──► NavServer        KillFloor: pawns below its height die
```

- **`WorldCoordinator`** finds a `TerrainGenerator` (required), a `ChunkStreamer` and a `TerrainNavFeeder` among its children and connects them. Code reaches them as `world.terrain_generator`, `world.chunk_streamer` and `world.nav_feeder`.
- **`TerrainNavFeeder`** hands each chunk's triangles to `NavServer` and its markers to `NavMarkerManager`, and asks nav to build around every streaming source. Without a `NavHooks` it only announces markers, which need no C++ library.
- **`BodyNavFeeder`** (new 2026-11-17; its history is in [navigation's changelog](../navigation/CHANGELOG.md)) puts a static body's box shapes into the nav mesh, so paths go around walls.
- **`KillFloor`**: a height below which pawns die (like Unreal's "kill Z"), with a report in the Debugger of how each one got there.

Other folders: `terrain/` (the generator), `streaming/` (the streamer and sources), `navigation/` and `native/` (nav itself).

## How to use it

**Build a level with streamed ground and nav.** Add a `WorldCoordinator`, then as its children a `TerrainGenerator`, a `ChunkStreamer` and a `TerrainNavFeeder` with a `NavHooks`. Turn on the feeder's `tick_nav` if nothing else in the scene ticks nav. The arena samples show the setup.

**Put a wall into nav.** Give a `StaticBody3D` with a `BoxShape3D` a `BodyNavFeeder` child. Only boxes go into nav for now.

**Stop pawns falling forever.** Place a `KillFloor` well below the lowest ground (both arenas have one at -40 m). A pawn below it gets `kill_effect` (by default all its Health) and dies the usual way. Turn `report_falls` off in a game where falling off the map is normal.

## Settings worth knowing

| Setting | Where | Default | What it does |
|---|---|---|---|
| `nav_hooks` | `TerrainNavFeeder` | empty | Set it to feed nav; empty, the terrain is invisible to nav |
| `tick_nav` | `TerrainNavFeeder` | off | Ticks the nav library each physics frame, if nothing else does |
| `unload_margin` | `TerrainNavFeeder` | 64 m | How far past a source's nav distance its nav stays built |
| `kill_effect` | `KillFloor` | `kill_self.tres` | What a pawn below the floor gets |
| `check_every_ticks` | `KillFloor` | 10 | How often it checks, in ticks at 60 a second |
| `report_falls` | `KillFloor` | on | Reports each fall in the Debugger and the replay |

## Tests

`world/tests/`: `world_coordinator_selftest` (the terrain standing alone, odd setups, a whole world with and without nav, the feeder arriving late, leaving and returning, sources changing size), `kill_floor_selftest`, `body_nav_feeder_selftest`. Run them with `bash tools/run_tests.sh <name>`.
