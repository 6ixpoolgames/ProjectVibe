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
- **`AIController`**: the AI's hands, a child of the pawn's AIManager (`pawn.ai.controller`); the ControllerManager reads it from there and puts it in charge while no player has the pawn. It follows no orders of its own: each tick it's asked for input it runs the running AI behaviour's step timeline, whose move, look and button steps write the command (pawn spec 16.7). What no step wrote comes from a script's walk (`move_to`) or its direct input (`move_in_direction`, `look_at_point`, `press`, `hold`), for scripts and tests; else the pawn stands with its own look. The AI's orders are its behaviours starting steps (`AIBehaviourManager.order_listener`), which is what lets a recorded order stream rebuild a battle (netcode spec 19.10).

## How to use it

**Add an input action.** Add its name to `resources/input_actions.tres`, and to Godot's Input Map if a key presses it. An action missing from the list warns, and gets no bit online.

**Read input in an ability.** `pawn.controller_manager.was_action_pressed(&"jump")`, `is_action_held(&"sprint")` and `move_input` (abilities also have helpers for these).

**Drive a pawn from AI code.** A behaviour starts steps (`start_step(&"Follow", {"target": target})`; the ai and steps READMEs). A script or test without behaviours can drive the controller directly:
```gdscript
var ai := pawn.controller_manager.ai_controller as AIController
ai.move_to(target)                 # a walk along a nav path; false if there's no way there
ai.press(&"attack")                # one press, this tick
ai.move_in_direction(Vector3.LEFT) # keeps walking that way
```
The running behaviour's steps come first, then the script's walk, then direct input. A dead pawn's AIController takes no direct input, and lets go of what it was given as its pawn dies (`let_go`, on `died`), so it comes back from a revive holding nothing; the running behaviour stops as the pawn dies, and its steps with it. A script's walk runs on its own `step_host` (a `MoveToStep`, as the player's click-to-move).

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

- **While the AI isn't in charge** (a player has the pawn, but the AI keeps deciding: `AIManager.while_possessed` FULL), its behaviours still start steps, but nothing runs them: only the controller in charge is asked for input. Charge changing hands drops the running move step's path, and it finds a new one once the AI is in charge again; a script's walk ends, as the player's click-to-move does. `is_walking()` says whether a script's walk is under way.
- **The input rolls back.** The pawn's `TickStateComponent` lists `ControllerManager:move_input` and the others as input, and `previous_held_actions` as state. The ControllerManager is its NetworkEntity's `input_owner`, so the server's checks on a client's input (`sanitize_network_input`, `_network_input_missing`) live here.
- **Odd cases** (`tests/controller_manager_selftest.gd`): a parent that isn't a Pawn warns and nobody is in charge; no AIController child leaves an unpossessed pawn with nobody in charge, and its input cleared; a tag `input_blocked_by` matches clears the input; a freed player controller is ignored; control changing hands has both controllers drop their paths (`drop_path`). Each controller follows its own path (`get_path_follower`); `ControllerManager.get_path_follower()` gives the one in charge's.
- **The step host** (`ControllerStepHost`): a controller's child that runs steps writing that controller's input, on a timeline of manual entries, on its machine only. The player controller's click-to-move is a `MoveToStep` on one. A pawn without a ControllerManager has no input and can't be possessed.
- **Unlisted input actions** (`tests/input_actions_selftest.gd`): with no list file the list starts empty and each action is added as first seen, with a warning. Offline, an unlisted action is added at the end with a one-time warning; in a network session it gets no bit (never held), because machines adding names in a different order would disagree. A blank name has no bit; past 64 actions the extras get none.

## Tests

`controllers/tests/`: `controller_manager_selftest` (who's in charge, paths dropped on a change of hands, odd cases), `input_actions_selftest` (bits, the list, unlisted actions). Possession end to end is `pawn/tests/possession_selftest`. Run them with `bash tools/run_tests.sh <name>`.
