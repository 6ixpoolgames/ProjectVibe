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
