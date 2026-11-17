<!-- Written by Claude (claude-opus-5-5), 2026-11-17: the visuals system's running changelog. History leaves the code comments and lives
here, next to the code. Newest first. -->

# Visuals changelog

Visuals are this folder: `ToyWaddle` and `FloatingSword`, visual-only pawn parts for the owner's "playing with my toys" look. They read the pawn once a rendered frame and are never simulated or rolled back. Models are Kenney's (CC0) in `assets/3d/`. Design: [docs/pawn/PAWN_SPEC.md](../../../docs/pawn/PAWN_SPEC.md) section 8.12. Overview: [README.md](README.md).

## Refactor candidates

Code that works but doesn't yet fit the project's goals (reusable, extensible, efficient, designer friendly). Each is marked `REFACTOR:` in the code. Sizes are rough: S an hour or two, M a day, L more.

| What | Where | Why | Size |
|---|---|---|---|
| A shared base for per-frame pawn visuals | `_find_pawn()` and `_bind()` in `ToyWaddle` and `FloatingSword` | The same pawn search and first-frame binding written twice | S |
| Abilities report a pose, instead of being found by class | `FloatingSword._bind()`, `_running_swing()`, `_running_parry()` | It knows MeleeAttackAbility and ParryAbility by class, so a new attack or guard needs code here. Fits the modular animation work on the roadmap | M |

## 2026-11-18

- **Comments rewritten to the reference style** (the documentation pass): the `FloatingSword` and `ToyWaddle` class comments shortened (the frame-by-frame description and the combo-side rule moved to the README's "How it works"; the owner's toy look is here). `GDScript note:` teaching comments removed, keeping any non-obvious fact shortened.

## 2026-11-17

- **Comments cleaned up** for the documentation pass: dated notes moved here, doc comments in Godot's markup. Stale comments fixed: `FloatingSword` said what it shows is a swing's id only (a parry's id counts too); `ToyWaddle` pointed at `_process` for the lean's sign (it's in `_animate`).

## 2026-11-16

- **Not built without a display** (the owner's call not to track the sword on a server): with no display, neither builds anything nor runs (`RunEnvironment.runs_visuals`). A host in a window still draws them.
- **The swing's place from its steps** (pawn spec 8.20): `FloatingSword` reads `swing_phase()`, not ticks since the swing started, since a windup can wait for its turn.
- **Diagnostics:** both are timed with `PerfScopes`, in the animation category (`animation.waddle`, `animation.sword`; were `visuals.*`). The wider audit made `FloatingSword` read the pawn once a frame, since `swing_phase()` makes a new Dictionary each call.

## 2026-11-15

- **Parry guard** (pawn spec 8.15): while a ParryAbility runs, the sword guards in front of the chest (`guard_forward`, `guard_height`).

## 2026-11-12

- **`ToyWaddle` and `FloatingSword`** (pawn spec 8.12, the owner's request): figures that rock, hop, lean into dashes, tip back from knockback and fall over when dead, on a coloured base; a sword hovering beside the pawn that swings through exactly the spots the hit checks. After a swing the sword rests on the side it ended, so combo swings alternate (the owner's request), and goes back to the right after `return_seconds`. `ToyWaddle`'s easing variable is named `blend`, since `ease` is one of Godot's functions.
