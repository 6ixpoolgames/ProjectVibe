<!-- Written by Claude (claude-opus-5-5), 2026-11-24: the steps system's running changelog. Newest first. Add an entry with every
change; code comments say what the code does now, this says how it got here and why. -->

# Steps changelog

This folder holds the step core (pawn spec 16.7). Overview: [README.md](README.md).

## Refactor candidates

| What | Where | Why | Size |
|---|---|---|---|
| Entries and conditions still ability-flavoured | `TimelineEntry.starts_with_ability()`, `AbilityCondition.holds(ability)` in `abilities/steps/` | Behaviours will share them; move them here and name them for any owner when behaviour steps arrive (step 7) | S |

## 2026-11-25

- **`MoveStep` finds its input through a checked contract** (cleanup after step 5c). A host whose steps write a pawn's input has `step_input()`; `MoveStep` reads it once when the timeline is built into a typed `input`, and warns once if the host gives none (it read the host's `input` property by name each tick before). Its 8 path settings are one `PathFollowSettings` resource (`settings`) instead of copies.

- **Movement steps** (pawn spec 16.7, 16.10 step 5c): `MoveStep` (`movement/`), the base of steps that walk the pawn along a nav path, holds a `PathFollower`, shows its settings in the inspector, and writes its direction and a link's action into its host's `input` (`steer()`). `MoveToStep` walks to `goal`: done on arriving, failed with no way there. The player's click-to-move runs one; the AI's behaviours will from step 7. Test: `navigation/tests/path_follower_selftest`.


## 2026-11-24

- **The step core** (the pawn redesign's build step 2, pawn spec 16.10): `Step` and `StepTimeline`, lifted out of `AbilityBase` and `AbilityStep` with their behaviour unchanged (the ability suites pass as they were, apart from names). The timeline reports to its owner through four host methods. `keeps_ability_running` is now `Step.keeps_owner_running`; release-ending became `Step.released_now()`, which `AbilityStep` overrides. `MAX_STEP_STARTS_PER_TICK` is now `StepTimeline.MAX_STARTS_PER_TICK`.
