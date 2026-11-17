<!-- Written by Claude (claude-opus-5-5), 2026-11-17: the game mode's overview, beside its code. -->

# Game mode

The game's rules, in small optional pieces: who spawns where, who controls which pawn, which pawns run and how often, and what every pawn starts with. A game keeps, swaps or drops each piece on its own.

**Status:** built, tier 0. Not yet: telling the server who is spectating, simulating switched-off AI some cheaper way, and a game-level respawn queue or scoreboard.

| File | What it's for |
|---|---|
| [README.md](README.md) | This overview: what's here and how to use it |
| [REFERENCE.md](REFERENCE.md) | Every class, setting and function, generated from the code's doc comments (`python tools/docs/make_reference.py game_mode`) |
| [CHANGELOG.md](CHANGELOG.md) | What changed and why, newest first, and the refactor candidates |
| [PAWN_SPEC.md](../../../docs/pawn/PAWN_SPEC.md) section 11, [PLAYER_AND_CAMERA.md](../../../docs/pawn/PLAYER_AND_CAMERA.md) section 5 | The design: the pawn initializer, possession and the game mode |

## The pieces

```
 GameMode (autoload, singletons/GameMode.gd)
   │  starts the modules listed in the project setting project_base/game_mode/modules
   ├─ PawnInitializer ────── every pawn's default parts (resources/pawn_defaults.tres)
   ├─ PossessionCoordinator ─ the PlayerController; who controls which pawn; spectating
   ├─ AIActivationManager ── freezes AI where the ground isn't loaded; each pawn's tick step
   ├─ SpawnManager ───────── pawns in at SpawnPoints; players back after dying
   ├─ TeamRegistry ───────── how many pawns on each team
   └─ modules from other folders: replay/ReplayRecorder, movement/CrowdMover, diagnostics/DiagnosticsManager
```

- **`GameMode`** (the autoload, in `singletons/`) holds the modules and does almost nothing itself. Each module is reached by name (`GameMode.spawn_manager`), or null when the game leaves it out, so check first.
- **`GameModeModule`** is the base every module extends: `_on_module_added`, `_on_module_removed`, and `get_match_options` for the settings a start menu may offer.
- **`PawnInitializer`**: a `Pawn` calls it from `_enter_tree`, and it adds each default part the pawn's scene doesn't already have, in the same order on every machine. It also hands out the game's default AI brain.
- **`PossessionCoordinator`**: a player possesses and lets go of pawns through it; in multiplayer the server decides. The pawn's `ControllerManager` hears about it, and its AI takes over when no player has it.
- **`AIActivationManager`**: watches every pawn, freezes AI pawns (`Pawn.set_frozen`) where the chunks around them aren't built, and sets how often the rest run (`Pawn.tick_step`) by distance from the viewers and `TickDriver.load_step`.
- **`SpawnManager`**: spawns through `NetworkSession`, picks a free spot at a `SpawnPoint` for the pawn's team, and brings players back. Works with `spawning/PawnSpawner`.
- **`TeamRegistry`**: counts pawns per team, so AI sensing can skip looking when there's nobody on another team.

## How to use it

**Choose a game's modules.** Set the project setting `project_base/game_mode/modules` to the list of module scripts (and `.release` for release builds). An empty list runs none, and the game still runs.

**Change what every pawn starts with.** Edit `resources/pawn_defaults.tres`: its parts list, the default AI brain, and how far a player's pawn loads the world. To override one part on one pawn, put a part with the same name in its scene; to skip some, list them in `Pawn.skip_default_parts`.

**Spawn a pawn, or a player.** On the server or offline:
```gdscript
GameMode.spawn_manager.spawn("goblin", &"red_base")   # at a SpawnPoint in that group
GameMode.spawn_manager.spawn_player(peer)             # possessed for that player, back after dying
```
Place `SpawnPoint` nodes in the level; a point says which teams and group it serves.

**Let a player take a pawn.** `GameMode.possession_coordinator.possess(pawn)`; `release()` lets go and the pawn's AI takes over. `spectate()` flies the free camera instead.

**Write a game's own rule.** Extend `GameModeModule`, add the script to the modules setting (or call `GameMode.add_module`), and find it with `GameMode.get_module(MyScript)`.

## Settings worth knowing

| Setting | Where | Default | What it does |
|---|---|---|---|
| `project_base/game_mode/modules` | project setting | the base's modules | Which modules start with the game |
| `edge_margin` | `AIActivationManager` | 2 m | How close an AI pawn may get to unbuilt ground before it's frozen |
| `full_rate_within_chunks` | `AIActivationManager` | 2 | Chunks from a viewer within which AI runs every tick |
| `every_4th_tick_beyond_chunks` | `AIActivationManager` | 4 | Beyond this, AI runs every 4th tick; between, every 2nd |
| `respawn_players` | `SpawnManager` | on | Players' pawns come back after dying |
| `player_respawn_seconds` | `SpawnManager` | 3 s | How long a player's pawn stays dead |
| `clearance_radius` | `SpawnManager` | 0.6 m | How far another pawn must be for a spot to count as free |
| `ai_brain` | `pawn_defaults.tres` | none | The behaviours a pawn without its own gets |

## Tests

`game_mode/tests/`: `game_mode_selftest` (loading modules, odd settings, match options, the AI switch-off), `pawn_initializer_selftest`, `spawn_manager_selftest`, `team_registry_selftest`. Possession is checked in `pawn/tests/possession_selftest` and, over real connections, `net_pawn_selftest`; tick steps in `pawn/tests/tick_step_selftest`. Run them with `bash tools/run_tests.sh <name>`.
