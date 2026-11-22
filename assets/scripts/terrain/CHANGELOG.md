<!-- Written by Claude (claude-opus-5-5), 2026-11-17: the terrain system's running changelog (the owner's call: history leaves the
code comments and lives here, next to the code). Newest first. Add an entry with every change; code comments say what the code does
now, this says how it got here and why. -->

# Terrain changelog

Terrain is this folder: `TerrainGenerator`, and its optional modules `TerrainEditLog` and `TerrainBodyLifter`. Design: [docs/world/WORLD_SPEC.md](../../../docs/world/WORLD_SPEC.md) (how it fits with streaming and nav) and [docs/streaming/STREAMING_SPEC.md](../../../docs/streaming/STREAMING_SPEC.md) (build costs). Overview: [README.md](README.md).

## Refactor candidates

Code that works but doesn't yet fit the project's goals (reusable, extensible, efficient, designer friendly). Each is marked `REFACTOR:` in the code. Sizes are rough: S an hour or two, M a day, L more.

None in this folder yet. Related: `TerrainSettings`, which describes a terrain, sits in `navigation/`; moving it here or to `world/` is listed in [navigation's changelog](../navigation/CHANGELOG.md).

| What | Where | Why | Size |
|---|---|---|---|

## 2026-11-22

- **A held chunk's collision stays out of the scene until it's published,** rather than switched off. `SightGeometry` (line of sight, and the crowd mover's ground) leaves switched-off shapes out and never noticed them switched on, so chunks landed through the schedule were missing from it: sight saw through that ground and soldiers there fell back to physics movement. Now the body enters the scene when the chunk lands, and everything following the scene's bodies sees it arrive.
- **Held chunks** (state store spec 13.12): `build_chunk_step(key, hold)` builds up to publishing and stops: the chunk's points (what `height_at` reads), its collision (built, switched off) and `chunk_built` wait until it's published by `load_chunk`, on its landing tick. `is_chunk_ready_to_publish` (new). A held chunk dug while it waited catches up on its edits when it lands. The mesh and collision builders read the build's own points, so nothing reads half-published ground.

## 2026-11-21

- **`TerrainBodyLifter` lifts a pawn with `Pawn.teleport`**, so the crowd, the state store and the move check know it was put there, and a sleeping pawn wakes (state store spec 13.9).

## 2026-11-18

- **Comments rewritten to the reference style** (the documentation pass): moved to the README's new "How edits work" section: the edit log's byte format, multiplayer and saving rules, the body lifter's rules and what `_make_chunk_markers` must return. `TerrainGenerator`'s teaching comments (`GDScript note:`, the "how to read this file" block, the history of the first generator) are gone. No stale comments found.

## 2026-11-17

- **Edits rebuild only the nav they touch.** `TerrainGenerator.edit_area`: while `chunk_built` goes out for an edit, the part of the ground it changed. `world/TerrainNavFeeder` passes it on, so nav rebuilds only the tiles under the edit instead of every tile under the chunk (the C++ bundle, stage 2, from the code audit).
- **A refused save isn't overwritten.** If the file at `save_path` was there but refused (broken, or made for ground with other settings), the log no longer saves itself over it, so one run with a different seed doesn't delete the saved edits; `save_to_file()` still replaces it on purpose. A late joiner now gets the whole log even when it's empty: before, a client that loaded edits from its own file kept ground the server doesn't have. Methods `TerrainEditLog` calls lost their underscores (`apply_edit_from_log`, `finish_building_chunks`, `edit_log_arrived`, `edit_log_left`, `rebuild_chunks_for_log`), since another class uses them (the wider code audit).
- **Comments cleaned up** for the documentation pass: dated notes moved here, doc comments in Godot's markup. Stale comments fixed: an edit is 20 bytes, not about 24; the edit log's rebuilds go one chunk a frame, not a few; a script extends `TerrainGenerator`, not `Terrain`; the generator no longer feeds nav itself (a `TerrainNavFeeder` does), and unloading a chunk removes its nav data through `chunk_removed`.

## 2026-11-16

- **`generator_version`**, part of `ground_settings_hash`: raise it when a script's own `_shape_height` changes the ground without changing a setting, so saved edits and other machines made for the old ground are refused (the navigation and terrain assessment).

## 2026-11-12

- Whole-number divisions in the chunk build steps are marked as meant, so they don't warn.

## 2026-11-09

- **Saving edits** (pawn spec step 11): `TerrainEditLog.save_to_file()` and `load_from_file()`, a 4-byte "PBTE" header then `to_bytes()`. A save writes a temporary file and renames it over the old one; loading falls back to the temporary file after an interrupted save. Designers use `save_path`, `load_on_start` and `save_every_seconds`. Only the server or an offline game saves and loads; a missing, broken or different-ground file is refused and nothing changes.

## 2026-11-07

- **Fixes from the audit of 6df1464.** `from_bytes` checks every record before changing anything (it used to clear the log first, so one bad record left it empty while the built ground still had the old edits). A client finishes half-built chunks before recording an edit from the server; the other order made a half-built chunk read the edit from the log and then get it again, raising the ground twice.
- **Terrain and nav split apart.** The generator knows nothing about nav, networks or streaming: it sends `chunk_built` and `chunk_removed`, and `world/TerrainNavFeeder` feeds nav. Moving bodies out of raised ground became the `TerrainBodyLifter` module (`ground_raised`), and the network rule (only the server edits) moved into `TerrainEditLog` (`refuses_edit`).
- **Renamed** so each name says what it does: `HeightmapTerrain`, then `Terrain`, became `TerrainGenerator`; `tile_size` became `chunk_size` and `grid_size` `chunk_resolution`, because "tile" means nav's 12.8 m tiles everywhere else. Scene nodes may still be called "Terrain".
- **`TerrainEditLog`**: edits outlast their chunks, go to clients as they happen and to late joiners whole, and are rounded to 32 bits so every machine gets identical ground. Built chunks read their edits a few at a time (`EDITS_PER_STEP`, about 24 microseconds an edit), and a neighbour that isn't built still has its edits, so lighting at the border matches.
- **For streaming and servers:** `build_meshes` (off: collision only; a mesh was about 1.9 ms of the 6.5 ms a 256 m chunk cost), `has_ground_around` for the AI switch-off, `get_chunk_triangles` for a feeder that arrives late, and the `terrains` group.

## 2026-11-06

- **Chunks built in steps** for `streaming/ChunkStreamer`: `build_chunk_step`, `load_chunk`, `unload_chunk`, `start_empty` and `build_on_start`, with steps of about 0.4 ms on a fast desktop. An edit finishes half-built chunks first. Unloading an edited chunk without an edit log warns once.
- **Mesh arrays filled directly** instead of through SurfaceTool, which took 5.6 ms of the 10.7 ms a 256 m chunk cost.
- **Chunk size** 256 m, then 128 m after the stress test (the owner's call): the worst single step is about a third of a 256 m chunk's, which suits slower machines. Squares stay about 6 m.
- **Chunk markers** (nav spec section 21.6): `_make_chunk_markers` lets a generator say what's in each chunk.

## 2026-11-05

- **`TerrainGenerator`** (first called `HeightmapTerrain`): one generator with the features of `procgen_tile.gd` (noise settings, UVs, a Generate button, a collision signal) and `nav_test_terrain.gd` (seamless chunks, `height_at`, `raycast`, live `edit`), built beside them. The low-poly default: flat shading and jittered grid points. Fixed from `procgen_tile.gd`: noise types now use Godot's own enum (its own list of names gave Cellular for "Simplex"); chunk size is the whole chunk, not one square; points are numbered across the world, so chunks join up; both kinds of normals are worked out across chunk borders instead of with `SurfaceTool.generate_normals()`, which left a faint line at each border (and was why `slope_smoothing` did nothing).
