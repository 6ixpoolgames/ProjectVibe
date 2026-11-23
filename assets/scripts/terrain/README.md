<!-- Written by Claude (claude-opus-5-5), 2026-11-17: the terrain system's overview, beside its code. -->

# Terrain

Generates the ground in square chunks from noise: low poly, with no visible square grid. You can see it, stand on it, edit it while the game runs, and nav walks on the very same triangles.

**Status:** built, tier 0. Not yet: merging long edit lists into stored heights, building chunks in C++, and building collision off the main thread.

| File | What it's for |
|---|---|
| [README.md](README.md) | This overview: what's here and how to use it |
| [REFERENCE.md](REFERENCE.md) | Every class, setting and function, generated from the code's doc comments (`python tools/docs/make_reference.py terrain`) |
| [CHANGELOG.md](CHANGELOG.md) | What changed and why, newest first, and the refactor candidates |
| [WORLD_SPEC.md](../../../docs/world/WORLD_SPEC.md) | How terrain, streaming and nav fit together, and the end goal of interchangeable level generators |
| [STREAMING_SPEC.md](../../../docs/streaming/STREAMING_SPEC.md) | Chunk build costs, measured, and the performance target |

## The pieces

```
 TerrainGenerator ── chunk_built / chunk_removed ──► world/TerrainNavFeeder ──► nav
   │  (one list of triangles per chunk: mesh, collision and nav all use it)
   ├── TerrainEditLog     optional child: edits outlast their chunks, reach clients, go into save files
   └── TerrainBodyLifter  optional child: bodies move up when an edit raises the ground over them
          ▲
 streaming/ChunkStreamer asks for chunks (build_chunk_step, unload_chunk); with the tick driver a chunk is held, built up to
 publishing, and load_chunk publishes it on its landing tick (is_chunk_ready_to_publish)
```

- **`TerrainGenerator`** makes the ground. Each chunk is a grid of points, shifted at random (`grid_jitter`) so the squares don't show, with heights from noise. It's flat shaded by default, for the low-poly look. Ground is the same on every machine, from the settings alone. It knows nothing about nav, networks or streaming: it says when a chunk is built or removed, and others listen.
- **`TerrainEditLog`** remembers edits (a centre, radius, amount and tick each), so a chunk built later still has them. In multiplayer only the server edits, and clients get each edit, or the whole log when they join. It saves to a file.
- **`TerrainBodyLifter`** moves bodies in its group up onto ground an edit raised above them, since the ground is one-sided and a body under it would fall forever.

Other folders: `world/WorldCoordinator` puts a terrain, a streamer and a nav feeder together; `world/TerrainNavFeeder` feeds nav from it; `streaming/ChunkStreamer` loads chunks around players. `TerrainSettings` (where a terrain is and its chunk size, for nav markers) lives in `navigation/` for now; navigation's changelog lists moving it here or to `world/`.

## How to use it

**Put ground in a level.** Add a Node3D, attach `TerrainGenerator.gd`, and press Play or the inspector's Generate button. Open `terrain_sample.tscn` to see one. For ground that loads around the player instead of one fixed block, put it under a `WorldCoordinator` with a `ChunkStreamer`.

**Change the look.** `grid_jitter` hides the grid (0 is a perfect grid), `chunk_resolution` sets how fine it is (fewer squares look more low poly), and `smooth_shading` blends the lighting instead of one colour per triangle. `noise_seed`, `frequency` and `height_scale` shape the hills.

**Raise or dig the ground.**
```gdscript
terrain.edit(point, 4.0, 1.5)    # raise a 4 m patch by 1.5 m; a negative amount digs
```
Add a `TerrainEditLog` child so edits survive their chunk unloading and reach other machines, and a `TerrainBodyLifter` child if raised ground could trap bodies.

**Save edits.** On the `TerrainEditLog`, set `save_path` (such as `user://world_edits.tedits`). It loads on start and saves when it leaves the tree; `save_every_seconds` adds timed saves.

**Shape the ground by hand.** Write a script that extends `TerrainGenerator` and overrides `_shape_height` (a flat plaza, a wall). `tests/terrain_test_course.gd` shows how. Raise `generator_version` when you change it, so old saved edits are refused.

**Place markers in each chunk.** Override `_make_chunk_markers` to give a chunk its jumps or points of interest; `tests/terrain_marker_example.gd` and `terrain_marker_sample.tscn` show how.

**Read the ground.** `height_at(x, z)` and `raycast(origin, direction)` work without physics.

## How edits work

The `TerrainEditLog` stores the edits themselves, not the heights they make: a centre, radius, amount and tick each, 20 bytes (the first four are 32-bit floats, so every machine reads back the same numbers). When a chunk is built, its edits are applied in the order they happened. Each edit is listed under every chunk it touches, including unloaded ones, so two chunks that share a border agree on it. A chunk with a very long list costs more to build; nothing merges old edits yet.

**Multiplayer.** The server's log is the one that counts, and only the server edits. A client gets each edit as it reaches it, which is after the server applied it by about half the ping, so prediction can differ for that moment and the usual corrections fix it. A late joiner gets the whole log, even an empty one, so a client that loaded edits of its own doesn't keep ground the server doesn't have. The whole log goes as `to_bytes()`, the same bytes a save file holds. Data from a terrain with different settings is refused, and so is broken data (every record is checked before anything changes).

**Saving.** A save file is a 4-byte `PBTE` header and then `to_bytes()`. Saving writes a temporary file and renames it over the old one, so a crash mid-save never leaves a broken save; loading falls back to the temporary file. A file that is missing, broken or made for different settings is refused and the ground stays as it was; the log then won't save itself over that file, so one run with a different seed doesn't delete the saved edits. Only the server or an offline game saves and loads.

**Body lifter.** `TerrainBodyLifter` moves bodies in the group `stays_above_terrain` (a `Pawn` joins by itself) up onto raised ground. A body's position must be at its feet; digging moves nothing, because a body just falls into the hole. A body over an unbuilt chunk is left alone.

**Markers per chunk.** What `_make_chunk_markers` returns: new markers every call (`get_chunk_markers` moves them into place), positioned from the terrain node, built from the chunk's numbers and not random ones so every machine gets the same list (a marker's id is its place in the list, which is also why an edit changes heights and never the list), with tags declared in `resources/tag_declarations.tres` or they're refused.

## Settings worth knowing

| Setting | Where | Default | What it does |
|---|---|---|---|
| `chunk_size` | `TerrainGenerator` | 128 m | How wide one chunk is |
| `chunk_resolution` | `TerrainGenerator` | 21 | Squares along a chunk's side; fewer look more low poly |
| `grid_jitter` | `TerrainGenerator` | 0.8 | How far grid points move at random, hiding the grid |
| `smooth_shading` | `TerrainGenerator` | off | Off: one flat colour per triangle (the low-poly look) |
| `height_scale` | `TerrainGenerator` | 12 m | How far the noise moves up and down |
| `noise_seed`, `frequency` | `TerrainGenerator` | 250, 0.015 | Which hills, and how big they are |
| `build_on_start` | `TerrainGenerator` | on | Off when a ChunkStreamer asks for chunks (a WorldCoordinator does this) |
| `build_meshes` | `TerrainGenerator` | on | Off: collision only, for a server nobody looks at |
| `save_path` | `TerrainEditLog` | empty | Where edits are saved; empty means no file |

## Tests

`terrain/tests/`: `terrain_selftest` (noise and size settings, seamless chunks, jitter, flat and smooth shading, edits, collision, nav from the terrain), `terrain_edit_selftest` (edits outlasting unloads, the log's bytes, edits arriving mid-build, streaming, the body lifter, long edit lists, save files), `terrain_markers_selftest` (markers per chunk). `streaming/tests/chunk_streaming_selftest` covers building a chunk in steps. `terrain_test_course.gd` and `terrain_marker_example.gd` are helper scripts the tests use. Run them with `bash tools/run_tests.sh <name>`.
