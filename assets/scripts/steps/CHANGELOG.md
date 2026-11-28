<!-- Written by Claude (claude-opus-5-5), 2026-11-24: the steps system's running changelog. Newest first. Add an entry with every
change; code comments say what the code does now, this says how it got here and why. -->

# Steps changelog

This folder holds the step core (pawn spec 16.7). Overview: [README.md](README.md).

## Refactor candidates

| What | Where | Why | Size |
|---|---|---|---|

## 2026-11-28

- **The timeline keeps a list of its running entries** (per-pawn cost proposal, cut A1; measured with the profiling suite (size 25, 3 runs each, against a baseline taken just before)). `_write_entry`, the one place entries start and stop, keeps it; `begin`, `build`, `loaded` and the new `set_state` (which `AbilityBase.timeline_state` uses for a rollback's state) work it out again. `run()` ticks a copy of it instead of scanning every entry twice: an AI behaviour's steps went from 16.8 to 14.4 us a tick (-0.15 ms a tick in all). Found on the way: packed arrays are shared by reference when assigned, so the copy is `duplicate()`; a plain assignment let a step started during a tick be ticked in the same one (ability_steps_selftest caught it).

## 2026-11-27

- **Each step's tick is timed** as `step.<its class>` while detailed timing is on (the profiling suite; [diagnostics changelog](../diagnostics/CHANGELOG.md)). `StepTimeline` names each entry's scope once when it's built, and checks `PerfScopes.detailed` itself, so with timing off a step's tick costs about 0.07 µs more.
- **The step library, and timelines for any owner** (pawn spec 16.7, 16.10 step 7a). Steps that write a pawn's input extend `InputStep` and write into their host's `StepInput` (an `InputCommand` that knows which parts were written: one writer per input, held actions ORed): moving (`FollowStep`, `KeepAwayFromStep`, `StopMovingStep` beside `MoveToStep`), looking (`LookAtStep`, `LookInDirectionStep`, `StopLookingStep`), buttons (`PressStep`, `HoldStep` with `fresh_press`, `ReleaseStep`) and flow (`DelayStep`, `WaitUntilStep`, `RepeatStep`). The proposal's Wait is `DelayStep`, Unreal's name, because abilities already have a `WaitStep`. `RunQuery` and `GrantTag` wait for step 8. Test: `steps/tests/step_library_selftest`.

- **`TimelineEntry` and `StepCondition` moved here** from `abilities/steps/`, named for any owner (closes the refactor row): `starts_with_ability()` is `starts_with_run()`, and `AbilityCondition` is `StepCondition`, which reads the pawn of the timeline's host (`holds(timeline)`), takes "its action" from the host's `default_action()`, and gains `TARGET_DISTANCE` (the AI target's real position) and a `BETWEEN` comparison, so "dash when 4 to 8 m away" is one condition.

- **What it costs** (size 25, about 95 pawns at load step 1, this machine, the last commit measured beside it): the input phase is 4.8 to 5.4 ms a tick against 3.6 to 4.4, almost all in `pawn.input`, where the running behaviour's timeline now runs (0.97 to 1.12 ms a frame against 0.52 to 0.56), about 10 us a pawn a tick; the whole tick 10.1 to 11.2 ms against 9.3 to 9.7. Timelines whose entries are all started by code skip the rule checks each tick (`StepTimeline` notes whether any entry has a rule), a small saving. The rest goes with the per-pawn GDScript costs (the next measurement and proposal).

- **`MoveStep` repath rules** (left over from 5c): a new path when its walk was dropped, after a rollback loaded old state (`TickDriver.rollbacks_loaded`; a path isn't state), every `repath_ticks` if set, and once more than `off_path_metres` from the path if set (`PathFollower.distance_off_path()`). Settings fall back to the AI controller's `path_settings`. A finished step keeps its follower's arrival or give-up (it stops only a walk still under way).

## 2026-11-25

- **`MoveStep` finds its input through a checked contract** (cleanup after step 5c). A host whose steps write a pawn's input has `step_input()`; `MoveStep` reads it once when the timeline is built into a typed `input`, and warns once if the host gives none (it read the host's `input` property by name each tick before). Its 8 path settings are one `PathFollowSettings` resource (`settings`) instead of copies.

- **Movement steps** (pawn spec 16.7, 16.10 step 5c): `MoveStep` (`movement/`), the base of steps that walk the pawn along a nav path, holds a `PathFollower`, shows its settings in the inspector, and writes its direction and a link's action into its host's `input` (`steer()`). `MoveToStep` walks to `goal`: done on arriving, failed with no way there. The player's click-to-move runs one; the AI's behaviours will from step 7. Test: `navigation/tests/path_follower_selftest`.


## 2026-11-24

- **The step core** (the pawn redesign's build step 2, pawn spec 16.10): `Step` and `StepTimeline`, lifted out of `AbilityBase` and `AbilityStep` with their behaviour unchanged (the ability suites pass as they were, apart from names). The timeline reports to its owner through four host methods. `keeps_ability_running` is now `Step.keeps_owner_running`; release-ending became `Step.released_now()`, which `AbilityStep` overrides. `MAX_STEP_STARTS_PER_TICK` is now `StepTimeline.MAX_STARTS_PER_TICK`.
