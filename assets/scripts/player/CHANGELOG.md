<!-- Written by Claude (claude-opus-5-5), 2026-11-17: the player system's running changelog. History leaves the code comments and lives
here, next to the code. Newest first. -->

# Player changelog

The player system is this folder: `PlayerController` (one player's controls) and `WorldCursor` (what the mouse points at). `game_mode/PossessionCoordinator` creates the controller; the camera pieces are in `camera/`. Design: [docs/pawn/PLAYER_AND_CAMERA.md](../../../docs/pawn/PLAYER_AND_CAMERA.md) and [docs/pawn/PAWN_SPEC.md](../../../docs/pawn/PAWN_SPEC.md) sections 6.2 and 8.18. Overview: [README.md](README.md).

## Refactor candidates

Code that works but doesn't yet fit the project's goals (reusable, extensible, efficient, designer friendly). Each is marked `REFACTOR:` in the code. Sizes are rough: S an hour or two, M a day, L more.

| What | Where | Why | Size |
|---|---|---|---|
| Settings for the InputMap names | `PlayerController` (`move_left`..., `scrollWheel_up`, `left_click`, `middleMouse_button`) | Written in the code, unlike `action_keys`; a designer can't remap them without code | S |
| One shared path-following helper | `PlayerController.take_input_command`, `controllers/AIController.take_input_command` | Following a path and pressing a link's action is written out twice | S |

## 2026-11-18

- **Comments rewritten to the reference style** (the documentation pass): the `PlayerController` and `WorldCursor` class comments shortened (spectating and the odd cases moved to the README's "How it works"). `GDScript note:` teaching comments removed, keeping any non-obvious fact shortened.

## 2026-11-17

- **Comments cleaned up** for the documentation pass: dated notes moved here, doc comments in Godot's markup. Stale comments fixed: the description said the pawn's movement module moves it (its abilities do).

## 2026-11-16

- **One camera arm per player** (pawn M5, pawn spec 8.18): the controller owns its arm and moves it to each pawn it takes, to the pawn's CameraMount with its preset; a pawn's own placed arm or view is used as it is.
- **Spectating** (the owner's request): `start_spectating`, `stop_spectating`, `place_spectator`, `is_spectating`, `get_spectator`, flying a FreeFlyCamera (`spectator_scene`) with the same keys and mouse. Up and down are the jump and crouch keys (`fly_up_key`, `fly_down_key`, the owner's call, instead of Q and E). With sprint held the wheel changes the fast speed; on its own it zooms, and the mouse turns slower when zoomed. The middle mouse button resets the zoom.
- **Click-to-move waits for nav**: a click waiting for nav (PENDING) is followed too (`is_under_way`).

## 2026-11-09

- **Dash and primary** (Left Alt, the left mouse button) in `action_keys` (pawn step 9), and `view_ticks_behind` sent for lag compensation.

## 2026-11-08

- **Click-to-move on the NavigationManager** (pawn step 7): the path lives on the pawn's NavigationManager, not here, and crosses links, pressing their action. A click with no way there does nothing, rather than walking straight at it.

## 2026-11-07

- **PlayerController and WorldCursor** (PLAYER_AND_CAMERA.md): the controller survives with no pawn; the cursor costs nothing until asked.
- **Inputs instead of intent** (pawn spec section 5): it extends `ControllerBase`, and builds an `InputCommand` with named actions mapped from keys (`action_keys`, replacing the fixed reads of jump and sprint). The pawn's ControllerManager asks it for input, so it no longer ticks itself. Presses are kept only with a pawn, so a press with no pawn never jumps the next one. `cursor` renamed `world_cursor`.
