<!-- Written by Claude (claude-opus-5-5), 2026-11-17: the controllers system's overview, beside its code. -->

# Controllers

Who drives a pawn: a player or the AI makes one input command a tick, and the pawn's abilities turn it into movement. A player and the AI can take turns on the same pawn.

**Status:** built, tier 0. Not yet: anti-cheat beyond the server's basic input checks.

| File | What it's for |
|---|---|
| [README.md](README.md) | This overview: what's here and how to use it |
| [REFERENCE.md](REFERENCE.md) | Every class, setting and function, generated from the code's doc comments (`python tools/docs/make_reference.py controllers`) |
| [CHANGELOG.md](CHANGELOG.md) | What changed and why, newest first, and the refactor candidates |
| [PAWN_SPEC.md](../../../docs/pawn/PAWN_SPEC.md) | The pawn's design: inputs (section 5), controllers (6), the input on the ControllerManager (8.17) |

## The pieces

```
 PlayerController (player/) ─┐                         ┌─► move_input, held_actions, look ─► abilities
                             ├─► ControllerManager ────┤      (rolled back, sent over the network)
 AIController ◄── behaviours ┘   (on the pawn)         └─► has_player, possession_changed
```

- **`InputCommand`**: one tick's input as plain values: a move direction, a look, and held actions as bits. Nothing else carries what a pawn wants between ticks.
- **`InputActions`**: action names (`jump`, `sprint`...) to bits, from the list in `resources/input_actions.tres`, the same on every machine.
- **`ControllerBase`**: what every controller extends. Its one job is `take_input_command(tick)`.
- **`ControllerManager`**: a part on every pawn. Picks who's in charge (this machine's player, else nobody if a remote player has it, else the AI), copies their command into the pawn's input, tells presses from holds, and holds whether a player has the pawn. Input is blocked by tags: while the pawn owns a tag `input_blocked_by` matches (`status.dead` by default) its input is cleared, whoever is in charge; with nobody in charge (no controller here, no player elsewhere) it's cleared too, rather than the last input repeating (pawn spec 16.4). On the server it cleans a client's input and covers missing input.
- **`AIController`**: the AI's hands, a child of the ControllerManager. The AI's behaviours tell it to walk somewhere, press or hold an action, or look at a point, and it builds the command. These calls are the AI's **orders**: `AIController.order_listener` sees each one, and the same orders at the same point of the same ticks give the same input, which is what lets a recorded order stream rebuild a battle (netcode spec 19.10).

## How to use it

**Add an input action.** Add its name to `resources/input_actions.tres`, and to Godot's Input Map if a key presses it. An action missing from the list warns, and gets no bit online.

**Read input in an ability.** `pawn.controller_manager.was_action_pressed(&"jump")`, `is_action_held(&"sprint")` and `move_input` (abilities also have helpers for these).

**Drive a pawn from AI code.**
```gdscript
var ai := pawn.controller_manager.ai_controller as AIController
ai.move_to(target)     # false if there's no way there
ai.press(&"attack")    # one press, this tick
ai.follow(target, 1.2) # keeps closing in on target until told otherwise
```
`follow` and `keep_distance` are persistent orders: given once, carried out at every input from where the target really is, which every machine knows, so an order stream sends one rather than one a tick (netcode spec 19.10). A move order ends them. A dead pawn's AIController takes no orders (they're ignored, and the order listener never hears them), and lets go of what it was told as its pawn dies (`let_go`, on `died`), so it comes back from a revive with no orders. While a player has the pawn but the AI keeps deciding, `move_to` only remembers the point (and returns true), so it can't overwrite the player's path.

**Make a pawn players can't take.** Untick `possessable` on its ControllerManager. If the part comes from the defaults, add `parts/ControllerManager.tscn` to the pawn scene first.

**Write your own controller.** Extend `ControllerBase` and override `take_input_command(tick)`; return the same command shape a player makes.

## Settings worth knowing

| Setting | Where | Default | What it does |
|---|---|---|---|
| `possessable` | `ControllerManager` | on | Whether a player may take this pawn |
| `input_blocked_by` | `ControllerManager` | any of `status.dead` | Owned tags that clear the pawn's input (a stun, a cutscene) |
| `missing_input_hold_ticks` | `ControllerManager` | -1 (NetworkSession's, 3) | On the server, how long a client's last input repeats when one goes missing |
| `missing_input_fade_ticks` | `ControllerManager` | -1 (NetworkSession's, 6) | Then how long its direction takes to fade out |

## How it works

- **While the AI isn't in charge** (a player has the pawn, but the AI keeps deciding: `AIContextComponent.while_possessed` FULL), `AIController.move_to()` only remembers the point and returns true, so it can't overwrite the player's path. The walk starts when the AI is in charge again. `stop()`, `move_in_direction()` and `release_all()` forget it. `is_following_order()` says whether its own last `move_to` is still under way.
- **The input rolls back.** The pawn's `TickStateComponent` lists `ControllerManager:move_input` and the others as input, and `previous_held_actions` as state. The ControllerManager is its NetworkEntity's `input_owner`, so the server's checks on a client's input (`sanitize_network_input`, `_network_input_missing`) live here.
- **Odd cases** (`tests/controller_manager_selftest.gd`): a parent that isn't a Pawn warns and nobody is in charge; no AIController child leaves an unpossessed pawn with nobody in charge, and its input cleared; a tag `input_blocked_by` matches clears the input; a freed player controller is ignored; control changing hands drops the pawn's path. A pawn without a ControllerManager has no input and can't be possessed.
- **Unlisted input actions** (`tests/input_actions_selftest.gd`): with no list file the list starts empty and each action is added as first seen, with a warning. Offline, an unlisted action is added at the end with a one-time warning; in a network session it gets no bit (never held), because machines adding names in a different order would disagree. A blank name has no bit; past 64 actions the extras get none.

## Tests

`controllers/tests/`: `controller_manager_selftest` (who's in charge, paths dropped on a change of hands, odd cases), `input_actions_selftest` (bits, the list, unlisted actions). Possession end to end is `pawn/tests/possession_selftest`. Run them with `bash tools/run_tests.sh <name>`.
