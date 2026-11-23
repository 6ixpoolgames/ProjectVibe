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

Every part is a child of the pawn. The pawn calls `AIContextComponent.run_ai` once per tick, offline or on the server only, and the AI thinks (`think`), running the rest in this order. An order source (`AIContextComponent.order_source`) can supply the pawn's orders instead, as the order replay test does (netcode spec 19.10); the AI gives orders only through the AIController, and should give them only in this step (a death-time exception is a refactor row in the changelog).

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
- **`AIBehaviourManager`** scores the **`AIBehaviourBase`** behaviours the state allows and runs the winner. `behaviours/`: Wander, Go To Point (Idle); Look Toward, Investigate, Search (Alert); Chase, Keep Distance, Attack (Combat: any attack, melee or ranged, from the reach its ability reports, `AbilityBase.attack_reach()`; a pawn with a ranged attack hangs back at shooting distance with Keep Distance, and melees a target that comes within 4 m); Parry (any state).
- Behaviours act only through **`AIController`** (`controllers/`): `move_to`, `press`, `hold`, `look_at_point`, `look_at_node`. It turns those into the pawn's input command, and uses the pawn's `NavigationManager` for paths.
- **When a behaviour may run is data** (scaling spec 6.2): conditions in **`conditions/`** (`AICompareCondition`, `AIChanceCondition`, `AIAnyCondition`, and `AIScoreCurve` for the score) read named numbers from the pawn's **`AIInputs`** (`context.inputs`): target distance, the most aware memory entry, a swing coming, the distance to the nearest node in a group, whether an action could start, and any a game adds. They're worked out once per decision. Each built-in behaviour builds its own conditions from its settings; a designer adds more in the inspector. Because they're data, the C++ decider (`AIBatchDecider`) can make the same decision without calling GDScript.
- **C++ makes the decisions; GDScript is the backup.** The **`AIDecisionModule`** (a GameMode module, in the project's list) holds the C++ decider and each pawn's decision state there, and makes each pawn's decision with one call; the behaviour manager starts what it chose. A pawn decides in GDScript instead when its `decides_in` says so, when the game mode's `decider` overrides every pawn (a match option; F10 in debug builds switches all to GDScript and back), when it's a special mind (a behaviour with its own `is_available` or `score` code, a fade with its own `value_at`), or without the C++ library. Nothing checks this every tick.
- **Behaviours sleep between events:** a running behaviour's `tick()` runs when something it waits for happens (a walk ending, an ability on its action ending, a tick it named: `wake_on_path_end`, `wake_on_action_end`, `wake_at`), with `tick_interval_ticks` as the longest it sleeps.

**C++ side** (`native/src/`, not edited here): `AIMemoryStore` (memory, sight checks, target scoring), `AIPawnGrid` (one grid of every pawn, for "who's near"; also used by swing hits), `AISensingJob` (sensing's search, visibility and line of sight on worker threads, between ticks), `SightGeometry` (line of sight without physics rays), and `ai_sight_rules.h` (the visibility rule both share).

## How to use it

**Give a pawn a brain.** The default parts (`assets/scenes/pawn/parts/`) give every pawn sensing, memory, targets and the three states, but no behaviours, so it stands still. Add an `AIBehaviourManager` with behaviour children to the pawn's scene, or set the game's default brain in `resources/pawn_defaults.tres` (`ai_brain`). `assets/scenes/samples/arena_brain.tscn` and `faction_brain.tscn` are working brains to copy.

**Tune a behaviour.** Select it under the AIBehaviourManager. `max_score` and `min_score` say how much it wants to run; `tag_requirements` when (a tag query over the pawn's owned tags: the AI's state is one, `ai.state.combat`, and so are conditions such as `status.has_ammo.ranged`); `enabled` switches it off (an inherited scene can't remove it); `cooldown_ticks`, `min_run_ticks` and `interrupt_threshold` how long it holds; `persistence` with a `FadeProfile` keeps it chosen for a while. Every tick setting is at 60 ticks a second.

**Make a new behaviour.** Extend `AIBehaviourBase`, set its scores and states in `_init()`, say when it may run with `own_conditions()` (conditions built from its settings), and override `enter`, `tick` and `exit` as needed. Act only through `context.controller`. In `enter()`, ask to be woken for what it waits for (`wake_on_path_end()`, `wake_on_action_end(action)`, `wake_at(tick)`) and give it a long `tick_interval_ticks` as a safety net. Overriding `is_available` or `score` with code still works, but the C++ decider then has to ask GDScript for that behaviour (`has_own_code()`).

**Change priorities while playing.** A score modifier (`AIScoreModifier`, a definition) raises, lowers or blocks the behaviours whose `tags` it applies to, for as long as it's added (or for `duration_ticks`), while its `ongoing_requirements` pass. Whatever causes it adds and removes it, keyed by itself:
```gdscript
pawn.ai_context.behaviour_manager.add_score_modifier(charge_shout, self)    # Chase (ai.stance.melee) +0.1
pawn.ai_context.behaviour_manager.remove_score_modifier(self)
```
A running behaviour whose tag requirements stop passing, or that a modifier blocks, is replaced at the pawn's next AI step: its `min_run_ticks` don't hold it, its `interrupt_threshold` still does.

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

**Record its decisions.** `ai/debug/AIDecisionRecorder.gd` keeps an `AIDecisionRecord` of every decision of every pawn (the reasons, the state, each behaviour's hard rule, range, availability and score, and the choice) plus each pawn's brain settings, and saves them as JSON lines. `mass_battle_measure -- --record-decisions=<file>` records a whole fight. It's how the C++ decider is checked against this GDScript one (scaling spec 6.2); it listens through `AIBehaviourManager.decision_listener`, and with no listener no record is made. `ai_batch_decider_compare -- --file=<file>` replays a recording through the C++ decider (`AIBatchDecider`, the game's main path through `AIDecisionModule`), and counts where it agrees. Live, the `AIDecisionModule`'s shadow mode (`check_against_gdscript`, `mass_battle_measure -- --ai-shadow`) has GDScript decide and C++ decide beside it, compares, and changes nothing.

## How it works

Details the code's doc comments leave out.

**A decision** (`AIBehaviourManager.decide`; the C++ `AIBatchDecider` follows the same steps, so a change goes in both). The pawn's inputs start afresh (each is worked out when a condition first reads it), then:
0. Interrupts: if the running behaviour can't be replaced by this decision's reason (`cannot_be_interrupted`, `interrupt_threshold`, `min_run_ticks`), it keeps running.
1. Valid: the behaviours the current state allows.
2. Hard rules, with no behaviour code run: drop any on cooldown, needing a target when there is none, or whose action can't start.
3. Ranges: each result can only land between floor (`min_score` + persistence - jitter) and ceiling (`max_score` + persistence + jitter). One whose ceiling is below the highest floor can't win. A floor is only certain if its behaviour is available, so the highest floor comes from the first available behaviour, from the highest floor down.
4. Scoring, highest ceiling first: `is_available()` and `score()`, plus persistence and this decision's jitter (each behaviour's own offset from the context's replayable random numbers). Once the next ceiling can't beat the best result, the rest are skipped.
5. Ties: results within `tie_margin` tie; `randomize_ties` picks at random, otherwise the fixed order (behaviours sorted by name) decides.
6. Switching: the old behaviour's `exit()`, then the new one's `enter()`, and its persistence starts.

Between decisions only the running behaviour's `tick()` runs. When it returns SUCCEEDED or FAILED the manager decides at once; when the pawn dies it stops (reason "died"). Odd cases are in `ai_behaviour_manager_selftest`: a state allowing no behaviour makes the pawn stand still with one warning; a `score()` outside its range warns once in debug builds; a behaviour with an automatic name (starting with `@`) warns, because names must be the same every run.

**Behaviours.** Settings counted in ticks are written for 60 a second and converted where read. A behaviour that waits asks to be woken (`wake_on_path_end`, `wake_on_action_end`, `wake_at`; cleared when it starts, `wake_at` used up when it fires), so `tick_interval_ticks` is only the longest it sleeps. Count time with `context.current_tick`, not by counting `tick()` calls. Persistence adds `persistence` times the fade's value from when the behaviour is chosen: positive keeps it chosen, negative makes the AI prefer something else for a while.

**States and forcing.** The state manager checks states from the highest priority down; the first whose prerequisites hold wins, with no minimum time in a state. `force_state` and `force_target` skip the normal choice for `hold_ticks` (-1: until released); a new force replaces the current one only if its priority is equal or higher. Called during a tick (by another pawn's ability, say), a force is queued and applied at the start of this pawn's next AI step, in the order asked, so the result never depends on which pawn went first (scaling spec step 3); it returns true for "queued". Forces work on the server and offline only.

**Memory and awareness.** A sense adds gain each time it sees an entity, up to 1; a certain entry refills to 1 at once. Sightings within `continuous_sighting_ticks` with no unseen check between count as one look. While unseen, awareness stays full for the delay, then fades: awareness now = awareness when seen x fade value at (ticks since seen - delay). Nothing drains in the background; entries are forgotten once the fade has ended (`forget_old` on each full pass) or the entity is freed or dies. A new entry or a newly certain one asks for a decision at once.

**Sensing on worker threads.** With the navcore library, `AIPawnGrid` (one grid of every pawn, built once a tick) finds the nearest candidates, and the full pass's search, visibility and line of sight run as the shared `AISensingJob` between ticks. At the end of the tick before a pawn's pass, it asks the job, which reads the shared pawn table and works while the next tick waits; on the pass's tick the sight sense only records the result. A pass with no result (a pawn not due, a test calling `full_pass`) runs on the main thread, as does everything with `TickJobs.enabled` off. Without the library, a physics shape query on `candidate_mask` is used. When no pawn of another team exists (TeamRegistry), the query is skipped.

**C++ decisions.** The `AIDecisionModule` keeps per-pawn rows in the C++ decider, written through when a fact changes (state, target, hits, swings, a game's inputs, which actions could start). Where a pawn decides is settled when it first decides, and again only when something changes it. Special minds (own `is_available`/`score` code, a fade with its own `value_at`, an unknown condition kind) stay in GDScript, with a warning. Shadow mode (`check_against_gdscript`) compares the two; in debug builds a sampled check warns when a written fact is stale.

**Rollback and network.** The AI runs only on the server or offline, never while a rollback replays ticks, so its decisions aren't rolled back.

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

`ai/tests/`: `ai_state_manager_selftest` (states, forcing, queueing during a tick), `ai_behaviour_manager_selftest` (scoring, interrupts, persistence, ties, wake-ups, tag requirements, score modifiers), `fade_profile_selftest`, `ai_perception_selftest` (sight, memory, targets; `-- --gdscript-store` runs it on the GDScript store), `ai_stealth_selftest`, `ai_sensing_job_selftest` (the worker-thread job gives the same answers), `sight_geometry_selftest` (C++ line of sight against physics), `ai_go_to_point_selftest`, `ai_decision_recorder_selftest` (decision records, the recorder and the timing scopes), `ai_batch_decider_selftest` (the C++ decider makes every decision the same way; the kept "could this action start" answers match the ability manager), `ai_conditions_selftest` (inputs, conditions, score curves, and C++ judging them the same way), and `ai_stress`, which prints the AI's cost per tick. Fights with the AI are in `abilities/tests/fight_selftest` and `parry_selftest`. Run them with `bash tools/run_tests.sh <name>`.
