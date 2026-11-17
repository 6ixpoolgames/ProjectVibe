<!-- Written by Claude (claude-opus-5-5), 2026-11-17: the pawn system's running changelog. History leaves the code comments and lives
here, next to the code. Newest first. -->

# Pawn changelog

The pawn is this folder (`Pawn.gd`), with its scene `assets/scenes/pawn/pawn.tscn` and default parts in `assets/scenes/pawn/parts/`, added by `game_mode/PawnInitializer`. Design: [docs/pawn/PAWN_SPEC.md](../../../docs/pawn/PAWN_SPEC.md) and [docs/pawn/PLAYER_AND_CAMERA.md](../../../docs/pawn/PLAYER_AND_CAMERA.md); the slimming plan (M1 to M6) is in [docs/ROADMAP.md](../../../docs/ROADMAP.md). Overview: [README.md](README.md).

## Refactor candidates

Code that works but doesn't yet fit the project's goals (reusable, extensible, efficient, designer friendly). Each is marked `REFACTOR:` in the code. Sizes are rough: S an hour or two, M a day, L more.

The owner wants the pawn to keep only the body, its tick order, its part references and general flags (pawn slimming). Input, possession, hits, death, camera and team counts have moved out (M1 to M5). What still sits on Pawn and belongs elsewhere:

| What | Where | Why | Size |
|---|---|---|---|
| Smoothing Visual in its own part | `_process`, `_on_network_interpolated`, `_on_network_corrected`, the `_previous_*` and `_current_*` fields | Pawn slimming M6: the VisualSmoother, planned with animation v0's visuals manager | M |
| The streaming source contract off the pawn | `load_distance`, `nav_distance`, `distance_moved_since_last_check`, `_update_source_group`, `counts_on_this_machine`, `is_keeping_world_loaded` | Pawn slimming (source). M2 kept a flag on the pawn plus the contract; a small part or the streamer's own bookkeeping would slim the pawn. **The owner's call** (the home was left open) | S–M |
| The pawn table and grid in a class of their own | `_table`, `_grid`, `get_table()`, `get_grid()`, `_join_table()` | Static shared state on the pawn class; a small holder class says what it is and slims the pawn | S |
| `detectability` off the pawn | `detectability`, `_own_detectability`, `_detectability_stat()` | A pass-through to the Detectability stat (M6), kept for pawns without one. Callers could read the stat and the table take a default | S |
| Input clearing on a role change | `_on_network_role()` | Input is the ControllerManager's (M4); it could watch the role change itself | S |

## 2026-11-17

- **Detectability is a stat** (the C++ bundle stage 4, pawn M6): `detectability` reads and writes the Detectability stat (`StatManager.DETECTABILITY`), mirrored into the pawn table, so effects can change it. It left the inspector, so there's one place to set it.
- **The shared grid** (`get_grid()`, an `AIPawnGrid`) moved here from AISensingManager (the C++ bundle stage 3), beside the table, since the swing hit checks use it too.
- **The owner's calls from the wider audit:** `possessable` moved to the ControllerManager; `get_health()` moved to the StatManager (`pawn.stat_manager.get_health()`); the pawn holds only `ai_context` of its AI, which finds the other AI parts.
- **Comments cleaned up** for the documentation pass: about 150 dated notes moved here, doc comments in Godot's markup. Stale comments fixed: the class description listed default parts without the AI's parts and said the first lines had no managers; `skip_move_when_still` said it was off by default; `is_sleeping` said "rested"; the sleep checks were listed in a different order from the code; a note said `previous_held_actions` was the pawn's.

## 2026-11-16

- **Pawn slimming M1 to M5** (the owner's plan, [docs/ROADMAP.md](../../../docs/ROADMAP.md)):
  - M1: `team_changed` for the new TeamRegistry module, which keeps the counts; resting renamed sleeping (the physics term); `set_simulation_active(active)` renamed `set_frozen(frozen)`, the other way round (`is_frozen()`); the AI's ordered step moved to `AIContextComponent.run_ai` (was `_tick_ai`).
  - M2: `keeps_world_loaded` replaced `ai_loads_chunks`, as a plain flag: no StreamingSource node. Distances come from the game (`PawnDefaultsRes.world_load_distance`, `world_nav_distance`). The streamer, nav feeder, AI switch-off and replay read pawns through the source contract (`counts_on_this_machine`, `distance_moved_since_last_check`). `has_chunk_source()` became `is_keeping_world_loaded()`. This also ended the bug where switching the flag off left a hero unwatched (found 2026-11-15).
  - M3: hits, death, `revive`, `is_invulnerable`, the hit queue and the `hit_received` and `died` signals moved to the AbilityManager.
  - M4: the input, press and hold checks, the server's checks on a client's input, `has_player` and `possession_changed` moved to the ControllerManager. `is_simulated_here()` became public.
  - M5: `camera_preset` moved to a CameraMount under Visual; `always_has_camera_arm` is gone (one arm per player moves between pawns).
- **Tick steps** (pawn spec 8.21, the owner's call): `tick_step` (1, 2 or 4) and `ticks_elapsed`, rolled back; a pawn running every Nth tick does N ticks' worth, finds check ticks that fell between runs, and Visual glides across the whole run. `fired_since_last_run`, `fires_in_run` (audit) and `next_run_tick` (from profiling the networked mass battle) keep schedules on stepping pawns.
- **Crowd movement** (pawn spec 8.22): `crowd_movement`, `finish_crowd_move`, `finish_move_by_physics`, `get_body_radius`, `get_body_shape`. A crowd move's position is rounded as the rollback recording rounds it (the owner's call), which replaced a millimetre tolerance in the mover.
- **Movement switches:** `skip_move_when_still` (on by default after the mass battle measurement: 24 to 31 skipped moves a frame at the first clash, about 0.2 ms) and `rebuild_floor_on_rollback`.
- **The wider audit:** `Pawn.GROUP`, the one list of all pawns (systems used to borrow TerrainBodyLifter's group or the sources' group); only pawns that might keep the world loaded are in the sources' group; a pawn re-entering the tree rejoins the AI switch-off; the camera getters moved to CameraMount (`arm_of`, `mount_of`, `preset_of`, `view_of`); `finish_crowd_move` and `finish_move_by_physics` made public.
- **Diagnostics:** the AI, input, abilities, move and smoothing are timed with `PerfScopes`; smoothing is in diagnostics' animation category (was `visuals.smoothing`).

## 2026-11-10

- **EffectManager part** (pawn spec 8.11): over-time effects count down before the abilities run, so a tick's abilities see its slows and boosts; a pawn with an effect running doesn't sleep.

## 2026-11-09

- **AI on the pawn** (pawn steps 8a and 8b): its AI parts run in a fixed order before input, offline or on the server only (`runs_ai_here`, `is_authority`). `team` (sensing notices other teams) and `detectability`.
- **Resting pawns** (pawn spec 15.3): `sleep_when_idle` and `sleep_check_ticks`; the end of a tick moved into `_finish_tick()`, which a resting tick runs too. Check ticks are counted at the tick rate (scaling spec step 6).
- **The shared pawn table** (scaling spec step 1): every pawn joins a `PawnTable` row, keyed by entity id. `dead`, read by C++ instead of calling `is_dead()` (step 4). `get_network_entity()`.
- **Death** (pawn step 10): `is_dead()` while the Death ability runs; a dead pawn ignores its controllers and its AI.

## 2026-11-08

- **NavigationManager** became a default part (pawn step 7). The old CharacterPawn3D moved to `assets/legacy/`.

## 2026-11-07

- **The tier -1 pawn**, with streaming, cameras, possession and the game mode.
- **Parts and input** (pawn spec steps 3 to 6): PawnInitializer adds default parts (`fill_in_default_parts`, `skip_default_parts`); the AbilityManager's abilities replaced GroundMovement and MovementModule, and gravity moved onto the pawn; input became an `InputCommand` with named actions as bits.
- **Freezing goes through the NetworkEntity**, which decides what ticks: stopping only the pawn left its entity and TickState running, and 2,000 pawns that were off still cost 53 ms a tick.
