<!-- Written by Claude (claude-opus-5-5), 2026-11-17: the game mode's running changelog (the owner's call: history leaves the code
comments and lives here, next to the code). Newest first. Add an entry with every change; code comments say what the code does now,
this says how it got here and why. -->

# Game mode changelog

The game mode is this folder (`GameModeModule`, `PawnInitializer`, `PossessionCoordinator`, `AIActivationManager`, `SpawnManager`, `TeamRegistry`) and the `GameMode` autoload that holds them (`singletons/GameMode.gd`). Modules from other folders (`replay/ReplayRecorder`, `movement/CrowdMover`, `diagnostics/DiagnosticsManager`) keep their own history. Design: [PAWN_SPEC.md](../../../docs/pawn/PAWN_SPEC.md) section 11 and [PLAYER_AND_CAMERA.md](../../../docs/pawn/PLAYER_AND_CAMERA.md). Overview: [README.md](README.md).

## Refactor candidates

Code that works but doesn't yet fit the project's goals (reusable, extensible, efficient, designer friendly). Each is marked `REFACTOR:` in the code. Sizes are rough: S an hour or two, M a day, L more.

| What | Where | Why | Size |
|---|---|---|---|
| One list of default modules | `DEFAULT_MODULES` in `singletons/GameMode.gd` | A second copy of the project setting's list, and it has drifted: the setting also starts `DiagnosticsManager`. One list in one place is easier for a designer to keep right | S |
| Modules name themselves on GameMode | the module lines (`spawn_manager`, `crowd_mover`...) in `singletons/GameMode.gd` | The autoload names every base module, from three folders, so adding one to the base means editing the autoload. Modules registering their own name, with `get_module` for the rest, would keep the autoload universal | M |
| Split the tick-step rule out of `AIActivationManager` | `AIActivationManager.gd` | Two jobs in one module, freezing pawns and choosing their tick step, and the name says only the first. Apart, a game could swap either alone | M |
| Reuse the free-spot query | `_is_free()` in `SpawnManager.gd` | A new shape and query object for every spot tried; made once and reused, a wave of spawns would allocate nothing | S |

## 2026-11-24

- **`max_spawns_per_tick` 1 → 8** (the owner's call: fill faster, still spread out; the internal build accepts the cost of bigger spawn frames).
- **Spawns spread over ticks** (the owner's request, to cut load spikes): `SpawnManager.max_spawns_per_tick` (1; 0 for no limit) caps what spawners spawn in one tick, and `spawns_left_this_tick()` tells them what's left; players' pawns are never held back. Each spawn is timed as `spawning.spawn`. *Why:* the mass battle's replays showed a spawn costs about 12 ms, and a frame with three replacements took 42-44 ms of physics. *Measured* (windowed, `--size=25`, 150 s, from the replays' diagnostics): frames over 45 ms that were mostly physics went from 17 to 3, and over 30 ms from 140 to 55; frames with a spawn in them still average about 16 ms of physics against 7 without, as one spawn is still about 12 ms.
- **Delays on the tick scheduler, rolls from `DeterministicRandom`** (the pawn redesign's build step 1, foundations (pawn spec 16.10)): `SpawnManager.after_seconds(seconds, callable)` is now `after_ticks(ticks, callable)` (ticks at 60 a second), booked with `TickDriver.scheduler`, which runs it just before its tick instead of after the frame's tick loop; its own list is gone. `player_respawn_seconds` (3) is now `player_respawn_ticks` (180). Spawn-spot rolls use `DeterministicRandom` with a roll count instead of a seeded generator. `GameMode.match_seed` sets the match's random seed.

## 2026-11-23

- **`AIActivationManager` runs on ticks:** its checks run from `TickDriver.before_tick` (skipped while resimulating) instead of once a physics frame, so which pawns are frozen depends on ticks, not frame timing; a chunk being removed checks its pawns at once, before the chunk's ground goes. `spread_over_frames` and `max_checks_per_frame` are now `spread_over_ticks` and `max_checks_per_tick` (no saved scene set them). Without a tick driver it still runs per frame.
- **`SpawnManager` lands a spawn's chunk through the streamer** (`ChunkStreamer.land_now`), so a spawn no longer builds terrain outside the landing schedule (state store spec 13.12).

## 2026-11-20

- **SpawnManager**: a respawn moves the pawn with `Pawn.teleport`, so its Visual doesn't glide from where it died and the crowd and the move check know.

## 2026-11-19

- **`AIActivationManager` reads the pawn's streaming source:** `Pawn.is_keeping_world_loaded()` for leaving a pawn on, and `PawnStreamingSource.pawn` for players' positions in the sources' group.

- **The PawnInitializer gives each pawn the game's crowd mover** as its `mover`, if it has none, before filling in default parts (and even when a pawn takes no default parts).

## 2026-11-18

- **Comments rewritten to the reference style** (the documentation pass): class comments of `AIActivationManager`, `PawnInitializer`, `PossessionCoordinator`, `SpawnManager` and `TeamRegistry` shortened (spawn-point choice, respawn, the chunk-ring rule, the spectator's reasoning and the odd cases moved to the README's "How it works"); `SpawnManager`'s "see the class description" pointers now point to the README. History kept here: `AIActivationManager` was a first pass chosen for tier 0 (and the tick step the owner's call); `SpawnManager` follows Unreal's GameMode (the owner's call); team counts in a GameMode module rather than the pawn (the owner's call); the spectator as its own kind of thing (the owner's call). `GDScript note:` teaching comments removed, keeping any non-obvious fact shortened.

## 2026-11-17

- **Tick steps in whole chunks** (the C++ bundle, stage 3; roadmap: "in whole chunks"). `AIActivationManager` measures a pawn's distance from the nearest viewer in rings of chunks, not metres, so every pawn in one chunk runs at the same rate and two pawns fighting side by side never differ.
- **`possessable` is the ControllerManager's** (the wider audit). `PossessionCoordinator` reads it there; it was on `Pawn`.
- `SpawnManager`'s unused `_spawn_count` went (rolls use `_roll_count`).
- **Comments cleaned up** for the documentation pass: dated notes moved here, doc comments in Godot's markup. Stale comments fixed: `PawnInitializer` listed the parts of 2026-11-07 (ControllerManager, StatManager, AbilityManager with Walk, Sprint and Jump), now the whole list; `PossessionCoordinator` said "an AI controller will ask here too" and that letting go was "the controller manager's job when it's built" (the AI never asks; the ControllerManager hands over); `AIActivationManager` said a pawn calls `add_pawn` "when it's an AI pawn" (every pawn does, in `_ready`); `SpawnManager._next_rng` said the spawn count was the key (it's the roll count); `GameMode`'s module list left out `CrowdMover`.

## 2026-11-16

- **`TeamRegistry`** (pawn M1, the owner's call: team counts are a GameMode module's job, not the pawn's). It replaced a shared counter on `Pawn` (`count_pawns_not_on_team`). The wider audit gave pawns their own group, `Pawn.GROUP`, which it counts from.
- **Every pawn watched by `AIActivationManager`** (pawn M2). A pawn that keeps the world loaded is left running, checked each time, so nothing has to tell the module when that changes; a possession is checked at once. `set_simulation_active(active)` became `set_frozen(frozen)` (pawn M1). Pawn M3 and M4 moved `died`, `revive` and `possession_changed` to the AbilityManager and ControllerManager, and the modules followed.
- **Tick steps** (pawn spec 8.21, scaling spec 7.1, the owner's call). `AIActivationManager` sets each AI pawn's `tick_step`: every tick near a viewer, every 2nd or 4th further off, and at least `TickDriver.load_step`. A player's pawn always runs every tick. `get_step_counts()` for diagnostics; its work is timed with `PerfScopes` (diagnostics v0).
- **Match options** (the owner's request, proving out the GameMode's modularity). `GameModeModule.get_match_options()` names settings a start menu may offer; `AIActivationManager` and `SpawnManager` name theirs.
- **Spectating** (the owner's call). `PossessionCoordinator.spectate()`, `stop_spectating()`, `is_spectating()`: the spectator is a `FreeFlyCamera`, not a Pawn, and it's local to this machine.
- **A default AI brain.** `PawnDefaultsRes.ai_brain` goes in place of the plain `AIBehaviourManager` on any pawn without one. From the audit: its name is read once per pawn, not per part, and a brain whose root matches no part warns once.
- **`CrowdMover`** (pawn spec 8.22) joins the default modules.
- **Wider audit fixes.** `PossessionCoordinator` refuses a pawn with no ControllerManager before changing anything (it used to change the pawn's owner, then stop on an error), and a client drops a peer's out-of-date wait for a pawn (one that spawned later went to a peer that had let go). `AIActivationManager` finds viewers among the streaming sources rather than every watched pawn every frame, and reads `TickDriver.load_step` from the autoload rather than by path for every pawn.

## 2026-11-15

- **`ReplayRecorder`** joins the default modules; it records nothing until the game starts a recording (replay spec).

## 2026-11-13

- **No more pawns spawned inside each other.** Physics only sees a pawn just placed after its next step, so two pawns spawned or brought back in one tick found the same spot free and landed 0 m apart; physics then pushed them around at up to 36 m/s and into the ground (the owner's report). `SpawnManager` now remembers spots it handed out for `claim_ticks`, and counts every roll, respawns too (`_roll_count`), so rolls in one tick differ.

## 2026-11-12

- A local variable in `SpawnManager` renamed from `ready` to `come`: it clashed with Node's `ready` signal, an editor warning.

## 2026-11-10

- **`SpawnManager`** (pawn spec 8.9, the owner's call: Unreal's GameMode does the same job). Spawns at `SpawnPoint`s by team and group, `spawn_near` for `PawnSpawner`, players brought back after `player_respawn_seconds`, delays counted in ticks between ticks.

## 2026-11-08

- **`PawnInitializer`** (pawn spec section 11, step 4): every pawn's default parts from one list per game (`PawnDefaultsRes`), in place of the old nexus node on every pawn. `GroundMovement` left the defaults when abilities replaced it.

## 2026-11-07

- **The game mode**: the `GameMode` autoload holding optional `GameModeModule`s, with `PossessionModule` (the PlayerController, and who controls which pawn) and `AIActivityModule` (freezing AI where no source keeps the ground loaded). Players leaving let go of their pawn.
- **Names say what they do**: `AIActivityModule` became `AIActivationManager` and `PossessionModule` became `PossessionCoordinator`, reached as `GameMode.ai_activation_manager` and `GameMode.possession_coordinator` (were `ai_activity` and `possession`).
