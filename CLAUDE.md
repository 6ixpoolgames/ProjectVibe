# ProjectBase: notes for Claude

A Godot 4.7 base for real-time 3D games (GDScript, with hot paths in a C++ GDExtension, `native/`). 3D only; an RTS counts as real-time 3D. Early and experimental: this framework is the product being explored. History lives in each system's `CHANGELOG.md` and in git, not here.

## Rules

1. **Rapid prototyping of architecture** (the owner, 2026-11-18). Fast, measured experiments; a ground-up rewrite may follow once it's clear what works. Summaries stay short.
2. **Use standard terms and practice.** The owner's wording is often informal or shorthand: follow the standard, don't turn a loose phrase into a rule, and say the standard term when the owner uses another. When naming something, pick the conventional name where one exists. Discuss big designs before building them.
3. **Names say what things do** (controller manager, terrain generator); code reads `parent.thing.does_this()`.
4. **Designer-first:** defaults that work, settings in the inspector, data over code where it's cheap. Settings are easy to reason about: AI timings in ticks (written for 60 a second, converted with `TickDriver.ticks_at_rate`), a half-life only where it really is one.
5. **Legacy files may change** (`assets/legacy/`, `docs/legacy/`): the owner keeps a copy elsewhere, so they can be changed or removed when that helps. Removing one that old scenes still need is the owner's call.
6. **Keep test code out of shipping code.** Test hooks go in `tests/` or `samples/` (see `docs/TEST_AND_DEBUG_CODE.md`). Samples are test beds: what they do for convenience isn't a rule of the base.
7. **Few autoloads:** only truly universal services (`singletons/`). Game rules and per-game defaults are GameMode modules.
8. **Twins stay in step:** where C++ and GDScript do the same job (the AI decider, packet encoding, the state store, `StateEncoding.quantize`, the crowd mover, the visual placement), a change goes in both and the comparison tests must pass. C++ is the main path; GDScript is the backup.
9. **Sign changes, keep history out of code:**
   - A new script starts with `# Written by Claude (<model id>), <date>. History: <system>/CHANGELOG.md.`
   - Comments describe the code as it is now, with no dates. What changed and why goes in the system's `CHANGELOG.md` (newest first), in the same change. Tests, samples and tools may keep dated notes.
   - Code that works but misses a goal gets `# REFACTOR: <what and why>` and a row in its changelog's refactor table.
   - `.tscn`, `.tres` and `project.godot` changes are listed in the commit message and the chat summary (scene files can't hold comments).
10. **Comments are the reference.** `##` doc comments become each system's `REFERENCE.md` and the wiki: a class gets a one-line summary and a short paragraph; a member or function gets one or two lines. Plain `#` comments only give a non-obvious why. Longer explanations go in the system's README. Godot markup: `[br]`, `[codeblock]`, `[method x]`, `[member x]`.
11. **Privacy:** the repository and wiki are public. No local paths (the user folder has the owner's name), keys, codes or emails. Machine-specific notes go in `CLAUDE.local.md` (not committed). Run `python tools/docs/check_privacy.py` before every commit and push.
12. **Git:** work on `master`. Commit and push only when asked; push only to `vibe`, never to `origin`. Never commit `native/thirdparty/recastnavigation`, `bin/~navcore*` or `.so` files.

## Working

- **Tests:** `bash tools/run_tests.sh <parts of suite names>`, `full`, or `full net` (`net_selftest` runs only when named; about 8 minutes). A suite passes only on exit 0, `ALL PASSED`, and no `FAIL` or `SCRIPT ERROR`. Per change: the affected suites plus the arena smoke tests (`arena`); the full suite before a commit; the network tests when netcode changes. After adding a `class_name`, run `--headless --import --path .` once. Tests extend `tests/SelfTest.gd`. The project runs on Jolt; `-- --tick-rate=30` runs anything at 30 ticks a second.
- **Godot:** the editor binary beside the project folder (`../Godot_v4.7.2-stable_win64_console.exe`). Never run two Godot processes at once, and don't edit `project.godot` while the editor is open.
- **C++ library:** `python -m SCons -j8` in `native/` (godot-cpp 10, Godot 4.7's API), with the editor closed (it holds the DLL). Linux builds in WSL (see `CLAUDE.local.md`); the Linux `.so` isn't committed.
- **Docs:** each system folder has a `README.md`, a generated `REFERENCE.md` (`python tools/docs/make_reference.py <system>`) and a `CHANGELOG.md`. Tags: `tools/tags/apply_redirects.py` (rewrites renamed tags in saved files) and `make_tag_reference.py` (`docs/tags/TAGS.md`). Also `make_class_index.py`, `check_links.py`, `check_comments_only.py` (proves a cleanup changed only comments) and `build_wiki.py` (the wiki, published by GitHub Actions on push). Rules: `tools/docs/README.md`.
- **Determinism:** `python tools/determinism/run_determinism_check.py` plays the mass battle several times and names the first entity and column that differ (state store spec 13.11). Across separate sessions, from their replay recordings: `python tools/determinism/compare_replays.py --sessions 3 --size 100` (or two files, or `--latest`). Across machines or platforms: `run_determinism_check.py --compare A B` on fingerprint files from each.
- **Measuring:** `samples/tests/mass_battle_measure.tscn` (`-- --size=N --scopes`, `--ai-shadow`, `--ai-gdscript`), and `mass_battle_net_measure.tscn` over a real network; F4 in a sample shows timings.

## Map

Each system's README has the detail. Specs are in `docs/` (pawn, netcode, navigation, scaling, streaming, replay, diagnostics, world, wiki, tags, and the ability and state store specs the refactor follows, on the `refactor/tick-core` branch); the plan is `docs/ROADMAP.md`; how the modules connect, today and after the refactor, is `docs/ARCHITECTURE.md`; every class is listed in `docs/CLASS_INDEX.md`.

| Folder (`assets/scripts/`) | What it is |
|---|---|
| `singletons/` | The autoloads: `TickDriver` (the tick everything runs on, the load ladder, rollback), `NetworkSession`, `GameMode`, `NavMarkerManager` |
| `pawn/` | The body every character is; runs its parts in a fixed order each tick |
| `controllers/` | Who drives a pawn: input commands, the controller manager, the AI's hands |
| `player/`, `camera/` | The player's side: input, the world cursor, one camera per player, the spectator |
| `abilities/` | Everything a pawn does, started by named actions: definitions (shared settings with variants), steps on timelines, combos, hits, interceptors, projectiles |
| `effects/` | What abilities and hits do to pawns: damage, heals, pushes, boosts, resistances |
| `stats/` | A pawn's numbers (Health, speeds) as nodes |
| `ai/` | Sensing, memory, target, states, behaviours; decisions in C++ (`AIDecisionModule`) |
| `movement/` | The crowd mover: AI pawns moved together once a tick |
| `navigation/` | The pawn's nav part, nav markers and links |
| `state_store/` | The central record of every entity's state, tick by tick (`StateStoreGD`, twin of C++ `StateStore`); `TickDriver.store` |
| `netcode/` | Rollback state, entities, packets, prediction, lag compensation |
| `replay/` | Records every pawn every tick; the viewer |
| `diagnostics/` | Frame timings, session logs, spikes, panels (F1) |
| `game_mode/`, `spawning/` | Optional game rules: possession, AI activation, teams, pawn defaults, spawning |
| `terrain/`, `streaming/`, `world/` | Chunked low-poly terrain, chunk streaming, putting a level together |
| `jobs/`, `platform/`, `tags/`, `resources/`, `ui/`, `visuals/` | Worker threads, run environment, tag bits, designer resources, menus, toy visuals |

Samples (`assets/scenes/samples/`, scripts in `assets/scripts/samples/`): `pawn_sample` (the main scene), `arena_sample`, `faction_arena_sample`, `mass_battle_sample`, `net_sample`, and one per system. Native classes (`native/src/`): `NavServer`, `AIMemoryStore`, `AIPawnGrid`, `AISensingJob`, `AIBatchDecider`, `SightGeometry`, `PawnTable`, `JobScheduler`, `StateStore`, `NetCodec`, `CrowdBatch`, `ReplayMotionPacker`, `VisualPlacement`.

## Legacy

Old code in `assets/legacy/` and old docs in `docs/legacy/`, kept so old scenes open; nothing new uses them. The owner keeps a copy elsewhere, so they can be changed or removed (rule 5). Three old autoloads (`GlobalTools`, `GlobalAICoordinator`, `ResourcePreloadManager`) stay registered for those scenes.
