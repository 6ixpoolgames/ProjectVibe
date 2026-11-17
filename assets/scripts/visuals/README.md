<!-- Written by Claude (claude-opus-5-5), 2026-11-17: the visuals system's overview, beside its code. -->

# Visuals

How pawns look in the toy style: figures that waddle like toys being played with, and swords that float beside them and swing exactly where the hits land.

**Status:** partly built, tier 0. Not yet: the modular animation system and the visuals manager (animation v0), which these will fold into.

| File | What it's for |
|---|---|
| [README.md](README.md) | This overview |
| [REFERENCE.md](REFERENCE.md) | Every class, setting and function, generated from the code's doc comments (`python tools/docs/make_reference.py visuals`) |
| [CHANGELOG.md](CHANGELOG.md) | What changed and why, newest first, and the refactor candidates |
| [PAWN_SPEC.md](../../../docs/pawn/PAWN_SPEC.md) | Section 8.12, the toy look |

## The pieces

```
 Pawn
 └─ Visual (follows the body smoothly)
    ├─ Model ─ ToyWaddle ─ the figure (toy_scene), its base
    └─ FloatingSword ─ the sword (sword_scene)
```

- **`ToyWaddle`**: makes the figure from a model scene, stands it on a coloured base, and rocks, hops, leans and topples it from how the pawn moves and what it's doing.
- **`FloatingSword`**: hovers at the pawn's side and swings through each MeleeAttackAbility's hit path (`hit_offset_at`), guards during a parry, and drops when the pawn dies.

Both only read the pawn, once a rendered frame. They're never simulated, rolled back or sent, and without a display they build nothing.

## How to use it

**Give a pawn a toy figure.** Add a `ToyWaddle` under the pawn scene's `Visual/Model`, set `toy_scene` to a model (a Kenney mini character, say) and `stand_color` to the team's colour.

**Give it a floating sword.** Add a `FloatingSword` under `Visual` (not `Model`, which rocks), and set `sword_scene`. Empty shows a plain box blade.

## Settings worth knowing

| Setting | Where | Default | What it does |
|---|---|---|---|
| `toy_scene`, `toy_scale` | `ToyWaddle` | empty, 2.2 | The model and how much bigger it's drawn |
| `stand_color` | `ToyWaddle` | gold | The base's colour; clear for no base |
| `rock_degrees`, `hop_height` | `ToyWaddle` | 10°, 0.09 m | How much it waddles at walking speed |
| `sword_scene`, `sword_scale` | `FloatingSword` | empty, 2.2 | The sword and how much bigger it's drawn |
| `hover_side`, `hover_height` | `FloatingSword` | 0.8, 1.0 m | Where it hovers |

## How it works

- **FloatingSword**, frame by frame: hovering (at the pawn's side, chest high, bobbing and swaying); a swing through its phases (windup pulls back to just behind where the hit starts, hit sweeps the blade out from the chest through each spot the hit checks, recovery drifts back); a parry (guards flat across in front of the chest for as long as the parry runs); dead (lies on the ground beside the pawn). Combo swings alternate: after a swing it rests on the side where the swing ended (a swing ending on the left leaves it on the left, so the next sweeps left to right; a chop ending in the middle leaves it where it was), and after `return_seconds` with no swing it goes back to the right, round the front of the pawn.
- **ToyWaddle** moves only itself: the pawn turns `Visual/Model`, and this sits inside it, so "forward" is the pawn's forward and its origin is at the feet. The step rate grows with speed (`steps_per_metre`). `toy_scene` is instanced at `toy_scale` (turned round if `turn_model_round` is on), and the first frame of `pose_animation` holds the model still.
- Both are visual only, so they need no rollback and work the same on the server, a predicting client and a client drawing other pawns; with no display they build nothing (`RunEnvironment.runs_visuals`).

## Tests

`visuals/tests/visuals_selftest`. Run it with `bash tools/run_tests.sh visuals`.
