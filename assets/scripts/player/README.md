<!-- Written by Claude (claude-opus-5-5), 2026-11-17: the player system's overview, beside its code. -->

# Player

One player's side of the game: reading their keys and mouse, aiming their camera, driving whichever pawn they have, and flying a spectator camera when they have none.

**Status:** partly built, tier 0. Not yet: gamepads, and remappable keys for moving and the mouse buttons.

| File | What it's for |
|---|---|
| [README.md](README.md) | This overview: what's here and how to use it |
| [REFERENCE.md](REFERENCE.md) | Every class, setting and function, generated from the code's doc comments (`python tools/docs/make_reference.py player`) |
| [CHANGELOG.md](CHANGELOG.md) | What changed and why, newest first, and the refactor candidates |
| [PLAYER_AND_CAMERA.md](../../../docs/pawn/PLAYER_AND_CAMERA.md) | Possession, cameras, the world cursor and the game mode |

## The pieces

- **`PlayerController`**: one per player, made by `game_mode/PossessionCoordinator`, and alive with or without a pawn. Each tick the pawn's ControllerManager asks it for an `InputCommand`. It owns the player's camera (`camera/PlayerCamera`) and one camera arm, which it moves to each pawn it takes. With no pawn it can fly a `camera/FreeFlyCamera`.
- **`WorldCursor`**: what the mouse or crosshair points at, a child of the controller. It costs nothing until something asks.

```
 keys, mouse ─► PlayerController ─► InputCommand ─► pawn's ControllerManager
                 ├─ PlayerCamera, CameraArm (moves to the pawn's CameraMount)
                 ├─ WorldCursor
                 └─ FreeFlyCamera (while spectating)
```

## How to use it

**Take or let go of a pawn.** Ask the PossessionCoordinator; it tells the controller. Never call `take_pawn` yourself.

**Map a key to an action.** Add an entry to `action_keys`: the named action (from `resources/input_actions.tres`) on the left, the Input Map action on the right.

**Click to move.** Tick `click_to_move`; a click on the ground walks the pawn there along a nav path. Keys take over from it.

**Ask what's under the mouse.**
```gdscript
var hit := controller.world_cursor.query_now()   # {"position", "normal", "collider"}, or empty
```

**Spectate.** `PossessionCoordinator.spectate()`; taking a pawn ends it. The arena samples' U key does this.

## Settings worth knowing

| Setting | Where | Default | What it does |
|---|---|---|---|
| `look_mode` | `PlayerController` | CAPTURED | Mouse captured, or turning at the screen's edge |
| `mouse_sensitivity` | `PlayerController` | 0.0025 | Radians per pixel |
| `action_keys` | `PlayerController` | jump, sprint, dash, primary | Which Input Map key presses which named action |
| `click_to_move` | `PlayerController` | off | Clicking the ground walks there |
| `spectator_scene` | `PlayerController` | empty (a default FreeFlyCamera) | The spectator camera |
| `collision_mask` | `WorldCursor` | 3 | What the cursor's ray hits: ground and pawns |

## Tests

`player/tests/world_cursor_selftest`. Taking and letting go of pawns, and spectating, are in `pawn/tests/possession_selftest`. Run them with `bash tools/run_tests.sh <name>`.
