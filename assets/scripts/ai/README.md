<!-- Written by Claude (claude-opus-5-5), 2026-11-17: the AI system's overview, beside its code. -->

# AI

The brain on each computer-run pawn: it notices enemies by sight, remembers them with awareness that fades (basic stealth), picks a target and a situation (Idle, Alert, Combat), and chooses what to do by score, acting through the same inputs a player would press.

**Status:** built, tier 0. Not yet (pawn spec section 14): hearing, and rolling back the AI's decisions for games where clients predict it.

| File | What it's for |
|---|---|
| [README.md](README.md) | This overview: what's here and how to use it |
| [REFERENCE.md](REFERENCE.md) | Every class, setting and function, generated from the code's doc comments (`python tools/docs/make_reference.py ai`) |
| [CHANGELOG.md](CHANGELOG.md) | What changed and why, newest first, and the refactor candidates |
| [PAWN_SPEC.md](../../../docs/pawn/PAWN_SPEC.md) | The AI's design: section 10 (parts, sensing, memory, states, behaviours, how a decision is made) |
| [SCALING_SPEC.md](../../../docs/scaling/SCALING_SPEC.md) | Running it for hundreds of pawns: the pawn table, sensing on worker threads, line of sight in C++, tick rates |

## The pieces

The AI is one component on the pawn, the **`AIManager`** (`pawn.ai`), with the AI's other components as its children: the AIController, sensing, memory, the target selector, and the state and behaviour managers. The pawn calls `AIManager.run_ai` once per tick, offline or on the server only, and the AI thinks (`think`), running the rest in this order. An order source (`AIManager.order_source`) can supply the pawn's orders instead, as the order replay test does (netcode spec 19.10); the AI gives orders only through the AIController, and should give them only in this step (a death-time exception is a refactor row in the changelog).

```
 SightSense ─► AISensingManager ─► AIMemory ─► AITargetSelector ─► AIStateManager ─► AIBehaviourManager ─► AIController
 (senses/)      who's near, on        awareness   picks the          Idle / Alert /      picks and runs a       (controllers/)
                its turn              that fades  current target     Combat              behaviour by score     presses inputs
                                                                                                                like a player
```

- **`AIManager`** holds the AI's components and what they share: the settings for the whole AI, the current target, the decision waiting this tick, the last hit, and random numbers that replay the same. Other code reaches every AI component through it: `pawn.ai.memory`, `pawn.ai.controller`.
- **`AISensingManager`** runs its senses on a schedule and finds the other-team pawns near enough. **`SightSense`** (in `senses/`) fills awareness faster for targets close and in front, if there's a line of sight. **`SightGeometryFeeder`** keeps C++'s copy of the level's solid shapes up to date for line of sight.
- **`AIMemory`** keeps one entry per pawn sensed: awareness from 0 to 1 that rises when seen, becomes certain at 1, and fades by a **`FadeProfile`** when not seen. Its entries live in a store: `AIMemoryStore` in C++ when the navcore library loads, else **`AIMemoryStoreGD`**, the same rules in GDScript.
- **`AITargetSelector`** picks the target by priority (awareness, nearness, threat). A taunt is threat on the taunter's memory entry.
- **`AIStateManager`** picks the state: the highest-priority **`AIStateBase`** whose prerequisites hold. `states/`: `AIIdleState`, and `AIAwarenessState`, which Alert and Combat both are, with different settings.
- **`AIBehaviourManager`** scores the **`AIBehaviourBase`** behaviours the state allows and runs the winner. A behaviour's settings are in its **definition** (`definitions/`: `AIBehaviourDefinition`, and a class per kind such as `AIChaseDefinition`), shared by every pawn that uses it, as an ability's are; the node holds its state. `behaviours/`: Wander, Go To Point (Idle); Look Toward, Investigate, Search (Alert); Chase, Keep Distance, Attack (Combat: any attack, melee or ranged, from the reach its ability reports, `AbilityBase.attack_reach()`; a pawn with a ranged attack hangs back at shooting distance with Keep Distance, and melees a target that comes within 4 m); Parry (any state).
- Behaviours act only through **`AIController`** (`controllers/`, a child of the AIManager; the pawn's ControllerManager puts it in charge while no player has the pawn): `move_to`, `press`, `hold`, `look_at_point`, `look_at_node`. It turns those into the pawn's input command, and uses the pawn's `NavigationManager` for paths.
- **When a behaviour may run is data** (scaling spec 6.2): conditions in **`conditions/`** (`AICompareCondition`, `AIChanceCondition`, `AIAnyCondition`) read named numbers from the pawn's **`AIInputs`** (`context.inputs`): target distance, the most aware memory entry, a swing coming, the distance to the nearest node in a group, whether an action could start, and any a game adds. They're worked out once per decision. Each built-in behaviour builds its own conditions from its settings; a designer adds more in the inspector. Because they're data, the C++ decider (`AIDecider`) can make the same decision without calling GDScript.
- **C++ makes the decisions; GDScript is the backup.** Each behaviour manager owns its C++ decider (`AIDecider`, one row: its pawn's decision state) through an **`AIDeciderBridge`** (`manager.cpp_decider`), which asks it for each decision; the manager starts what it chose. Brains are compiled once per behaviour set and shared by every decider. A pawn decides in GDScript instead when its `decides_in` says so, when the project setting `project_base/ai/all_decisions_in_gdscript` is on, when diagnostics switch every pawn over (F10 in debug builds, `AIDecisionChecks`), when its memory fades are custom (a fade with its own `value_at`), or without the C++ library. A behaviour with its own `is_available` or `score` code, or a condition of a kind C++ doesn't read (`judged_in_gdscript()`), doesn't move its pawn: C++ asks GDScript about that behaviour when it reaches it, and judges the rest. Nothing checks this every tick.
- **Behaviours sleep between events:** a running behaviour's `tick()` runs when something it waits for happens (a walk ending, an ability on its action ending, a tick it named: `wake_on_path_end`, `wake_on_action_end`, `wake_at`), with `tick_interval_ticks` as the longest it sleeps.

**C++ side** (`native/src/`, not edited here): `AIMemoryStore` (memory, sight checks, target scoring), `AIPawnGrid` (one grid of every pawn, for "who's near"; also used by swing hits), `AISensingJob` (sensing's search, visibility and line of sight on worker threads, between ticks), `SightGeometry` (line of sight without physics rays), and `ai_sight_rules.h` (the visibility rule both share).

## How to use it

**Give a pawn a brain.** The default AIManager (`assets/scenes/pawn/parts/AIManager.tscn`) gives every pawn sensing, memory, targets and the three states, but no behaviours, so it stands still. Add an `AIManager` node to the pawn's scene with an `AIBehaviourManager` and its behaviour children under it (PawnInitializer fills in the other components), or set the game's default brain in `resources/pawn_defaults.tres` (`ai_brain`, which goes in place of the AIManager's empty behaviour manager). `assets/scenes/samples/arena_brain.tscn` and `faction_brain.tscn` are working brains to copy.

**Tune a behaviour.** Its settings are in its definition, as an ability's are (abilities README, "Give an ability other numbers"): give the node's `definition` a new one of its kind (`New AIChaseDefinition`), change what you need and save it in `resources/ai_behaviours/` so other pawns share it (the samples' `goblin_chase.tres`, `heavy_attack.tres`, `shoot.tres`); a variant sets `based_on` first. Empty, it runs with its kind's defaults. While playing a definition is read-only: swap it with `use_definition()`, or give one pawn its own copy with `make_definition_unique()`; a behaviour modifier is the way to change numbers in play. `base_score` says how much it wants to run: an open number like an ability's priority (the samples run from Wander's 10 to Parry's 97); `score_jitter` how much at random it moves up or down; `tag_requirements` when (a tag query over the pawn's owned tags: the AI's state is one, `ai.state.combat`, and so are conditions such as `status.has_ammo.ranged`); `enabled`, on the node, switches it off for that pawn (an inherited scene can't remove it); `cooldown_ticks`, `min_run_ticks` and `interrupt_threshold` how long it holds; `modifier_always`, `modifier_on_start` and `modifier_on_end` are behaviour modifiers it gives itself always, as it starts or as it ends (Look Toward steps aside for 15 s with one). Every tick setting is at 60 ticks a second.

**Make a new behaviour.** Extend `AIBehaviourBase`. Give it a definition class extending `AIBehaviourDefinition` with its own settings (each setter calls `_changed`) and its defaults (scores, `tag_requirements`) in that class's `_init()`; return one from `make_default_definition()` and keep a typed reference from `_settings_changed()` (`_kind_settings = settings as AIChaseDefinition`). Then say when it may run with `own_conditions()` (conditions built from its settings), and override `enter`, `tick` and `exit` as needed. Act only through `context.controller`. In `enter()`, ask to be woken for what it waits for (`wake_on_path_end()`, `wake_on_action_end(action)`, `wake_at(tick)`) and give it a long `tick_interval_ticks` as a safety net. Overriding `is_available` or `score` with code works too: C++ asks GDScript for those answers when it reaches the behaviour (`has_own_code()`; see **Scripted behaviours under C++**).

**Change priorities while playing.** A behaviour modifier (`AIBehaviourModifier`, a definition) changes one number of the behaviours whose `tags` it applies to: their score, jitter, interrupt threshold, cooldown or minimum run, multiplying, then adding, or overriding (the last added wins). It can block them instead. It lasts as long as it's added (or for `duration_ticks`), while its `ongoing_requirements` pass. Whatever causes it asks the AI to add and remove it, keyed by itself:
```gdscript
pawn.ai.add_modifier(charge_shout, self)    # Chase (ai.stance.melee) +10, from the pawn's next AI step
pawn.ai.remove_modifiers(self)
```
A running behaviour whose tag requirements stop passing, or that a modifier blocks, is replaced at the pawn's next AI step: its `min_run_ticks` don't hold it, its `interrupt_threshold` still does.

**Ease a modifier in or out.** Give it a `curve` (a drawn Godot Curve, y from -1 to 1): how strongly it applies over `curve_input`, or over the ticks since it was added when that's empty (x at 60 a second; set the curve's domain to the x range it spans). At strength s a multiply m becomes `1 + (m - 1) x s` (stopping at x0 when reversed) and an add a becomes `a x s`; at -1 the change is reversed. A Chase that's hard to interrupt at first and gives way after a long chase:
```
modifier_on_start: INTERRUPT_THRESHOLD, add 40, curve 1 at x 0 down to 0 at x 120   # +40, easing to 0 over 2 s
modifier_always:   SCORE, multiply 1.3, curve over target_distance                    # keener up close
```
A time curve settles once past its domain and then costs nothing; one over an input is worked out at each decision.

**Change when a behaviour runs, without code.** In the inspector, add conditions to a behaviour's `conditions` list (compare an input with a number, a random chance, or "any of"), or a curved modifier (`modifier_always`) to scale its score by an input. A game adds its own inputs by writing them when they change: `pawn.ai.set_input(&"morale", 0.4)`, then compare `morale` in a condition.

**Make a new awareness state.** Add a node with `AIAwarenessState` under the AIStateManager and fill in its settings (awareness needed, certain or not, seen how recently, hit by whom). No code.

**Ask the AI from outside: the request inbox.** Game code never changes the AI's components directly: it asks the AIManager (`add_modifier`, `remove_modifiers`, `set_input`), and the requests apply at the start of the pawn's next AI step, in the order asked, so no result depends on which pawn ran first. On a client they're ignored (the AI runs on the server). There's no forcing: a taunt is threat on the taunter's memory entry, which target priority weighs, and a scripted state is a state whose prerequisites read a tag the script grants.

**Stealth.** A pawn's Detectability stat (1 normal, 0 invisible) scales how fast others fill awareness of it. Walls on physics layer 1 block sight.

**While a player has the pawn.** `while_possessed` on the AIManager: OFF, MEMORY_ONLY (the default: it keeps noticing, so it knows what's around when the player lets go), or FULL.

**See it.** In the arena samples, each goblin has a readout of its state, target and behaviour, and P pauses with a rewind of the last 10 s (`ai/debug/AIDebugTimeline.gd`).

**Where its time goes.** The AI marks its work with timing scopes (F4 in a sample, or `mass_battle_measure -- --scopes`): `ai.sensing`, `ai.decide` and `ai.behaviours` for the whole of each step, and inside them `ai.decide.target`, `ai.decide.state`, `ai.decide.behaviour` (the behaviour manager's judging, including a decision made when a behaviour ends) and `ai.decide.switch` (exit and enter), plus, while F4 is open or with `--scopes` (detailed scopes, `PerfScopes.begin_detailed`), one per part: `ai.state.<name>` (a state's check), `ai.available.<name>` (a behaviour's is_available), `ai.behaviour.<name>` (its tick), `ai.sense.<name>.full` and `.refresh`, `ai.sense.search` and `ai.memory.forget`. With nothing listening each costs one check.

**Record its decisions.** `ai/debug/AIDecisionRecorder.gd` keeps an `AIDecisionRecord` of every decision of every pawn (the reasons, the state, each behaviour's hard rule, its numbers with modifiers, its result, availability and score, and the choice) plus each pawn's brain settings, and saves them as JSON lines. `mass_battle_measure -- --record-decisions=<file>` records a whole fight. It's how the C++ decider is checked against this GDScript one (scaling spec 6.2); it listens through `AIBehaviourManager.decision_listener`, and with no listener no record is made. `ai_decider_compare -- --file=<file>` replays a recording through the C++ decider (`AIDecider`, the game's main path), and counts where it agrees. Live, shadow mode (`AIDecisionChecks.set_check_against_gdscript`, `mass_battle_measure -- --ai-shadow`) has GDScript decide and C++ decide beside it, compares, and changes nothing.

## How it works

Details the code's doc comments leave out.

**A decision** (`AIBehaviourManager.decide`; the C++ `AIDecider` follows the same steps, so a change goes in both). The pawn's inputs start afresh (each is worked out when a condition first reads it), then:
0. Interrupts: if the running behaviour can't be replaced by this decision's reason (`cannot_be_interrupted`, `interrupt_threshold`, `min_run_ticks`), it keeps running.
1. Valid: the behaviours the current state allows.
2. Hard rules that cost nothing, with no behaviour code run: drop any blocked or switched off, on cooldown, or needing a target when there is none.
3. Results: each candidate's result is its `base_score` with modifiers (multiplied, then added to), plus its jitter (an offset from the context's replayable random numbers, drawn each decision or once per pawn, `jitter_draw`). Known before any of its code runs; a behaviour with its own `score()` is known only once asked, so it goes first.
4. The walk, highest result first: `is_available()`, then whether its action could start (and a scripted `score()`), asked only on the way. Once the best so far is ahead of the next by more than the tie margin, nothing after can win and the rest are skipped. Exact: nothing skipped could have won.
5. Ties: results within `tie_margin` tie; `randomize_ties` picks at random, otherwise the fixed order (behaviours sorted by name) decides.
6. Switching: the old behaviour's `exit()` and its `modifier_on_end`, then the new one's `modifier_on_start` and `enter()`.

Between decisions only the running behaviour's `tick()` runs. When it returns SUCCEEDED or FAILED the manager decides at once; when the pawn dies it stops (reason "died"). Odd cases are in `ai_behaviour_manager_selftest`: a state allowing no behaviour makes the pawn stand still with one warning; a behaviour with an automatic name (starting with `@`) warns, because names must be the same every run.

**Behaviours.** Settings counted in ticks are written for 60 a second and converted where read. A behaviour that waits asks to be woken (`wake_on_path_end`, `wake_on_action_end`, `wake_at`; cleared when it starts, `wake_at` used up when it fires), so `tick_interval_ticks` is only the longest it sleeps. Count time with `context.current_tick`, not by counting `tick()` calls. To keep a behaviour chosen a while, or step it aside, give it a modifier as it starts or ends, eased with a time curve.

**States.** The state manager checks states from the highest priority down; the first whose prerequisites hold wins, with no minimum time in a state. A change asks for a decision with the new state's priority as its reason.

**Memory and awareness.** A sense adds gain each time it sees an entity, up to 1; a certain entry refills to 1 at once. Sightings within `continuous_sighting_ticks` with no unseen check between count as one look. While unseen, awareness stays full for the delay, then fades: awareness now = awareness when seen x fade value at (ticks since seen - delay). Nothing drains in the background; entries are forgotten once the fade has ended (`forget_old` on each full pass) or the entity is freed or dies. A new entry or a newly certain one asks for a decision at once.

**Sensing on worker threads.** With the navcore library, `AIPawnGrid` (one grid of every pawn, built once a tick) finds the nearest candidates, and the full pass's search, visibility and line of sight run as the shared `AISensingJob` between ticks. At the end of the tick before a pawn's pass, it asks the job, which reads the shared pawn table and works while the next tick waits; on the pass's tick the sight sense only records the result. A pass with no result (a pawn not due, a test calling `full_pass`) runs on the main thread, as does everything with `TickJobs.enabled` off. Without the library, a physics shape query on `candidate_mask` is used. When no pawn of another team exists (TeamRegistry), the query is skipped.

**C++ decisions.** A pawn's `AIDeciderBridge` keeps its row in the C++ decider up to date by reading version counters just before each decision and copying only what changed: the owned tags (`OwnedTags.version`, the state among them), the behaviour modifiers (`modifiers_version`: their fixed numbers and their live curves, which C++ works out at each decision), which behaviours are switched on (`enabled_version`), the target, last hit and swing coming (`AIManager.facts_version`), and a game's inputs (`AIInputs.kept_version`). A fact's owner only raises its counter; it never calls the decider. Brains are shared through a static store in C++, keyed by everything a brain is compiled from (the description as text): not the definitions' ids alone, since Attack's reach and Keep Distance's minimum come from the pawn's abilities. Where a pawn decides is settled when it first decides, and again when something changes it (its brain, its `decides_in`, a switch, late tags). **C++ asks back** through one callback (`AIDeciderBridge.answer`), as it reaches a behaviour in the walk: whether its action could start, a scripted behaviour's `is_available()` and `score()`, and the inputs only GDScript works out (`action_ready`, a group's nearest node). C++ works out the rest of the inputs itself, each when first read. A pawn whose memory fades are custom (own `value_at`) stays in GDScript. The checks live in diagnostics (`AIDecisionChecks`): shadow mode (`set_check_against_gdscript`) compares the two, F10 moves every pawn to GDScript, and in debug builds a sampled check warns when a written fact is stale (a counter not raised).

**Scripted behaviours under C++.** A behaviour with its own `is_available()` or `score()` code, or a condition C++ doesn't read (`judged_in_gdscript()`), is asked through the callback when C++'s walk reaches it, as GDScript's own decider asks it. Two things to know:
- **A `score()` of its own is always asked** once the behaviour passes the hard rules and is available: its result isn't known up front, so it can't be skipped. A score from settings and modifiers (curves included) can.
- **No side effects.** In shadow mode both deciders ask, so anything `is_available()` or `score()` changes (a timer, a random draw, a memory write) happens twice. Read only; do changes in `enter()`, `tick()` or `exit()`.

Each answer is a call into GDScript, timed under `ai.available.<name>` (detailed PerfScopes) inside `ai.decide.cpp.native`. Prefer conditions and curved modifiers (data, judged in C++). Reach for code when no condition kind fits, keep it cheap, and work out anything costly once into a kept input (`ai.set_input`) that several behaviours can read.

**Rollback and network.** The AI runs only on the server or offline, never while a rollback replays ticks, so its decisions aren't rolled back.

## Settings worth knowing

| Setting | Where | Default | What it does |
|---|---|---|---|
| `while_possessed` | AIManager | MEMORY_ONLY | What the AI does while a player has the pawn |
| `decision_interval_ticks` | AIManager | 15 | How often it decides (some events wake it early) |
| `sense_interval_ticks` | AISensingManager | 10 | How often sight looks for everyone near |
| `sight_range`, `near_range` | SightSense | 25 m, 8 m | How far it sees, and within what distance at full strength |
| `central_cone_degrees`, `periphery_degrees` | SightSense | 90, 160 | Its field of view: full strength, and weaker at the sides |
| `fill_rate` | SightSense | 1/30 a tick | How fast a fully visible target fills awareness (half a second) |
| `uncertain_fade_delay_ticks`, `certain_fade_delay_ticks` | AIMemory | 300, 0 | How long awareness stays full after losing sight, before fading |
| `min_awareness` | AITargetSelector | 0.3 | Awareness needed before something can be a target |
| `default_score_jitter` | AIBehaviourManager | 0 | Randomness in its choices, for variety, in score units |
| `jitter_draw` | AIBehaviourManager | EACH_DECISION | Jitter drawn at every decision, or once per pawn (a fixed personality) |
| `parry_chance` | AIParryDefinition | 0.3 | How often it parries a swing coming at it |

## Tests

`ai/tests/`: `ai_state_manager_selftest` (states, the request inbox), `ai_behaviour_manager_selftest` (scoring, interrupts, ties, wake-ups, tag requirements, behaviour modifiers and their numbers, a behaviour's own start and end modifiers), `ai_behaviour_definition_selftest` (definitions: kind defaults, files and variants, settings written on a node, the lock while playing, swaps, the samples' files, registry ids), `fade_profile_selftest`, `ai_perception_selftest` (sight, memory, targets; `-- --gdscript-store` runs it on the GDScript store), `ai_stealth_selftest`, `ai_sensing_job_selftest` (the worker-thread job gives the same answers), `sight_geometry_selftest` (C++ line of sight against physics), `ai_go_to_point_selftest`, `ai_decision_recorder_selftest` (decision records, the recorder and the timing scopes), `ai_decider_selftest` (the C++ decider makes every decision the same way; the kept "could this action start" answers match the ability manager), `ai_conditions_selftest` (inputs, conditions, score curves, and C++ judging them the same way), and `ai_stress`, which prints the AI's cost per tick. Fights with the AI are in `abilities/tests/fight_selftest` and `parry_selftest`. Run them with `bash tools/run_tests.sh <name>`.
