<!-- Written by Claude (claude-opus-5-5), 2026-11-17: the movement system's overview, beside its code. -->

# Movement

Moves crowds cheaply: AI pawns walking on the ground are moved together once a tick, kept apart by separation and walked along the nav mesh, instead of each one running Godot's physics move.

**Status:** built, tier 0. Not yet: crowd movement on clients or for players' pawns (they always move by physics).

| File | What it's for |
|---|---|
| [README.md](README.md) | This overview |
| [REFERENCE.md](REFERENCE.md) | Every class, setting and function, generated from the code's doc comments (`python tools/docs/make_reference.py movement`) |
| [CHANGELOG.md](CHANGELOG.md) | What changed and why, newest first |
| [PAWN_SPEC.md](../../../docs/pawn/PAWN_SPEC.md) | Section 8.22, the crowd mover's design |

## The pieces

```
 each AI pawn's simulate ─► CrowdMover.try_take_move ─► queued
 after every pawn:  CrowdMover ─► CrowdBatch (C++, worker threads): move, separate, walk the nav mesh
                               └► physics sweep and ray for pawns it hands back
                    ─► Pawn.finish_crowd_move   or   Pawn.finish_move_by_physics
```

- **`CrowdMover`**: a GameMode module (`GameMode.crowd_mover`, also `CrowdMover.current`). It decides which pawns it moves, runs the batch last in the simulate phase, and finishes each pawn's tick.
- **`CrowdBatch`** (C++, `native/`): the batch on worker threads, with walls from the nav mesh. Without the library, a GDScript batch does the same with physics sweeps.

Who it moves: an AI pawn, on the server or offline, on the ground, not jumping, with no Dash or Knockback running, and `crowd_movement` on. Everything else moves by physics, as does any pawn the batch can't place (a wall, no ground, too steep).

## How it works

A pawn the AI drives still runs its abilities and gravity (Walk and Sprint set its velocity from the AI's input). Then, instead of `move_and_slide` (about 24 microseconds a pawn, one of a tick's biggest costs in the mass battle), it hands its move to `try_take_move` and waits. `CrowdMover` runs last in `TickDriver`'s simulate phase (`TICK_ORDER`), after every pawn: it moves each by its velocity for the tick, flat; pushes pawns apart where they overlap (separation, from a grid of cells built once a tick); then checks walls and stands each on the ground. Each pawn then finishes its tick (`Pawn.finish_crowd_move`) or, where a check failed, moves by physics at once (`Pawn.finish_move_by_physics`), which handles the edge, the wall or the fall properly.

**Separation.** AI pawns don't collide with each other physically. Two crowd pawns each take half the push; a pawn moving by physics (a player's, one in the air) doesn't move, so a crowd pawn takes all of it.

**Walls and ground, in C++.** With the navcore library the batch runs in `CrowdBatch` on the job scheduler's worker threads. Walls come from the nav mesh: a pawn on it walks along it (Detour's `moveAlongSurface` for its nav tier, Unreal's NavWalking), sliding along an edge instead of being handed to physics at a wall, and the ground comes from `SightGeometry`'s copy of the level. A pawn it can't walk that way (no nav mesh under it, a body wider than its tier's radius, or crossing a nav link) gets the physics checks. See `crowd_batch.h`.

**Walls and ground by physics** (the GDScript batch, `_move_batch`, used without the library and for the pawns the C++ batch hands back; it must give the same answer as `CrowdBatch`): the pawn's collision shape is swept along the move, lifted by the step it may climb, against the level (not pawns), then one ray goes down where it ends up. Anything taller than the step blocks the sweep; anything lower is a step the ray stands it on. No ground, a step or slope too steep, a wall, or no collision shape: it moves by physics instead.

**Who it moves** (`try_take_move`): an AI pawn, on the server or offline, on the ground, with no ability running that wants full movement (`AbilityBase.needs_full_movement`: Dash and Knockback), and its own `crowd_movement` on. A player's pawn, anything on a client and anything in the air always moves by physics, so prediction and rollback, which only clients do and only for their own pawn, never meet this. A rollback replay, or a test calling a pawn's `_tick_simulate` itself, also moves by physics, since the mover wouldn't run until the next tick.

## How to use it

**Turn it on or off.** It's in the project's GameMode modules by default (the project setting `project_base/game_mode/modules`). Its `enabled` and `separation_strength` are in the start menu's match options.

**Keep one pawn on physics.** Untick `crowd_movement` on that pawn.

**Let pawns squeeze through each other.** Lower `separation_strength`; 0 lets them walk through each other.

**See what it costs.** F4 shows `movement.crowd`, `movement.crowd_queries` and `movement.crowd_fallbacks`.

## Settings worth knowing

| Setting | Where | Default | What it does |
|---|---|---|---|
| `enabled` | `CrowdMover` | on | Off: every pawn moves by physics |
| `separation_strength` | `CrowdMover` | 1 | How much of an overlap is pushed apart each tick |
| `separation_margin` | `CrowdMover` | 0.1 m | Gap kept between pawns |
| `max_step` | `CrowdMover` | 0.4 m | How far up or down a pawn may step in one move |
| `use_cpp_batch` | `CrowdMover` | on | The C++ batch, walls from the nav mesh |
| `crowd_movement` | `Pawn` | on | This pawn may be moved by the crowd mover |

## Tests

`movement/tests/crowd_mover_selftest` (who it moves, separation, walls, edges, fallbacks), and `crowd_query_measure` (timings of its sweeps and rays). Run them with `bash tools/run_tests.sh <name>`.
