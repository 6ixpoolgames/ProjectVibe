<!-- Written by Claude (claude-opus-5-5), 2026-11-17: the controllers system's running changelog. History leaves the code comments and
lives here, next to the code. Newest first. -->

# Controllers changelog

Controllers are this folder: `ControllerBase`, `InputCommand`, `InputActions` (with `resources/input_actions.tres`), `ControllerManager` and `AIController`. The player's controller is in `player/`. Design: [docs/pawn/PAWN_SPEC.md](../../../docs/pawn/PAWN_SPEC.md) sections 5, 6 and 8.17. Overview: [README.md](README.md).

## Refactor candidates

Code that works but doesn't yet fit the project's goals (reusable, extensible, efficient, designer friendly). Each is marked `REFACTOR:` in the code. Sizes are rough: S an hour or two, M a day, L more.

| What | Where | Why | Size |
|---|---|---|---|
| Move the test hooks out of `InputActions` | `reset()`, `use_list()` in `InputActions.gd` | Test hooks in a shipping class; the owner's rule keeps test code in `tests/` | S |
| Share the missing-input defaults | `_network_input_missing()` in `ControllerManager.gd` | 3 and 6 copy `NetworkSession`'s defaults by hand, so the two can drift apart | S |

## 2026-11-17

- **`possessable` moved here** from Pawn, with the rest of possession (the owner's call). A pawn scene whose ControllerManager comes from the defaults adds `parts/ControllerManager.tscn` itself to untick it.
- **Comments cleaned up** for the documentation pass: dated notes moved here, doc comments in Godot's markup. Stale comments fixed: `ControllerBase` said only PlayerController extended it; `AIController` said a script or test drives it until step 8 (the AI's behaviours do); `InputCommand` and `AIController` said the pawn copies the command (the ControllerManager does); `ControllerManager` said the pawn calls `take_input_command()` (it calls `tick_input()`).

## 2026-11-16

- **Input and possession on the ControllerManager** (pawn M4, pawn spec 8.17, the owner's call). This tick's input (`move_input`, `held_actions`, `look_yaw`, `look_pitch`, `view_ticks_behind`), `previous_held_actions`, `is_action_held`, `was_action_pressed`, `has_player`, `set_has_player`, `possession_changed`, and the server's checks on a client's input (`sanitize_network_input`, `_network_input_missing`, as the NetworkEntity's `input_owner`) moved here from Pawn. `tick_input()` asks the controller in charge where the input is decided here.
- **The AI's hands let go on death** (pawn M3): the ControllerManager listens to the AbilityManager's `died`, where Pawn used to do it.
- **Waiting paths.** `AIController` asks for a direction while the path is under way (`is_under_way`), so a path waiting for nav (PENDING) tries again; `is_following_order` counts that wait.

## 2026-11-12

- A warning's pawn name goes through `String()`, so both sides are text; `ControllerBase.pawn_changed` is marked as sent by subclasses, so the editor doesn't warn.

## 2026-11-09

- **The AI while not in charge** (pawn spec 6.3 and 10.3): with `while_possessed` FULL, `AIController.move_to` only remembers the point and starts it when in charge again; it never touches the player's path. `is_following_order()`, `is_looking_at_point()`.
- **`InputCommand.view_ticks_behind`** for melee lag compensation (pawn step 9).

## 2026-11-08

- **`AIController.move_to`** walks a nav path through the pawn's NavigationManager, and presses a link's action (pawn step 7). The ControllerManager drops a path the moment control changes hands, so the AI never walks the rest of a player's click.

## 2026-11-07

- **Inputs instead of intent** (pawn spec section 5): `InputCommand`, one tick's input as plain values; `InputActions`, named actions as bits from a declared list; `ControllerBase`, with `take_input_command()` ("take", since it may use up presses).
- **`ControllerManager` and `AIController`** (pawn spec steps 3 and 4): the fixed rule for who's in charge, and the AI's hands. `possessable` is on by default (the owner's choice). The AI keeps the pawn's own look until told where to look.
- **`InputActions` audit fixes**: the copy of the list in code is gone, so the file is the only list; an unlisted action used online gets no bit, since machines could disagree.
