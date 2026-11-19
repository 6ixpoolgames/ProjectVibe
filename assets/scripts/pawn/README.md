<!-- Written by Claude (claude-opus-5-5), 2026-11-17: the pawn system's overview, beside its code. -->

# Pawn

The body every character is: something a player or the AI can drive. It runs its parts (input, AI, abilities, effects) in a fixed order each tick, then moves.

**Status:** built, tier 0; being slimmed down for the state store refactor (state store spec 12.8). Smoothing is in `VisualSmoother` and the shared table in `SharedPawnTable`. Not yet: the tick stepping in the tick driver, part-finding in the `PawnInitializer`, and a home for the streaming source contract.

| File | What it's for |
|---|---|
| [README.md](README.md) | This overview: what's here and how to use it |
| [REFERENCE.md](REFERENCE.md) | Every class, setting and function, generated from the code's doc comments (`python tools/docs/make_reference.py pawn`) |
| [CHANGELOG.md](CHANGELOG.md) | What changed and why, newest first, and the refactor candidates |
| [PAWN_SPEC.md](../../../docs/pawn/PAWN_SPEC.md) | The pawn's design: node tree, inputs, controllers, abilities, stats, AI, the tick rules (section 15) |
| [PLAYER_AND_CAMERA.md](../../../docs/pawn/PLAYER_AND_CAMERA.md) | Possession, cameras, the world cursor and the game mode |

## The pieces

```
 Pawn (CharacterBody3D, pawn.tscn)
 ├─ ControllerManager ─ AIController     input: who's in charge, this tick's input, has_player   (controllers/)
 ├─ NavigationManager                    paths                                                    (navigation/)
 ├─ StatManager, EffectManager           numbers, and effects on them                             (stats/, effects/)
 ├─ AbilityManager ─ Walk, Jump, Sprint  steer the pawn; hits and death                           (abilities/)
 ├─ AIContextComponent and the AI parts  decide what the AI's hands do                            (ai/)
 ├─ TickStateComponent, NetworkEntity    rollback and multiplayer (in the scene)                  (netcode/)
 └─ Visual ─ Model, CameraMount          placed smoothly each frame by the VisualSmoother part        (visuals/, camera/)
```

Each tick, in the **input phase**: the AI runs, then the ControllerManager asks whoever is in charge for input. In the **simulate phase**: effects count down, abilities write velocity and facing, gravity is added, and the pawn moves with one `move_and_slide`, or hands the move to its `mover` (the `CrowdMover`, `movement/`, set by the `PawnInitializer`), which then finishes it (`finish_move`, or `move_by_physics_now` where the crowd can't). The state store records it at the tick's end: a pawn on a load step is copied forward on ticks it skips, and its team, tick step and stats' current values are pushed when they change. Each rendered frame, the `VisualSmoother` places Visual between the last two runs.

`PawnInitializer` (`game_mode/`) adds every default part the scene doesn't have, from `resources/pawn_defaults.tres`. The pawn itself holds only the body, its tick order, its part references and general flags: `dead`, frozen, sleeping, `tick_step`.

Three states that are easy to mix up:
- **Sleeping**: standing still with nothing to do, it skips its abilities and physics until something wakes it (`sleep_when_idle`).
- **Frozen**: the AI switch-off stops it ticking at all where no ground is loaded around it (`set_frozen`).
- **Paused**: the whole game, not one pawn.

## How to use it

**Make a pawn.** Inherit from `assets/scenes/pawn/pawn.tscn`. Give it parts of its own (an AbilityManager with your abilities, say) and the defaults fill in the rest. `skip_default_parts` leaves one out; `fill_in_default_parts` off takes none.

**Put it on a team.** Set `team`. AI sensing only notices pawns on other teams, and a player who takes it plays for that team.

**A hero that keeps the world loaded.** Tick `keeps_world_loaded`. Without it, an AI pawn freezes wherever nothing else keeps the ground loaded, which is what a horde wants.

**Find every pawn.**
```gdscript
for node in get_tree().get_nodes_in_group(Pawn.GROUP):
    var pawn := node as Pawn
```

**Reach a part.** `pawn.controller_manager`, `pawn.ability_manager`, `pawn.stat_manager`, `pawn.effect_manager`, `pawn.navigation_manager`, `pawn.ai_context` (null when the pawn hasn't got one).

## Settings worth knowing

| Setting | Where | Default | What it does |
|---|---|---|---|
| `team` | `Pawn` | 0 | Which side it's on |
| `keeps_world_loaded` | `Pawn` | off | Keeps the world loaded around it without a player |
| `fill_in_default_parts` | `Pawn` | on | The game's default parts fill in what the scene lacks |
| `skip_default_parts` | `Pawn` | empty | Default parts to leave out, by name |
| `gravity` | `Pawn` | -1 (project's) | How strongly it falls |
| `sleep_when_idle` | `Pawn` | on | A still pawn with nothing to do skips its tick |
| `crowd_movement` | `Pawn` | on | An AI pawn walking on the ground moves with the crowd, not by physics |
| `skip_move_when_still` | `Pawn` | on | A still pawn that's awake skips its physics move |
| Detectability | the pawn's StatManager | 1 | How easy it is for AI to see (0 invisible) |

## How it works

- **Scene.** All optional: an `AbilityManager` (with none, nothing steers it and it only falls), a `TickStateComponent` and `NetworkEntity` (rollback and multiplayer; they stay in the scene because `NetworkSession` reads them before the pawn joins the tree) and a `Node3D` called `Visual`. `pawn.tscn` puts bodies on collision layer 2, colliding with layers 1 and 2; the ground is on layer 1, so a camera arm can tell the ground from a pawn walking past.
- **Visual exists** because the body moves in ticks and gets corrected, which looks jerky. Visual follows it smoothly per rendered frame and fades corrections out, so anything on screen hangs from it.
- **Where things live** (they used to be on the pawn): input, presses and whether a player has the pawn on `ControllerManager` (`move_input`, `has_player()`, `possessable`); hits, death and their signals on `AbilityManager` (`died`); camera pieces on `CameraMount`; team counts in `TeamRegistry`; Health on `StatManager`.
- **Odd cases** (`tests/pawn_selftest.gd`): with no `TickDriver` it ticks itself from `_physics_process`; an AI pawn in unloaded ground is frozen by `AIActivationManager` and keeps all its state.

## Tests

`pawn/tests/`: `pawn_selftest` (input, presses, rollback, odd cases), `possession_selftest`, `tick_step_selftest` (every 2nd or 4th tick), `pawn_table_selftest` (the C++ table), `rollback_coverage_selftest` (anything that changes in play without rolling back), `net_pawn_selftest` (real connections, about 4 minutes), and `pawn_stress` (what whole pawns cost per tick, about 5 minutes). Run them with `bash tools/run_tests.sh <name>`.
