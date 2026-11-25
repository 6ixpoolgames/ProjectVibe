<!-- Written by Claude (claude-opus-5-5), 2026-11-17: the pawn system's running changelog. History leaves the code comments and lives
here, next to the code. Newest first. -->

# Pawn changelog

The pawn is this folder (`Pawn.gd`), with its scene `assets/scenes/pawn/pawn.tscn` and default parts in `assets/scenes/pawn/parts/`, added by `game_mode/PawnInitializer`. Design: [docs/pawn/PAWN_SPEC.md](../../../docs/pawn/PAWN_SPEC.md) and [docs/pawn/PLAYER_AND_CAMERA.md](../../../docs/pawn/PLAYER_AND_CAMERA.md); the slimming plan (M1 to M6) is in [docs/ROADMAP.md](../../../docs/ROADMAP.md). Overview: [README.md](README.md).

## Refactor candidates

Code that works but doesn't yet fit the project's goals (reusable, extensible, efficient, designer friendly). Each is marked `REFACTOR:` in the code. Sizes are rough: S an hour or two, M a day, L more.

The owner wants the pawn to keep only the body, its tick order, its part references and general flags (pawn slimming). Input, possession, hits, death, camera and team counts have moved out (M1 to M5). Nothing found still sits on Pawn that belongs elsewhere. Other rows:

| What | Where | Why | Size |
|---|---|---|---|
| A test-only read | `VisualSmoother.get_correction_offset` | Only `netcode/tests/net_test_node` calls it; the test can read `VisualPlacer.current.placement.get_correction(slot)` itself | S |

## 2026-11-25

- **`pawn.navigation_manager` is gone** (pawn spec 16.10 step 5c): each controller follows its own path (`navigation/PathFollower`).

- **`pawn.ai`** (pawn spec 16.10 step 5b): the AI is one `AIManager` with the AI's components as its children; `pawn.ai_context` is gone.

- **Dead ticks** (pawn spec 16.4): `_tick_input` no longer clears a dead pawn's input or has its AI let go; it skips only the AI. The controller manager blocks the input (`input_blocked_by`, `status.dead`).

## 2026-11-24

- **One status component and gameplay events** (the pawn redesign's build step 3a, pawn spec 16.8): `stat_manager` and `effect_manager` are one `status_manager`. `send_event(tag, data)` and `gameplay_event_received` carry gameplay events (Unreal's "send gameplay event to actor"; the owner's call).
- **`Pawn.entity_number()`** (the pawn redesign's build step 1, foundations (pawn spec 16.10)): the pawn's one number (its network id, else a hash of its path, kept until it enters the tree again). It replaces the stagger's instance-id fallback, so a level's own pawns spread their runs the same way on every run.

## 2026-11-23

- **Script warnings:** `_on_lingering_started`'s parameter renamed (it shadowed `_entity`).
- **The code and documentation pass:** `runs_every_tick` removed (unused); `_is_check_tick` uses `_stagger()`; the physics-delta comment moved into `_move_with_physics`; the class doc and `teleport`'s trimmed; `VisualSmoother` flagged `REFACTOR:` (row above). README: owned tags, the streaming source and `PawnStreamingSource`.

## 2026-11-22

- **`owned_tags`** (tag spec step 2): a reference to the pawn's `OwnedTags` part, which the part sets as it enters, like the others.
- **A despawned pawn lingers while its projectiles fly** (ability spec 13.5): `linger_until()` (new) keeps its entity to the last one's end; while it lingers it's frozen, hidden and has no collision layer (`_on_lingering_started`).

## 2026-11-21

- **A rollback load tells the AbilityManager** (`state_loaded()`), which works out its soonest deadline again: the tick went back, so a deadline already passed may be ahead again (state store spec 13.10).

- **`VisualPlacer`** and **`VisualPlacementGD`** (new): the "place what's drawn" pass. One placer, made on first use under the TickDriver, places every pawn's Visual once a frame (the C++ `VisualPlacement`, or its GDScript twin). `VisualSmoother` no longer runs each frame: it holds the pawn's slot in the placer (`slot`, `get_correction_offset()`, new) and forwards runs, snaps, moves and corrections (state store spec 13.9).
- **`get_visual_slot()`** (new): the Visual's slot in the placer, for the crowd mover.
- **`finish_written_move()` removed**: the crowd mover no longer calls the pawns it moved.
- **The input bookkeeping moved** from the end of the run to just after the abilities, in the pawn's own simulate (`_finish_input`), so it doesn't wait for the crowd's move.
- **`_position_after_run` is replaced by `_moved_since_run`**, set by `teleport` and cleared as a run begins and by a rollback load: a teleported pawn stays awake for its next run. A position set directly no longer wakes a sleeping pawn; use `teleport`.

- **`teleport` is recorded even after the crowd mover wrote the pawn's move this tick**: the store's `mark_changed`, which it calls, now drops the written values.

## 2026-11-20

- **`teleport(to)`** (new): the one way to move a pawn instantly. Tells the crowd mover, snaps the Visual, marks its store row changed and sets `last_teleport_tick` (new), which the `MoveSanityCheck` lets through (state store spec 13.8).
- **`finish_written_move()`** (new): ends a run whose position, velocity and grounded the crowd mover wrote through the state store.

- **Tells the crowd mover about itself**: it joins `CrowdMover.current`'s members as it enters the tree and leaves as it leaves, and notes each move by physics (`note_moved`), so the crowd reads the others from the state store (state store spec 13.7).
- **`get_store_handle()`** (new): its handle in the state store, or -1.

## 2026-11-19

- **Pawn slimming for the state store's step 3** (state store spec 12.8): 638 lines to 577 (313 code).
  - **Parts tell the pawn they're there:** each pawn part (AbilityManager, StatManager, EffectManager, ControllerManager, NavigationManager, AIContextComponent, PawnStreamingSource) sets its reference on the pawn as it enters the tree; the pawn finds only its two general parts (NetworkEntity, TickStateComponent), in `_enter_tree`. Works with or without the GameMode.
  - **The streaming source is a part** (`PawnStreamingSource`, a default part): `keeps_world_loaded`, `load_distance`, `nav_distance`, `counts_on_this_machine()` and `distance_moved_since_last_check()` left the pawn. `pawn.keeps_world_loaded` is now `pawn.streaming_source.keeps_world_loaded`; `is_keeping_world_loaded()` stays, asking the part.
  - **The role hook** only notes its NetworkEntity: clearing input on a role change is the ControllerManager's.
- **`due_tick`**: the first tick it may run on, worked out after each run (reset by its step changing, a player taking it, or a rollback load), so the tick driver doesn't call a pawn on a load step on the ticks it skips.

- **Pawn slimming for the state store's step 2** (state store spec 12.8): 716 lines to 638.
  - **`VisualSmoother`** (new): smoothing Visual between ticks and fading corrections moved out of the pawn, which makes one when it has a Visual and tells it after each run, after a rollback load and from the network hooks. The pawn has no `_process` any more.
  - **`SharedPawnTable`** (new): the shared pawn table and grid, out of the pawn's static state. `Pawn.get_table()` and `Pawn.get_grid()` became `SharedPawnTable.get_table()` and `get_grid()`.
  - **`detectability` removed:** callers read the Detectability stat through `StatManager.detectability_of()` (and set it with `set_detectability()`); a pawn without the stat counts as 1.
- **`mover`**: what moves the pawn instead of its own `move_and_slide`, on the ticks it takes the move (the CrowdMover, set by the PawnInitializer; null, it moves itself). The pawn no longer names `CrowdMover`. `finish_crowd_move` and `finish_move_by_physics` are now `finish_move` and `move_by_physics_now`.
- **Recorded only when it changes:** its `TickStateComponent` copies its last row forward on ticks it doesn't run, unless something marks it (`mark_state_changed()`, which an effect landing calls); its runs mark it. `team` and `tick_step` are pushed entries (their setters push), so team is recorded now.

## 2026-11-18

- **Comments rewritten to the reference style** (the documentation pass): the `Pawn` class comment cut to the tick order, the unwritten body rotation, Visual and the scene's optional children (scene needs, Visual's reason, "where things live now" and the odd cases moved to the README's "How it works"). `tick_step`, the sleeping rule and the streaming members shortened, with the tick rules kept. The "tier -1" wording in the summary was dropped. `GDScript note:` teaching comments removed, keeping any non-obvious fact shortened.

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
