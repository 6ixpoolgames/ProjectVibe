<!-- Written by Claude (claude-opus-5-5), 2026-11-27. A proposal for the owner's review; once agreed, what's built goes into the systems' changelogs and pawn spec 15. -->

# Per-pawn GDScript cost (proposal)

**Status:** part A built 2026-11-28 (A5 built, measured and undone); B and C not started.

**As built: A saved about 0.44 ms a tick, not the 1.5 to 2 estimated.** Measured with the profiling suite (size 25, 3 runs each), against a baseline taken just before:

| Cut | Its timer, before → after (µs a call) | ms a tick saved |
|---|---|---|
| A1 timeline running list | AI behaviour steps 16.8 → 14.4 | 0.15 |
| A2 input-block check cached | 4.7 → 1.5 | 0.29 |
| A3 behaviour tick schedule as a deadline | `ai.behaviours` 5.4 → 4.7 | 0.04 |
| A4 locomotion pass | 6.5 → 6.0 | 0.03 |
| A5 move steps' repath interval once (undone) | Follow 9.2 → 8.4 | 0.01 |
| Whole tick, A1 to A5 | 10.96 ±0.34 → 10.51 ±0.10 | 0.45 |

- **The estimates were too high.** They came from a run with temporary timers whose names were built each call, which inflated the timeline's own share; the profiling suite's timers don't.
- **Today:** about 75 µs of GDScript per AI pawn per tick (AI 31, input 21, abilities 24). The rest is real work spread over many small calls (steps, the walk, sensing), so further GDScript cuts would each save little; B is where a large saving would come from.
- **A5 was undone:** 0.01 ms is within noise, and reading `repath_ticks` only as the step starts meant a designer's edit to a running step didn't apply. Move steps convert it each time again.
- `refresh_modifiers` (part of `ai.check_running`, 4.5 µs) was left: it already returns early, and what it costs is the calls around it.

## Today: what each pawn costs

The mass battle at size 25 (about 94 AI pawns, load step 1, 60 ticks a second, C++ deciding, `--scopes`), at commit b38098b.

**Whole phases** (ms a tick, no extra timers):

| Part | ms |
|---|---|
| Whole tick | 10.4 (62% of the budget) |
| Input phase | 4.9 |
| → AI step | 2.4 |
| → `pawn.input` (the controller and the behaviour's steps) | 2.0 |
| Simulate phase | 3.7 |
| → `pawn.abilities` | 1.9 |
| → crowd mover | 0.8 |
| Pawn spawns (respawns, averaged over frames) | 0.8 to 1.0 |

**Per pawn per tick** (µs). The first numbers came from a run with temporary finer timers. The bold totals are from the profiling suite, averaged over 3 runs (`tools/profiling/profile_mass_battle.py`, tick 10.94 ms ±0.25 with every timer on). A timer adds about 0.5 µs, so small rows are mostly the timer itself.

| Part | µs | Note |
|---|---|---|
| **AI step** | **32** | |
| → sensing | 6.5 | |
| → deciding | 8 | about 45 per decision, 9 decisions a tick; a behaviour switch is 60 to 130 |
| → `tick_running` (should the behaviour tick now?) | 5 | the behaviour itself ticks only every 5 ticks |
| → `check_running` | 5 | 3 of it is `refresh_modifiers`, every tick |
| → is this a decision tick? | 1.7 | |
| **Input** | **26** | |
| → the input-block tag check (`status.dead`) | 4.7 | a tag query every tick |
| → the behaviour's steps | 17 | |
| → → timeline bookkeeping | about 8 | it scans every entry twice and rebuilds the running list |
| → → the steps themselves | about 9 | Follow 9, KeepAwayFrom 7, MoveTo 6, LookAt 2.6, Hold 1.8 (per step) |
| → the controller and writing the input | 4 | |
| **Abilities** | **25** | |
| → actions | 12 | a running ability's steps are 16 a tick; a melee sweep is about 80 a tick; a fired bolt about 250 |
| → locomotion | 7 | the walk itself is 2.6; choosing which locomotion runs is about 4.6 |
| → the rest (deadlines, effects, input bookkeeping) | 5 | |

**In short:** each AI pawn costs about 83 µs a tick in GDScript. That's about 7.8 ms at 94 pawns. Much of it is bookkeeping done every tick even when nothing changed.

## Proposal

### A. GDScript cuts now (about 1.5 to 2 ms a tick at size 25)

The behaviour stays the same. These cuts follow the base's own rules (tick deadlines, work only when something changed). I'd measure each cut on its own.

1. **The timeline keeps a list of running entries.** It changes on start and stop, and is rebuilt after a rollback loads the state. The state array stays the record. Steps without a length skip the length and count work. *About 0.5 ms.*
2. **The input-block check is cached by the owned tags' version.** The query runs only when tags change. *About 0.35 ms.*
3. **AI schedules become tick deadlines.**
   - A behaviour's next tick is stored as the tick it's due. `ticks_at_rate` and `fired_since_last_run` are no longer worked out every tick.
   - `refresh_modifiers` runs only at its next deadline or on a change.
   - *About 0.4 ms.*
4. **A locomotion fast path.** With no locomotion action held and none running, the walk runs directly. *About 0.3 ms.*
5. **Move steps work out their constants once.** The repath interval in ticks is computed once, and positions are read once a tick. *About 0.2 ms.*

### B. Later: the common steps in C++ (not now)

At about 83 µs a pawn, GDScript tuning tops out well short of the netcode goal: 1,000 pawns needs roughly 10 µs a pawn. The scaling answer would follow the decider's pattern:
- A C++ twin runs the common steps (Follow, MoveTo, KeepAwayFrom, LookAt, Hold) and the walk for every pawn at once, from their values.
- Other steps stay in GDScript.

That's a design of its own. Per the brain-per-pawn direction (architecture first, batching per game), I'd leave it until after tier 0 and discuss it first.

### C. Seen in passing, not per pawn

- **Pawn spawns** cost 0.8 to 1 ms a frame on average (up to 8 a tick). Pooling would be a later item.
- **The melee sweep** (about 80 µs a tick while sweeping) and **firing a bolt** (about 250 µs) are worth a look of their own.
