# ProjectBase: notes for Claude

Godot 4.4 hobby project (GDScript). Meant as a reusable base for many kinds of games. Very early WIP: whether a feature is used in `test scene.tscn` (the main scene) is the best indicator of whether it works.

## Requirements from the owner

1. **Sign every change.** Any code Claude adds or modifies gets a comment saying Claude wrote it, the date, and why:
   - New script: a header line at the top, e.g. `## Written by Claude (claude-opus-5-5), 2026-11-02: <purpose>`
   - Edited block: a comment on or above the change, e.g. `# Claude 2026-11-02: <what changed and why>`
   - `.tscn` / `.tres` files can't hold comments reliably (the editor strips them), so list those changes in the commit message and in the chat summary instead.
2. **The owner wants to understand the whole codebase.** Don't make changes they can't follow. After every change, explain what changed, how it fits into the rest of the system, and anything it affects elsewhere. Prefer clear and boring over clever.

## Layout

- `assets/scripts/Character Pawn/`: the pawn and its components (nexus, initializer, movement controllers, AI, stats, camera arm)
- `assets/scripts/Dynamic Camera/`: player camera, 3D cursor, free-floating camera, possession toggle
- `assets/scripts/singletons/`: autoloads `GlobalTools`, `GlobalAICoordinator`, `ResourcePreloadManager`, `NetworkTime` (the tick driver all new gameplay runs on; test in `singletons/tests/`) <!-- Claude 2026-11-04: added NetworkTime -->
- `assets/scripts/tags/`: `TagRegistry`, tag names to bits for ability categories (declared in `resources/tag_declarations.tres`; test in `tags/tests/`) <!-- Claude 2026-11-04: new folder -->
- `tick_pawn_sample.tscn` (project root): sample showing a pawn hooked onto the tick driver; scripts in `assets/scripts/samples/`, pawn scene in `assets/scenes/samples/`, test in `samples/tests/`. A teaching example, not the real pawn <!-- Claude 2026-11-04: new sample -->
- Headless tests are scenes (so autoloads load): `Godot_v4.4.1-stable_win64.exe --headless --path . "res://<path>/tests/<name>_selftest.tscn"`, exit code 0 = pass <!-- Claude 2026-11-04: how to run tests -->
- `assets/scripts/resources/`: custom Resource classes (stat blocks, initializer configs)
- `assets/legacy/` and `Orchastrated Component System - legacy/`: old code, not used
- `Pawn Heirarchy Reference.txt`: the owner's design doc for the pawn component tree
- `root.tscn` predates the nexus refactor and is stale; `test scene.tscn` is current
- `docs/navigation/NAV_SPEC.md`: design spec for the planned bespoke C++ voxel-first nav system (nothing built yet) <!-- Claude 2026-11-02: added pointer to the new spec -->
- `docs/pawn/PAWN_ARCHITECTURE.md`: design spec for the pawn layer (controllers, intent, abilities, navigation manager); draft, not locked <!-- Claude 2026-11-04: added pointer to the new spec -->
- `docs/netcode/NETCODE_SPEC.md`: design spec for multiplayer (tick driver, rollback state, prediction, interpolation, lag compensation, packets); own implementation modelled on netfox; draft; only the offline tick driver is built <!-- Claude 2026-11-04: added pointer to the new spec; updated once the tick driver was built -->
- `native/`: C++ GDExtension `navcore` (spec phases 1–2) on Recast/Detour; build with `python -m SCons` in `native/` (needs VS Build Tools), output DLL in `bin/`. Godot side in `assets/scripts/navigation/`, demo `nav_test.tscn`, headless test `assets/scripts/navigation/tests/nav_selftest.gd` <!-- Claude 2026-11-03: phases 1–2 built and self-test passing -->


## Work in progress

- A parallel rewrite of the pawn assembly system (nexus + initializer) on branch `claude/pawn-assembler-rewrite`. Build it alongside the old code, don't replace the old code in place.
