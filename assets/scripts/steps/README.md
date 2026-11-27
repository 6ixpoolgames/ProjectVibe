<!-- Written by Claude (claude-opus-5-5), 2026-11-24: the steps system's overview. -->

# Steps

One step system for everything that runs a sequence over ticks (pawn spec 16.7): a `Step` base, the `StepTimeline` that runs a set of them, and a library of steps that write a pawn's input. Each ability owns a timeline, and so does each AI behaviour.

**Status:** built, tier 0: the step core (pawn redesign step 2), and the step library with behaviours hosting steps (step 7). Next: steps that run queries and grant tags, with step 8's selectors.

- **`Step`**: one step, a child node of its owner: `enter()`, `tick(dt)` (RUNNING, DONE or FAILED), `exit(reason)`, `length_ticks` (at 60 a second), `keeps_owner_running`, `counts_this_tick()`, `released_now()`. `AbilityStep` (`abilities/steps/`) extends it with a cancel window and ending when its action is let go.
- **`StepTimeline`**: runs an owner's steps on `TimelineEntry` rules: at a tick, after another entry starts or ends (with a delay), or on a condition (`StepCondition`); several at once; one step in several entries. Its state is four numbers per entry, which the owner rolls back as one value.
- **The step library**, steps that write a pawn's input (`InputStep`, into its host's `StepInput`):

  | Kind | Steps |
  |---|---|
  | Moving (`movement/`) | `MoveToStep` (a point), `FollowStep` (close in on a target), `KeepAwayFromStep` (hold a distance), `StopMovingStep` |
  | Looking (`looking/`) | `LookAtStep` (a point, or a target followed), `LookInDirectionStep`, `StopLookingStep` |
  | Buttons (`buttons/`) | `PressStep` (one tick), `HoldStep` (while it runs; `fresh_press`), `ReleaseStep` |
  | Flow (`flow/`) | `DelayStep` (Wait: a length or a deadline tick), `WaitUntilStep` (a condition), `RepeatStep` |

## How to use it

**Run steps from an owner.** Make a `StepTimeline.new(self, name)`, `build(steps, entries)` once, `begin(tick)` when a run starts, `run(dt, elapsed)` each tick it runs (it returns RUNNING, DONE or FAILED), `end(reason)` when it stops early, and `loaded()` after a rollback sets `state`. The owner provides four methods the timeline calls: `_timeline_state_written()` (push `state` for rollback), `_timeline_step_started(step)`, `_timeline_step_finished(step, reason)` and `_timeline_runaway()` (more than `MAX_STARTS_PER_TICK` starts in one tick: end the run). `AbilityBase` is the example.

**Give an AI behaviour steps.** Override `make_steps()` to return the steps it uses (`made_step(FollowStep, &"Follow")`), or add `Step` children to the behaviour node in its scene (one with the same name replaces the made one). Start them from its code with values: `start_step(&"Follow", {"target": target, "stop_distance": 1.2})`; stop one with `stop_step`. The AI controller runs the running behaviour's timeline each tick it's asked for input. A definition's `step_timeline` starts steps by rule instead, as an ability's does.

**Write a step that writes input.** Extend `InputStep` (or `MoveStep` for walking along a nav path) and write into `input` in `tick()`: `write_move`, `write_look` or `look_at`, `write_held`. Each part takes the last write; held actions OR together. A part nothing wrote is the controller's.

## How it works

- An entry's state is the tick it started, the tick it ended, why it ended, and where its step's count starts (moved on by ticks that don't count, such as a windup waiting for a turn). Nothing counts down: a step's length is checked against its start.
- Entries with values (`TimelineEntry.values`) set them on their step as they start; the step's own values come back when the run ends.
- Conditions on entries (`StepCondition.holds(timeline)`) read the pawn of the timeline's host: look angle, an action held (the host's `default_action()` when none is named), grounded, a stat, ticks since the run began, and the AI's target distance (with `BETWEEN`, a band such as "dash when 4 to 8 m away").
- **Move steps find a new path** when their walk was dropped (charge changing hands), after a rollback loaded old state (`TickDriver.rollbacks_loaded`: a path isn't state, so it's found afresh), every `repath_ticks` if set, once more than `off_path_metres` from the path if set, and after a link isn't crossed in time (the follower itself). A Follow also finds one when its target moves `repath_distance` from where the path leads.
- **A failed step ends its owner's run**, every other step with it. A behaviour whose walk may fail checks right after starting it (`MoveStep.gave_up()`).
