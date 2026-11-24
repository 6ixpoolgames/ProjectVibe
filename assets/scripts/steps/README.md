<!-- Written by Claude (claude-opus-5-5), 2026-11-24: the steps system's overview. -->

# Steps

One step system for everything that runs a sequence over ticks (pawn spec 16.7): a `Step` base and the `StepTimeline` that runs a set of them. Each ability owns a timeline; each AI behaviour will (pawn redesign step 7).

**Status:** built, tier 0 (pawn redesign step 2): the step core, lifted out of `AbilityBase` with its behaviour unchanged. Next: behaviour steps and the step library (step 7).

- **`Step`**: one step, a child node of its owner: `enter()`, `tick(dt)` (RUNNING, DONE or FAILED), `exit(reason)`, `length_ticks` (at 60 a second), `keeps_owner_running`, `counts_this_tick()`, `released_now()`. `AbilityStep` (`abilities/steps/`) extends it with a cancel window and ending when its action is let go.
- **`StepTimeline`**: runs an owner's steps on `TimelineEntry` rules: at a tick, after another entry starts or ends (with a delay), or on a condition; several at once; one step in several entries. Its state is four numbers per entry, which the owner rolls back as one value.

## How to use it

**Run steps from an owner.** Make a `StepTimeline.new(self, name)`, `build(steps, entries)` once, `begin(tick)` when a run starts, `run(dt, elapsed)` each tick it runs (it returns RUNNING, DONE or FAILED), `end(reason)` when it stops early, and `loaded()` after a rollback sets `state`. The owner provides four methods the timeline calls: `_timeline_state_written()` (push `state` for rollback), `_timeline_step_started(step)`, `_timeline_step_finished(step, reason)` and `_timeline_runaway()` (more than `MAX_STARTS_PER_TICK` starts in one tick: end the run). `AbilityBase` is the example.

## How it works

- An entry's state is the tick it started, the tick it ended, why it ended, and where its step's count starts (moved on by ticks that don't count, such as a windup waiting for a turn). Nothing counts down: a step's length is checked against its start.
- Entries with values (`TimelineEntry.values`) set them on their step as they start; the step's own values come back when the run ends.
- Conditions on entries are asked about the owner (`AbilityCondition.holds(owner)`). `TimelineEntry` and `AbilityCondition` still live in `abilities/steps/`; they move here when behaviours use them.
