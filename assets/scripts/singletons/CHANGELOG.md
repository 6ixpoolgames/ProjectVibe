<!-- Written by Claude (claude-opus-5-5), 2026-11-17: the tick driver's running changelog (the owner's call: history leaves the code
comments and lives here, next to the code). Newest first. Add an entry with every change; code comments say what the code does now,
this says how it got here and why. -->

# Tick driver changelog

This file covers `TickDriver.gd`, the one autoload here that is its own service. The other autoloads keep their history with their systems: `NetworkSession` in [netcode/CHANGELOG.md](../netcode/CHANGELOG.md), `GameMode` in [game_mode/CHANGELOG.md](../game_mode/CHANGELOG.md), `NavMarkerManager` in [navigation/CHANGELOG.md](../navigation/CHANGELOG.md). Design: [NETCODE_SPEC.md](../../../docs/netcode/NETCODE_SPEC.md) section 3, [SCALING_SPEC.md](../../../docs/scaling/SCALING_SPEC.md) section 7. Overview: [README.md](README.md).

## Refactor candidates

Code that works but doesn't yet fit the project's goals (reusable, extensible, efficient, designer friendly). Each is marked `REFACTOR:` in the code. Sizes are rough: S an hour or two, M a day, L more.

| What | Where | Why | Size |
|---|---|---|---|
| A test-only swap | `TickDriver.replace_store` | Only `tick_state_selftest` calls it, to compare the C++ store with its twin; a test helper keeps it out of the shipping autoload | S |
| Move the load ladder's rule to a GameMode module | `_note_tick_cost()`, the ladder's settings and `get_match_options()` in `TickDriver.gd` | A policy for shedding AI work, with its own tuning and match options, inside the universal tick driver. The owner wants autoloads to hold only what every game needs: the driver could report each tick's cost, and a module beside `AIActivationManager` own the rule | M |
| One timing tool | `profile_enabled`, `profile`, `_profile_phase()` in `TickDriver.gd` | A second way of timing work beside diagnostics' `PerfScopes`, with its own names and its own switch | S |

## 2026-11-24

- **Foundations for the pawn redesign** (the pawn redesign's build step 1, foundations (pawn spec 16.10)):
  - **`TickScheduler`** (new, `TickDriver.scheduler`): actions booked for a tick and a point in it, before the tick or after simulate, run by tick, order number and booking order. v0 carries hit delivery (the abilities' static hit queue is gone) and the spawning delays (SpawnManager's own list is gone). Before-tick actions run before the tick's phases are built, so a pawn they spawn runs that same tick. Hit delivery keeps its `pawn.hits` timing.
  - **`DeterministicRandom`** (new, static): `unit`, `signed`, `float_range`, `int_range`, `pick` from the match seed, a key, a tick and a salt; the AI's hash, now shared, with its C++ twin in `native/src/deterministic_random.h` (the AI decider uses it). `TickDriver.tick_rng` is gone: its users (ability priority jitter, spawn spots, the tick sample) use the new service.
  - **Ticks at 60 a second for gameplay settings:** `reference_ticks()` and `reference_seconds()` added; the **Tick Seconds** editor plugin (`addons/tick_seconds/`, enabled in `project.godot`) shows the seconds beside every whole-number setting ending in `_ticks`.
  - **`GameMode.match_seed`**: sets `DeterministicRandom.match_seed`. Not sent to clients yet (REFACTOR).

- **The load ladder tries the lower step, and counts frames that overrun** (the owner asked for the fix after a profiling pass).
  - *Stuck step:* measuring the mass battle headless (`--size=35`, about 130 pawns), the spawn burst stepped the ladder up to 2, and it stayed there at 50% load although step 1 fit at about 66%: the saving it measured after stepping up included the burst ending, so it predicted step 1 at about 95%. Now, after `probe_after_ticks` (600, 10 s) comfortably loaded (a slower average, over about 2 s, under `raise_above` less `step_down_headroom`), it tries the lower step anyway and forgets the stale saving. A try that has to step up again within the same time doubles the wait before the next (up to `probe_wait_max_ticks`, 160 s); one that holds resets it. The deadlines count on the ladder's own clock (ticks it has measured), which keeps working in a driver that isn't running.
  - *Rendering:* the headful pass showed a tick's cost leaves out the rest of the frame (Godot's physics step, drawing, per-frame scripts): windowed at `--size=50`, trying step 2 kept ticks at 67% of their budget while frames went from about 26 ms to 44 ms (22 fps). Now a rendered frame longer than a tick by more than `frame_overrun_margin` (10%: a lighter frame is taken to be waiting for vsync) counts at its length, capped at 1.5 ticks so one hitch only nudges the average; only the autoload measures frames.
  - *Measured after (headless 60 s runs and windowed ones):* headless 35 back to step 1 at 66%; windowed 35 settles between steps 1 and 2 at 58-59 fps (it ran at step 1 at 49-53 fps before); windowed 50 holds step 4 at 37-45 fps (34-39 before, 22 with the try alone).
  - Tested in `pawn/tests/tick_step_selftest` (tries, back-off, switching tries off); the frame part is checked by the measurements, since only the autoload hears frames.

## 2026-11-23

- **Script warnings:** locals named `owner` in `TickDriver` renamed (they shadowed `Node.owner`).
- **The code and documentation pass:** `NetworkSession.snapshot_rate` no longer calls every entity when set (that feature was gone); `COUNTING_STATS` says diagnostics reads some by name; a silent drop got its reason; the class doc points to this README. `TickDriver.replace_store` flagged `REFACTOR:` (row above). README: the tick order includes the store's commit and due ticks, the driver's store settings are listed, the net test's path fixed. `REFERENCE.md` regenerated.

## 2026-11-19

- **Pawns grouped by step** (state store spec 9, step 3): a participant with a `due_tick` property (a pawn) isn't called in input or simulate before that tick. At 300 pawns, most on every 4th tick: about 0.3 ms a tick less in input and commit.

- **The commit phase and the state store** (state store spec 4 and 9, refactor step 1): `store` (the C++ `StateStore`, or `StateStoreGD` with `-- --gdscript-store`), `history_depth` (64), `replace_store()`. After the record phase, `_commit()` writes every active entity's row in one pass and hands the ones the store couldn't read to their owner's `_store_gather()`. A rollback's re-run rewrites the loaded entities' rows (`get_store_handle()`, `commit_entities`). `verify_store_each_tick` (off) is the tripwire: at the start of a tick, nodes must hold what the last commit recorded; mismatches are counted in `store_mismatches` and warned about. `profile` has a `commit` phase.

## 2026-11-18

- **Comments rewritten to the reference style** (the documentation pass): all four autoloads. The tick driver's rules (registering, time, the load ladder, rollback), the session's tick order, rules, time dilation, snapshot rules and packet formats, and the nav marker manager's storage and search notes moved to the README ("How it works"). Stale comment fixed: the session's `disconnected` signal comment said it came "after" `connection_ended` gives the reason; the code sends `connection_ended` first, and the comment now says so. `GameMode`'s class text no longer lists the modules, which its member comments and `DEFAULT_MODULES` already do.
- **`GameMode.DEFAULT_MODULES` starts `AIDecisionModule`**, as the project's module list now does, so the AI decides in C++ (scaling spec 6.2, step 5c). The two lists still differ by `DiagnosticsManager` (the refactor row above).

## 2026-11-17

- **Comments cleaned up** for the documentation pass: dated notes moved here, doc comments in Godot's markup, and doc comments added to the signals and the undocumented public functions. Stale comments fixed: `tick_factor` said it would be "adjusted on clients once netcode exists" and rollback's rules said "the netcode will apply snapshots" (the netcode does both now); the header said nothing was networked yet.

## 2026-11-16

- **The load ladder** (pawn spec 8.21, the owner's call). Each tick's cost is measured against its length; while ticks run over `raise_above`, `load_step` doubles (1, 2, 4), and `AIActivationManager` makes every AI pawn run at most every `load_step`-th tick. `load_ladder_enabled`, `max_load_step`, `load_step_override`, and the `load_step_changed` signal.
- **The ladder steps back down** (the owner's question: why doesn't it?). Under `lower_below` alone it stayed at 4 for good in the owner's run: much of a tick doesn't shrink with the AI's step, so the tick sat at about half its budget. Now it also steps down when the load it predicts for the lower step, from what stepping up saved, fits under `raise_above` less `step_down_headroom`. From the audit: the saving is measured after its own `saving_measured_after_ticks` (it borrowed `raise_after_ticks`), and a saving under `smallest_believable_saving` counts as not measured, so the ladder doesn't bounce.
- **No more catch-up spiral** (the owner's 6 fps playtest). `max_ticks_per_frame` went from 6 to 3, and the autoload sets Godot's own limit (`Engine.max_physics_steps_per_frame`, 8 by default) to match. Godot's limit was the real one: a frame ran up to 8 ticks to catch up, which made the next frame later still, and nothing was ever dropped. The time Godot drops is counted in `dropped_ticks` too.
- **Match options**: `get_match_options()` offers the load ladder's switches in the start menu.
- **Wider audit.** Each registry entry keeps its id and phases, worked out once, and the list stays in order as entries arrive. Before, every register and unregister searched the whole list, and the next tick sorted it again and asked every participant about nine functions: about 450 entries at 150 pawns, each time one spawned, died or froze. `PROFILE_COUNTS` says which profile entries are counts.

## 2026-11-10

- **The tick rate chosen per match** (scaling spec step 6). `tick_rate` is fixed before a match, and clients take the server's in the handshake; `-- --tick-rate=30` chooses it for a dedicated server. Settings counted in ticks are written for 60 a second (`REFERENCE_RATE`) and converted with `ticks_at_rate()` and `per_tick_at_rate()`. Godot's physics rate follows the tick rate (`physics_follows_tick_rate`), so physics doesn't step twice a tick at 30.

## 2026-11-09

- **Hits after simulate** (pawn spec 15.1): `after_simulate`, between the simulate and record phases, and `is_in_simulate()`. Effects queued during simulate are delivered there, so they never depend on which pawn simulated first.
- **`is_in_tick()`** (scaling spec step 3): a force or taunt aimed at another pawn during a tick waits for that pawn's next AI step.

## 2026-11-07

- **Renamed** from `NetworkTime` to `TickDriver`, the name the netcode spec already used: it drives ticks online and offline.
- **`rollback_state_loaded`**: sent once state is back at the rollback's tick, before the replay, so the ground under a corrected pawn can be made ready.

## 2026-11-05

- **The timing record**: `profile_enabled`, `profile` and `reset_profile()`, adding up each phase's time, for finding what's slow.

## 2026-11-04

- **The tick driver** (netcode spec section 3): numbered fixed-length ticks in four phases, registration order, the per-frame limit, `tick_rng()` for repeatable rolls, `set_tick()` for a client's clock.
- **Rollback** (netcode spec section 3.5): `rollback(from_tick)` loads predicted participants and replays later ticks; following entities join only near the replay; loading happens in stages, with `_rollback_after_load` and `_rollback_finished`. Bodies replaying together sync their collision positions.
- **Collision between ticks of one frame**: a later tick in a frame sees where the last one left things. Without it, two pawns touching drifted up to 21 cm from a one-tick-per-frame run (netcode spec section 4.2).
- Found while building the tick sample: a participant that also defines `_physics_process` must turn it off in `_ready`, or it ticks twice.
