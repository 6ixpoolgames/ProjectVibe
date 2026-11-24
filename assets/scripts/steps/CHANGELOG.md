<!-- Written by Claude (claude-opus-5-5), 2026-11-24: the steps system's running changelog. Newest first. Add an entry with every
change; code comments say what the code does now, this says how it got here and why. -->

# Steps changelog

This folder holds the step core (pawn spec 16.7). Overview: [README.md](README.md).

## Refactor candidates

| What | Where | Why | Size |
|---|---|---|---|
| Entries and conditions still ability-flavoured | `TimelineEntry.starts_with_ability()`, `AbilityCondition.holds(ability)` in `abilities/steps/` | Behaviours will share them; move them here and name them for any owner when behaviour steps arrive (step 7) | S |

## 2026-11-24

- **The step core** (the pawn redesign's build step 2, pawn spec 16.10): `Step` and `StepTimeline`, lifted out of `AbilityBase` and `AbilityStep` with their behaviour unchanged (the ability suites pass as they were, apart from names). The timeline reports to its owner through four host methods. `keeps_ability_running` is now `Step.keeps_owner_running`; release-ending became `Step.released_now()`, which `AbilityStep` overrides. `MAX_STEP_STARTS_PER_TICK` is now `StepTimeline.MAX_STARTS_PER_TICK`.
