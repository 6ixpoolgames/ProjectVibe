<!-- Written by Claude (claude-opus-5-5), 2026-11-17: the navcore C++ library's overview, beside its code. -->

# navcore (C++)

A C++ GDExtension that gives the game a Recast/Detour nav mesh (`NavServer`) and runs the hot paths that are too slow in GDScript: AI perception, line of sight, the shared pawn table, worker-thread jobs, snapshot encoding, rollback recording, replay packing and crowd movement.

**Status:** built, tier 0. Not yet: nav tiers for bigger pawns, the coarse planner and other domains (air, water), and path searches on worker threads (they run in `NavServer.tick` within a budget).

| File | What it's for |
|---|---|
| [README.md](README.md) | This overview: what's here, how to build it, what GDScript uses |
| [CHANGELOG.md](CHANGELOG.md) | What changed and why, newest first, and the refactor candidates |
| `src/*.h` | The reference: each header's top comment says what the class is and how GDScript uses it (Godot's doc tool doesn't read C++) |
| [NAV_SPEC.md](../docs/navigation/NAV_SPEC.md), [SCALING_SPEC.md](../docs/scaling/SCALING_SPEC.md) | The designs: nav, and the tier 1 server plan the table, scheduler and jobs come from |

Every class here is optional for GDScript: each script checks `ClassDB.class_exists(...)` (or `Engine.has_singleton("NavServer")`) and, for most, falls back to a GDScript version that gives the same results. The tests compare the two.

## Building it

- From `native/`: `python -m SCons -j8` (a debug build, the one the editor loads). `target=template_release` for a release build.
- Windows needs the Visual Studio Build Tools (C++). Linux builds a `.so` with `scons` in `native/` (don't commit it: it needs a very new Linux).
- godot-cpp is a submodule in `thirdparty/godot-cpp`, at **10.0.0-stable**, built for Godot 4.7's API (`api_version` in `SConstruct`). `bin/navcore.gdextension` says `compatibility_minimum = "4.7"`.
- Recast/Detour are in `thirdparty/recastnavigation`, built with 64-bit poly refs (`DT_POLYREF64`).
- Their `qsort` calls go to a stable sort of ours (`src/stable_qsort.h`, forced into their sources by the `SConstruct`; their files are untouched), and nearest-polygon lookups go through `GroundDomain`'s own `nearest_poly`, so the nav mesh and its answers are the same on every platform (state store spec 13.11). Call `nearest_poly`, never `dtNavMeshQuery::findNearestPoly`.
- The library lands in `bin/` (`navcore.windows.template_debug.x86_64.dll`). **Close the Godot editor first**: it holds the DLL open, and the library can't hot-reload (its worker threads).

## The classes GDScript can use

Registered in `src/register_types.cpp`.

| Class | What it is | Used by |
|---|---|---|
| `NavServer` (engine singleton) | Builds the nav mesh in tiles from input layers, around streaming interests; path searches now or queued, links (jumps, drops, placed) | `world/TerrainNavFeeder` (also ticks it), `world/BodyNavFeeder`, `NavigationManager`, `NavLinkModule`, `NavMarkerManager`, `CrowdMover`, `diagnostics/NavDebugView` |
| `NavHooks` (Resource) | How a level piece feeds nav: add, carve or surface; order; material to surface names | `TerrainNavFeeder`, `BodyNavFeeder` |
| `PawnTable` | One table of plain pawn data, a slot per pawn, read once a tick; optional and pushed columns | `SharedPawnTable` (makes it), `AISensingManager`, `Stat` (pushed columns) |
| `AIPawnGrid` | Who's near whom, from the table: sensing's search and hits (`find_touching`) | `SharedPawnTable` (makes it), `AISensingManager`, `HitQuery` |
| `JobScheduler` | The worker threads every per-tick job shares, learning what each job costs | `jobs/TickJobs` (makes it) |
| `AISensingJob` | Sensing's search, visibility and line of sight on the workers | `AISensingManager` |
| `AIMemoryStore` | One pawn's AI memory, sight checks and target scoring | `AIMemory`, `SightSense`, `AITargetSelector` (fallback `AIMemoryStoreGD`) |
| `SightGeometry` | A thread-safe copy of the level's collision: rays for sight, ground for the crowd | `ai/senses/SightGeometryFeeder` (makes it), `AISensingManager`, `CrowdMover` |
| `AIDecider` | AI behaviour decisions, the same as `AIBehaviourManager.decide()` (scaling spec 6.2, pawn spec 16.5), the game's main path: one per pawn, the brains shared by all | `AIDeciderBridge` (each behaviour manager's); `ai/tests/decision_replay.gd` (comparing with GDScript) |
| `CrowdBatch` | The crowd mover's batch on the workers, walking pawns along the nav mesh | `CrowdMover` (`use_cpp_batch`; fallback `_move_batch`) |
| `NetCodec` | Snapshot encoding and delta snapshots' change check | `NetworkSession`, `NetPackets` (fallback `NetPackets`) |
| `StateStore` | The central record of every entity's state, tick by tick: layouts, frames, the commit at the end of a tick | `TickDriver` (twin: `StateStoreGD`) |
| `ReplayMotionPacker` | The replay's motion channel packing, byte for byte as GDScript | `ReplayMotionChannel` (fallback: its own GDScript) |
| `VisualPlacement` | Places every pawn's Visual between its last two runs, once a frame, and fades corrections | `VisualPlacer` (twin: `VisualPlacementGD`) |

Inside only, not seen by GDScript: the nav pipeline (`InputStore`, `TileManager`, `GroundBuilder`, `GroundDomain`, `PathQueue`, `SpanField`, `providers`, nav's own `WorkerPool`), and shared headers: `state_encoding.h` (the rounding steps `NetCodec` and `StateStore` share with `StateEncoding.gd`), `change_guard.h` (see below), `fade_math.h` (fades, shared by memory and the decider), `ai_sight_rules.h` (sight rules, shared by sensing and memory) and `stable_qsort.h` (Recast's and Detour's stable sort).

## Threads

Two sets of worker threads, and one rule: **workers only read plain data that can't change while they run, and write only their own results.** Nothing on a worker touches a Godot object.

- **NavServer's own `WorkerPool`** builds nav tiles. A build gets a snapshot of its inputs (references, not copies), so the main thread can keep submitting. Finished builds are swapped in only in `NavServer.tick`, phase 2, on the main thread: each on its landing tick, `build_delay_ticks` nav ticks after it started, in the order they started, the tick waiting for any still running (state store spec 13.12), so the same tiles land on the same ticks on any machine; `get_landed_tiles()` says which. Path searches run there too, after the commits.
- **`JobScheduler`** runs everything else (`AISensingJob`, `CrowdBatch`): a job is cut into batches of about 100 µs, idle workers take the next batch, and `finish()` runs what's left on the main thread. With 0 workers everything runs on the main thread and gives the same answers. Worker count: cores minus one, minus one more on a machine that draws the game, at most 8 (`TickJobs.set_worker_count` to fix it).
- **`ChangeGuard`** keeps that rule for the shared data (`PawnTable`, `AIPawnGrid`, `SightGeometry`): each job reading one adds itself to its guard, and the data calls `before_change()` before any change, which finishes every reader first.
- **`GroundDomain::move_along_surface`** (`CrowdBatch`) reads the nav mesh on workers; that's safe because the mesh only changes in `NavServer.tick`, and each worker has its own Detour query object.

## Tests

Run with `bash tools/run_tests.sh <name>`. None needs a build step, but they all need the library built and loaded.

- Nav: `nav_selftest` (tiles, paths, links, budgets, the stale-build fix), `nav_links_selftest`, `navigation_manager_selftest`, `nav_stitching_selftest`, `body_nav_feeder_selftest`.
- AI: `ai_perception_selftest` and `ai_stealth_selftest` (C++ and GDScript stores give the same results; `-- --gdscript-store` runs GDScript), `ai_sensing_job_selftest`, `sight_geometry_selftest`, `pawn_table_selftest`, `combat_selftest` (swing hits, which go through `find_touching` when nothing is rewound), `tick_rate_selftest` (fades at 30 ticks a second), `ai_decider_selftest` (every decision the same as GDScript's; `ai_decider_compare -- --file=` for a recorded fight).
- Netcode and replay: `net_codec_selftest` (bytes and values match `NetPackets`), `tick_state_selftest` (matches `StateEncoding.quantize`), `replay_selftest` (packing byte for byte).
- Crowd: `crowd_mover_selftest`. Visuals: `visual_placement_selftest`.
- Costs, run by hand (they print numbers, not pass or fail): `godot --headless --path . res://assets/scripts/ai/tests/ai_stress.tscn`, and the same for `pawn/tests/pawn_stress.tscn` and `ai/tests/ai_decider_compare.tscn`.
