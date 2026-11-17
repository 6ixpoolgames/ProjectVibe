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

## Tests

`visuals/tests/visuals_selftest`. Run it with `bash tools/run_tests.sh visuals`.
