<!-- Written by Claude (claude-opus-5-5), 2026-11-17: the AI system's overview, beside its code. -->

# AI

The brain on each computer-run pawn: it notices enemies by sight, remembers them with awareness that fades (basic stealth), picks a target and a situation (Idle, Alert, Combat), and chooses what to do by score, acting through the same inputs a player would press.

**Status:** built, tier 0. Not yet (pawn spec section 14): hearing, more persistence options, and rolling back the AI's decisions for games where clients predict it.

| File | What it's for |
|---|---|
| [README.md](README.md) | This overview: what's here and how to use it |
| [REFERENCE.md](REFERENCE.md) | Every class, setting and function, generated from the code's doc comments (`python tools/docs/make_reference.py ai`) |
| [CHANGELOG.md](CHANGELOG.md) | What changed and why, newest first, and the refactor candidates |
| [PAWN_SPEC.md](../../../docs/pawn/PAWN_SPEC.md) | The AI's design: section 10 (parts, sensing, memory, states, behaviours, how a decision is made) |
| [SCALING_SPEC.md](../../../docs/scaling/SCALING_SPEC.md) | Running it for hundreds of pawns: the pawn table, sensing on worker threads, line of sight in C++, tick rates |

## The pieces

Every part is a child of the pawn. The pawn calls `AIContextComponent.run_ai` once per tick, offline or on the server only, and it runs the rest in this order:

```
 SightSense ─► AISensingManager ─► AIMemory ─► AITargetSelector ─► AIStateManager ─► AIBehaviourManager ─► AIController
 (senses/)      who's near, on        awareness   picks the          Idle / Alert /      picks and runs a       (controllers/)
                its turn              that fades  current target     Combat              behaviour by score     presses inputs
                                                                                                                like a player
```

- **`AIContextComponent`** holds what the parts share: the settings for the whole AI, the current target, the decision waiting this tick, the last hit, and random numbers that replay the same. Other code reaches every AI part through it: `pawn.ai_context.memory`.
- **`AISensingManager`** runs its senses on a schedule and finds the other-team pawns near enough. **`SightSense`** (in `senses/`) fills awareness faster for targets close and in front, if there's a line of sight. **`SightGeometryFeeder`** keeps C++'s copy of the level's solid shapes up to date for line of sight.
- **`AIMemory`** keeps one entry per pawn sensed: awareness from 0 to 1 that rises when seen, becomes certain at 1, and fades by a **`FadeProfile`** when not seen. Its entries live in a store: `AIMemoryStore` in C++ when the navcore library loads, else **`AIMemoryStoreGD`**, the same rules in GDScript.
- **`AITargetSelector`** picks the target by priority (awareness, nearness, threat), with taunts (`force_target`).
- **`AIStateManager`** picks the state: the highest-priority **`AIStateBase`** whose prerequisites hold. `states/`: `AIIdleState`, and `AIAwarenessState`, which Alert and Combat both are, with different settings.
- **`AIBehaviourManager`** scores the **`AIBehaviourBase`** behaviours the state allows and runs the winner. `behaviours/`: Wander, Go To Point (Idle); Look Toward, Investigate, Search (Alert); Chase, Attack (Combat); Parry (any state).
- Behaviours act only through **`AIController`** (`controllers/`): `move_to`, `press`, `hold`, `look_at_point`, `look_at_node`. It turns those into the pawn's input command, and uses the pawn's `NavigationManager` for paths.
- **When a behaviour may run is data** (scaling spec 6.2): conditions in **`conditions/`** (`AICompareCondition`, `AIChanceCondition`, `AIAnyCondition`, and `AIScoreCurve` for the score) read named numbers from the pawn's **`AIInputs`** (`context.inputs`): target distance, the most aware memory entry, a swing coming, the distance to the nearest node in a group, whether an action could start, and any a game adds. They're worked out once per decision. Each built-in behaviour builds its own conditions from its settings; a designer adds more in the inspector. Because they're data, the C++ decider (`AIBatchDecider`) can make the same decision without calling GDScript.
- **Behaviours sleep between events:** a running behaviour's `tick()` runs when something it waits for happens (a walk ending, an ability on its action ending, a tick it named: `wake_on_path_end`, `wake_on_action_end`, `wake_at`), with `tick_interval_ticks` as the longest it sleeps.

**C++ side** (`native/src/`, not edited here): `AIMemoryStore` (memory, sight checks, target scoring), `AIPawnGrid` (one grid of every pawn, for "who's near"; also used by swing hits), `AISensingJob` (sensing's search, visibility and line of sight on worker threads, between ticks), `SightGeometry` (line of sight without physics rays), and `ai_sight_rules.h` (the visibility rule both share).

## How to use it

**Give a pawn a brain.** The default parts (`assets/scenes/pawn/parts/`) give every pawn sensing, memory, targets and the three states, but no behaviours, so it stands still. Add an `AIBehaviourManager` with behaviour children to the pawn's scene, or set the game's default brain in `resources/pawn_defaults.tres` (`ai_brain`). `assets/scenes/samples/arena_brain.tscn` and `faction_brain.tscn` are working brains to copy.

**Tune a behaviour.** Select it under the AIBehaviourManager. `max_score` and `min_score` say how much it wants to run; `allowed_states` where; `cooldown_ticks`, `min_run_ticks` and `interrupt_threshold` how long it holds; `persistence` with a `FadeProfile` keeps it chosen for a while. Every tick setting is at 60 ticks a second.

**Make a new behaviour.** Extend `AIBehaviourBase`, set its scores and states in `_init()`, say when it may run with `own_conditions()` (conditions built from its settings), and override `enter`, `tick` and `exit` as needed. Act only through `context.controller`. In `enter()`, ask to be woken for what it waits for (`wake_on_path_end()`, `wake_on_action_end(action)`, `wake_at(tick)`) and give it a long `tick_interval_ticks` as a safety net. Overriding `is_available` or `score` with code still works, but the C++ decider then has to ask GDScript for that behaviour (`has_own_code()`).

**Change when a behaviour runs, without code.** In the inspector, add conditions to a behaviour's `conditions` list (compare an input with a number, a random chance, or "any of"), or `score_curves` to scale its score by an input. A game adds its own inputs by writing them when they change: `pawn.ai_context.inputs.set_input(&"morale", 0.4)`, then compare `morale` in a condition.

**Make a new awareness state.** Add a node with `AIAwarenessState` under the AIStateManager and fill in its settings (awareness needed, certain or not, seen how recently, hit by whom). No code.

**Taunt or script the AI.**
```gdscript
pawn.ai_context.target_selector.force_target(player_pawn, 180, 40, "taunt")
pawn.ai_context.state_manager.force_state(&"Combat", 120, 50, "scripted")
```
A stronger force replaces a weaker one; during a tick, forces wait for the pawn's next AI step.

**Stealth.** A pawn's Detectability stat (1 normal, 0 invisible) scales how fast others fill awareness of it. Walls on physics layer 1 block sight.

**While a player has the pawn.** `while_possessed` on the AIContextComponent: OFF, MEMORY_ONLY (the default: it keeps noticing, so it knows what's around when the player lets go), or FULL.

**See it.** In the arena samples, each goblin has a readout of its state, target and behaviour, and P pauses with a rewind of the last 10 s (`ai/debug/AIDebugTimeline.gd`).

**Where its time goes.** The AI marks its work with timing scopes (F4 in a sample, or `mass_battle_measure -- --scopes`): `ai.sensing`, `ai.decide` and `ai.behaviours` for the whole of each step, and inside them `ai.decide.target`, `ai.decide.state`, `ai.decide.behaviour` (the behaviour manager's judging, including a decision made when a behaviour ends) and `ai.decide.switch` (exit and enter), plus, while F4 is open or with `--scopes` (detailed scopes, `PerfScopes.begin_detailed`), one per part: `ai.state.<name>` (a state's check), `ai.available.<name>` (a behaviour's is_available), `ai.behaviour.<name>` (its tick), `ai.sense.<name>.full` and `.refresh`, `ai.sense.search` and `ai.memory.forget`. With nothing listening each costs one check.

**Record its decisions.** `ai/debug/AIDecisionRecorder.gd` keeps an `AIDecisionRecord` of every decision of every pawn (the reasons, the state, each behaviour's hard rule, range, availability and score, and the choice) plus each pawn's brain settings, and saves them as JSON lines. `mass_battle_measure -- --record-decisions=<file>` records a whole fight. It's the first piece of checking a C++ decider against this one (scaling spec 6.2); it listens through `AIBehaviourManager.decision_listener`, and with no listener no record is made. `ai_batch_decider_compare -- --file=<file>` replays a recording through the C++ decider (`AIBatchDecider`), which isn't used by the game yet, and counts where it agrees. Live, the `AIDecisionBatcher` module's shadow mode does the same as the game runs (`mass_battle_measure -- --ai-shadow`): it gathers each decision's inputs, decides them all in C++ at the end of the tick, compares, and changes nothing.

## Settings worth knowing

| Setting | Where | Default | What it does |
|---|---|---|---|
| `while_possessed` | AIContextComponent | MEMORY_ONLY | What the AI does while a player has the pawn |
| `decision_interval_ticks` | AIContextComponent | 15 | How often it decides (some events wake it early) |
| `sense_interval_ticks` | AISensingManager | 10 | How often sight looks for everyone near |
| `sight_range`, `near_range` | SightSense | 25 m, 8 m | How far it sees, and within what distance at full strength |
| `central_cone_degrees`, `periphery_degrees` | SightSense | 90, 160 | Its field of view: full strength, and weaker at the sides |
| `fill_rate` | SightSense | 1/30 a tick | How fast a fully visible target fills awareness (half a second) |
| `uncertain_fade_delay_ticks`, `certain_fade_delay_ticks` | AIMemory | 300, 0 | How long awareness stays full after losing sight, before fading |
| `min_awareness` | AITargetSelector | 0.3 | Awareness needed before something can be a target |
| `default_score_jitter` | AIBehaviourManager | 0 | Randomness in its choices, for variety |
| `parry_chance` | AIParryBehaviour | 0.3 | How often it parries a swing coming at it |

## Tests

`ai/tests/`: `ai_state_manager_selftest` (states, forcing, queueing during a tick), `ai_behaviour_manager_selftest` (scoring, interrupts, persistence, ties, wake-ups), `fade_profile_selftest`, `ai_perception_selftest` (sight, memory, targets; `-- --gdscript-store` runs it on the GDScript store), `ai_stealth_selftest`, `ai_sensing_job_selftest` (the worker-thread job gives the same answers), `sight_geometry_selftest` (C++ line of sight against physics), `ai_go_to_point_selftest`, `ai_decision_recorder_selftest` (decision records, the recorder and the timing scopes), `ai_batch_decider_selftest` (the C++ decider makes every decision the same way; the kept "could this action start" answers match the ability manager), `ai_conditions_selftest` (inputs, conditions, score curves, and C++ judging them the same way), and `ai_stress`, which prints the AI's cost per tick. Fights with the AI are in `abilities/tests/fight_selftest` and `parry_selftest`. Run them with `bash tools/run_tests.sh <name>`.
