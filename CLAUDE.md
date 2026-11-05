# ProjectBase: notes for Claude

Godot 4.4 hobby project (GDScript). Meant as a reusable base for many kinds of games. Very early WIP: whether a feature is used in `test scene.tscn` (the main scene) is the best indicator of whether it works.

## Requirements from the owner

1. **Sign every change.** Any code Claude adds or modifies gets a comment saying Claude wrote it, the date, and why:
   - New script: a header line at the top, e.g. `## Written by Claude (claude-opus-5-5), 2026-11-02: <purpose>`
   - Edited block: a comment on or above the change, e.g. `# Claude 2026-11-02: <what changed and why>`
   - `.tscn` / `.tres` files can't hold comments reliably (the editor strips them), so list those changes in the commit message and in the chat summary instead.
2. **The owner wants to understand the whole codebase.** Don't make changes they can't follow. After every change, explain what changed, how it fits into the rest of the system, and anything it affects elsewhere. Prefer clear and boring over clever.
3. **Comment generously, in plain language.** The owner is getting back into reading and writing GDScript, so new GDScript explains what it does and why, and explains language features as they come up. `assets/scripts/Procedural Terrain/heightmap_terrain.gd` shows the level of detail, with its `GDScript note:` comments. <!-- Claude 2026-11-05: asked for by the owner -->


## Layout

- `assets/scripts/Character Pawn/`: the pawn and its components (nexus, initializer, movement controllers, AI, stats, camera arm)
- `assets/scripts/Dynamic Camera/`: player camera, 3D cursor, free-floating camera, possession toggle
- `assets/scripts/singletons/`: autoloads `GlobalTools`, `GlobalAICoordinator`, `ResourcePreloadManager`, `NetworkTime` (the tick driver all new gameplay runs on; test in `singletons/tests/`), `NetworkSession` (multiplayer: connecting, spawning, inputs, snapshots) <!-- Claude 2026-11-04: added NetworkTime and NetworkSession -->
- `assets/scripts/tags/`: `TagRegistry`, tag names to bits for ability categories (declared in `resources/tag_declarations.tres`; test in `tags/tests/`) <!-- Claude 2026-11-04: new folder -->
- `assets/scripts/netcode/`: `TickStateComponent` (add as a child, list properties in the inspector, get rollback), `StateEncoding`, `NetworkEntity` (add as a child to make an entity networked), `NetPackets`, `NetClock`, `NetFakeConditions` (worst-case fake network), `NetTestBench` (debug-only keys for it and the feature switches), `LagCompensation`. Tests in `netcode/tests/`: `net_selftest` runs real connections between separate processes, `net_measure` prints numbers at set pings, `net_stress` runs many clients and pawns on hills with nav, `net_profile` shows where the time goes, `net_codec_selftest` compares C++ packet encoding (`NetCodec` in `native/`, which snapshots use, with `NetPackets` as the fallback) with `NetPackets` and times both. A change to the packet format goes in both <!-- Claude 2026-11-04: new folder; multiplayer added; 2026-11-05: net_codec_selftest; snapshots now use it -->
- `tick_pawn_sample.tscn` (project root): sample showing a pawn hooked onto the tick driver; scripts in `assets/scripts/samples/`, pawn scene in `assets/scenes/samples/`, test in `samples/tests/`. A teaching example, not the real pawn <!-- Claude 2026-11-04: new sample -->
- `net_sample.tscn` (project root): a small multiplayer game to play. Open it twice, Host in one and Join in the other. In a debug build, keys change the fake network and switch features live (`NetTestBench.gd`). Scripts `samples/NetSampleGame.gd` and `NetSamplePawn.gd` <!-- Claude 2026-11-04: new sample -->
- Headless tests are scenes (so autoloads load): `Godot_v4.4.1-stable_win64.exe --headless --path . "res://<path>/tests/<name>_selftest.tscn"`, exit code 0 = pass. After adding a script with a new `class_name`, run `--headless --import --path .` once first. A script that fails to compile leaves a test scene running forever, so use a timeout. The project runs on Jolt. To test on Godot's own physics, temporarily add an `override.cfg` with `[physics]` and `3d/physics_engine="DEFAULT"` <!-- Claude 2026-11-04: how to run tests; 2026-11-05: Jolt is now the project's engine -->
- `assets/scripts/Procedural Terrain/`: `heightmap_terrain.gd` (`HeightmapTerrain`) brings `procgen_tile.gd` and `navigation/nav_test_terrain.gd` together in one generator with a low-poly default (flat shading, jittered grid points), feeds nav through its mesh input, and also shows the commenting style the owner wants. To see it, open `terrain_sample.tscn` (project root); the test is in `tests/`. Both originals stay in use: `test scene.tscn` still uses `procgen_tile.gd`, and the nav demo and netcode tests still use `nav_test_terrain.gd` <!-- Claude 2026-11-05: new generator -->
- `assets/scripts/resources/`: custom Resource classes (stat blocks, initializer configs)
- `assets/legacy/` and `Orchastrated Component System - legacy/`: old code, not used
- `Pawn Heirarchy Reference.txt`: the owner's design doc for the pawn component tree
- `root.tscn` predates the nexus refactor and is stale; `test scene.tscn` is current
- `docs/navigation/NAV_SPEC.md`: design spec for the planned bespoke C++ voxel-first nav system (nothing built yet) <!-- Claude 2026-11-02: added pointer to the new spec -->
- `docs/pawn/PAWN_ARCHITECTURE.md`: design spec for the pawn layer (controllers, intent, abilities, navigation manager); draft, not locked <!-- Claude 2026-11-04: added pointer to the new spec -->
- `docs/netcode/NETCODE_SPEC.md`: design spec for multiplayer (tick driver, rollback state, prediction, interpolation, lag compensation, packets); own implementation modelled on netfox; draft; stage v0 is built, and section 16 says what's next <!-- Claude 2026-11-04: added pointer to the new spec; updated as it was built -->
- `native/`: C++ GDExtension `navcore` (spec phases 1–2) on Recast/Detour; build with `python -m SCons` in `native/` (needs VS Build Tools), output DLL in `bin/`. Godot side in `assets/scripts/navigation/`, demo `nav_test.tscn`, headless test `assets/scripts/navigation/tests/nav_selftest.gd`. Linux: Ubuntu in WSL2 on the owner's PC, with a separate clone in `~/ProjectBase` and Godot in `~/godot-4.4.1`. Build with `scons` in `native/` there, and copy changed files over or pull them. Don't commit its `.so` files, because they need a very new Linux (netcode spec section 17, row 25) <!-- Claude 2026-11-03: phases 1–2 built and self-test passing; 2026-11-05: Linux -->


## Work in progress

- A parallel rewrite of the pawn assembly system (nexus + initializer) on branch `claude/pawn-assembler-rewrite`. Build it alongside the old code, don't replace the old code in place.
