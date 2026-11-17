<!-- Written by Claude (claude-opus-5-5), 2026-11-17: the streaming system's overview, beside its code. -->

# Streaming

Loads the ground in chunks around the things that need it (players, cameras, spawners) and unloads what nothing needs, a few milliseconds a frame, so a big world never stalls the game and a pawn always has ground under it.

**Status:** built, tier 0. Not yet: more than one terrain or props by chunk, loading ahead of a fast source, a budget for the refresh itself, and a run on a real low-end machine.

| File | What it's for |
|---|---|
| [README.md](README.md) | This overview: what's here and how to use it |
| [REFERENCE.md](REFERENCE.md) | Every class, setting and function, generated from the code's doc comments (`python tools/docs/make_reference.py streaming`) |
| [CHANGELOG.md](CHANGELOG.md) | What changed and why, newest first, and the refactor candidates |
| [STREAMING_SPEC.md](../../../docs/streaming/STREAMING_SPEC.md) | How it works, the performance target, measured costs, nav across chunk borders, multiplayer |

## The pieces

```
 streaming sources (the group "streaming_sources")
   StreamingSource node  ─┐
   Pawn that keeps the   ─┼─► ChunkStreamer ──► TerrainGenerator.build_chunk_step / unload_chunk
   world loaded           │        (budgeted per frame; the chunk under a source built at once)
                          └─► also read by world/TerrainNavFeeder (nav), AIActivationManager, the replay
```

- **`StreamingSource`** marks something as keeping the world loaded: add it as a child of a camera, a spawner, anything. A `Pawn` doesn't need one: it's a source itself while a player has it or its `keeps_world_loaded` is on, with distances from the game's `PawnDefaultsRes`. Anything that has the **source contract** (`global_position`, `load_distance`, `nav_distance`, `counts_on_this_machine()`, `distance_moved_since_last_check()`) and is in the group counts.
- **`ChunkStreamer`** scores the chunks near every source, builds the nearest first in small steps within `max_ms_per_frame`, and unloads chunks past `load_distance + unload_margin`. Before each tick it builds any missing chunk a source is over or about to step onto, ignoring the budget, so the ground is always there.

In multiplayer each machine streams for itself: the server around every player, a client around its own pawn. Terrain isn't sent: the same settings make the same ground everywhere.

## How to use it

**Load the world around the player.** Under a `WorldCoordinator`, add a `ChunkStreamer` beside the `TerrainGenerator`; the coordinator connects them and turns off the terrain's `build_on_start`. A player's pawn is a source by itself. Open `streaming_sample.tscn` to see it.

**Keep the world loaded around something else.** Add a `StreamingSource` child to it (an RTS camera, a spawner, a point the AI fights over). Turn `active` off when it shouldn't count.

**Keep an AI pawn's surroundings loaded.** Turn on its `keeps_world_loaded`. How far pawns load is the game's `world_load_distance` and `world_nav_distance` in `resources/pawn_defaults.tres`.

**Smoother on slow machines.** Lower `max_ms_per_frame`: chunks finish later, frames stay short.

## Settings worth knowing

| Setting | Where | Default | What it does |
|---|---|---|---|
| `load_distance` | `StreamingSource` | 320 m | Chunks within this distance load |
| `nav_distance` | `StreamingSource` | 128 m | Nav is built within this distance; 0 builds none |
| `active` | `StreamingSource` | on | Whether it keeps the world loaded right now |
| `max_ms_per_frame` | `ChunkStreamer` | 2 ms | Time a frame may spend building (at least one step always runs) |
| `unload_margin` | `ChunkStreamer` | 64 m | How far past `load_distance` a chunk stays, so edges don't rebuild |
| `max_chunks_per_source` | `ChunkStreamer` | 256 | A safety limit; the nearest chunks win |
| `hold_when_no_sources` | `ChunkStreamer` | on | With no active sources, keep everything loaded |
| `world_load_distance`, `world_nav_distance` | `PawnDefaultsRes` | 320 m, 128 m | The same, for pawns that keep the world loaded |

## Tests

`streaming/tests/`: `chunk_streaming_selftest` (building in steps, the ground guarantee, sources and their network rules, margins, limits, budgets, pawns walking), `nav_stitching_selftest` (paths across chunk borders), `net_streaming_selftest` (real connections, about 2 minutes) and `chunk_stress` (a table of timings with a pretend slower CPU, about 6 minutes; `SlowChunkStreamer.gd` is its test extension). Run them with `bash tools/run_tests.sh <name>`.
