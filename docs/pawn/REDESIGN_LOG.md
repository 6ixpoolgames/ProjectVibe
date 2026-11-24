<!-- Written by Claude (claude-opus-5-5), 2026-11-24: the decision log of the pawn redesign, moved out of pawn spec 16 when that
section was rewritten as the consolidated design. Kept as it was recorded, dated, so the reasons stay findable. -->

# Pawn redesign: decision log

The pawn redesign was agreed with the owner on 2026-11-23 and 2026-11-24, first as unit definitions, then component by component.
This is the record as it was written during that review, in order; later entries revise earlier ones. The design as decided is
[pawn spec 16](PAWN_SPEC.md); read that first.

Section numbers below (16.0 to 16.8) are the ones the spec had during the review.

## Units: pawn definitions, ability sets and behaviour sets *(Claude 2026-11-23: agreed with the owner the same day, with Claude's recommendations; revised 2026-11-24, the owner: a pawn is built from a definition that hands each component its own, through the pawn initializer. Nothing built yet)*

**Why.** A unit today is a chain of inherited scenes (`arena_goblin` → `faction_goblin` → `faction_goblin_blue` → `faction_goblin_blue_archer`):
- One shared AbilityManager scene (`faction_abilities.tscn`) gives every faction pawn every ability, so a player who takes an archer can still swing a sword.
- Behaviours are child nodes of the behaviour manager, and a role switches off the ones it doesn't want (`enabled = false`).
- Team and look are set in the scene, so four factions with two roles make eight scenes.
- A spawner takes one type-name string registered in code (`NetworkSession.register_type`), so a mixed squad needs two spawners on the same spot.

The goal, the owner's: a designer combines behaviours and abilities into units from data, with basic logical controls (the gates and scores of 10.13), and example sets for the archetypes (swordsman, archer). Acquiring an ability during play (a magic item that grants one) is part of the same design.

### 16.0 The AI is one component: a tree with the AI manager at its root *(the owner, 2026-11-24)*

Today the pawn's 13 default components include six AI components side by side (`AIContextComponent`, `AISensingManager`, `AIMemory`,
`AITargetSelector`, `AIStateManager`, `AIBehaviourManager`). The context finds the other five by searching the pawn's children, a
player-only pawn has to skip six components, and `PawnDefaultsRes.ai_brain` exists because the brain is one sibling among them. They become
one node tree:

```
AIManager                 the root: what the AI components share (inputs, current target, random numbers) and the AI step; pawn.ai
├─ AISensingManager
│  └─ SightSense, ...     its senses
├─ AIMemory
├─ AITargetSelector
├─ AIStateManager
│  └─ Idle, Alert, Combat, ...
└─ AIBehaviourManager
   └─ Chase, Attack, KeepDistance, ...
```

- **`AIContextComponent` becomes `AIManager`,** and `pawn.ai_context` becomes `pawn.ai`. It holds direct references to its children
  instead of searching the pawn. The five child classes keep their jobs (the standard split: perception, memory, targeting, states,
  utility choice).
- **The pawn's components go from 13 to 8** (7 once `NavigationManager` goes, below): ControllerManager, NavigationManager, AbilityManager, StatManager, EffectManager, OwnedTags,
  AIManager, PawnStreamingSource. A player-only pawn leaves out one component; a pawn definition gives one AI entry (a scene or a
  definition), so the `ai_brain` special case goes.
- **A thin `AIController` in the AI tree hands over the AI's input** *(revised twice on 2026-11-24, see below)*: it registers with
  the ControllerManager as the player's controller does, and the running behaviour's steps write its input. The old AI controller
  (the AI's hands, holding orders) goes.
- **The tree is the unit of reuse.** An AI scene (the whole tree, or one sub-manager with its children) can be a premade scene, built
  from a definition, or the designer's own nodes, by the rules of 16.1.
- **Touched:** six scenes that place AI children (paths become `AIManager/AIBehaviourManager/...`), changed by a script; about 40
  places in code that name the components; behaviours' and states' `context` parameter becomes the AI manager. The AI runs only on the
  server and isn't rolled back, so no rolled-back state or network path changes.

### 16.1 Built component by component, through the pawn initializer

The pawn initializer (11) is where this happens: it already gives each pawn its components, one by one, in a fixed order, from the game's defaults (`PawnDefaultsRes.parts`, a list of component scenes), and keeps any component the pawn's own scene already has under the same name. A **PawnDefinition** extends that per pawn kind: for each component it may give

| What it gives a component | How the component is made | When to use it |
|---|---|---|
| **a premade scene** | instantiated, as the defaults are today | a component a designer built and tuned in the editor |
| **a definition** | the component's script made in code and handed the definition | a component fully described by data |
| **nothing** | the game's default component, or the pawn scene's own | the component doesn't vary for this kind |

- **Which wins, for each component:** the pawn scene's own node, then the pawn definition's, then the game's default. So a designer can still build a whole pawn by hand in the editor, and it works as today.
- **Each component takes its own definition** (`apply_definition`), so the pawn definition is a list of pieces, not one large settings file. Parts get a definition kind when a unit needs to vary them: the ability manager (ability sets), the AI manager (behaviour sets, and the sensing, state and target settings units vary), the stats (base values), and the look come first; navigation, movement and the rest later.
- **The same choice holds inside a component.** An ability set's entries, and a behaviour set's, are each an ability or behaviour scene (premade, with its child nodes) or a definition (built in code). Both are first-class: scenes for what a designer composes in the editor, definitions for what is pure data. Parts and abilities move from scenes to definitions as they move into data (agreed with the owner: everything that makes sense moves into definitions), with no change for those that stay scenes.
- **A definition names what it builds.** Each definition kind knows the script it makes (a `RangedAttackDefinition` makes a `RangedAttack`). Child nodes that are still nodes (steps, OnHit effects, interceptors) become entries in the definition when that ability moves to data; until then the ability is used as a scene.
- **Names come from the scene's root or the definition,** never from the order things were built: a behaviour's name sets its place in the fixed order and its random numbers (10.8), and rolled-back state is found by node path, so every machine must build the same names.
- **Spawn cost.** Building nodes in GDScript is slower than instantiating a scene. If spawning shows it, each pawn definition is built once and kept as a packed scene in memory, and spawns instantiate that. Measured before deciding.

### 16.2 The resources

| Resource | What it holds | Examples |
|---|---|---|
| **PawnDefinition** (an archetype) | The body scene, and per component: a scene, a definition, or nothing (16.1); tags given at spawn | Swordsman, archer |
| **AbilitySet** | Abilities, each a scene or a definition | "basic movement" (jump, dash), "sword" (three swings, heavy attack, parry), "bow" (bolts) |
| **AIBehaviourDefinition** | A behaviour's settings (a `Definition`, with `based_on` variants), one subclass per behaviour kind that has settings of its own | Chase (`lost_after_ticks`), Attack (`min_distance`) |
| **BehaviourSet** | Behaviours, each a scene or a definition | "melee fighter" (Chase, Attack, HeavyAttack, Parry), "ranged" (Shoot, KeepDistance) |
| **Faction** | Name, team, colours (or a look per pawn kind), its spawn list | Red goblins, blue goblins, the players' soldiers |
| **SpawnList** | Pawn definitions with weights, or with shares of the total | Three quarters swordsmen, a quarter archers |

- Swordsman: abilities movement + sword; behaviours melee fighter. Archer: abilities movement + sword + bow; behaviours melee fighter + ranged. Out of bolts, the ranged behaviours fail their gates and the melee ones win: no switches.
- **Behaviour settings move into definitions,** as ability settings did (ability spec 3). The node keeps what changes while playing (its decision state, ticks, wake-ups). Its exported settings forward to the definition, as `AbilityBase`'s do, so a scene that sets one still works, as an override on that node. Moving abilities over this way kept every suite passing; the same pattern is expected to here.
- **A score tuned for one set** is a variant of the shared definition (`based_on`): it changes only what it sets, and changing the base still changes every variant. This is how a set gives a behaviour its own `max_score`.

### 16.3 Putting a unit together

- **At spawn:** the pawn initializer builds the body's components (16.1), the faction is applied (team, look), then the definition's ability sets and behaviour sets are granted in order, through the same calls a pickup uses (16.5).
- **Combining sets:** the behaviour manager keeps its behaviours sorted by name (the fixed order the decider and the random numbers use, 10.8), whatever order they were added in, so the order of sets doesn't change what a unit decides. **Two entries with the same name: the later one replaces the earlier**, like an override; set order, then entry order, decides which is later.
- **Brains:** the C++ decider already shares one brain between pawns whose behaviour lists describe the same (`AIDecisionModule._brain_for`), so units of one kind share a brain without new code.
- **Compatibility:** pawns built entirely in scenes keep working, and sets add to what a scene already has, so samples move over one at a time.

### 16.4 Spawning and ids

- **A spawner takes a pawn definition or a spawn list, and a faction.** One spawner makes a mixed squad. `SpawnManager.spawn` takes the same.
- **Ids come from the `DefinitionRegistry`** (ability spec 3.1), extended to the new resources' folders: the permanent id is the file's Godot resource UID, which survives renames and moves, and the registry's small index goes on the wire. This meets the decision that ids aren't file paths, without a second id system. Premade scenes have UIDs too, so a set entry that is a scene is named the same way.
- **A spawn message says "pawn definition, faction, sets granted"** by id, and every machine builds the same pawn. Pawn kinds register once, in place of a type name per scene; the body scene still goes through `register_type` underneath.
- **Entity ids for orders:** the same work gives the order stream (netcode spec 19.10) what it needs for a followed pawn: an entity id in place of a node.

### 16.5 Granting and revoking

```
pawn.ability_manager.grant_set(ability_set, source)
pawn.ability_manager.revoke_set(source)
pawn.ai_context.behaviour_manager.grant_set(behaviour_set, source)
pawn.ai_context.behaviour_manager.revoke_set(source)
```

- **Keyed by source,** as score modifiers are (10.13): a unit's own sets are granted with its pawn definition as their source, a pickup's with the pickup. Each source revokes only its own.
- **Tier 0 (now):** the calls, with spawning using them. Behaviour sets can be granted and revoked in play (16.8); ability sets are fixed once a unit has spawned.
- **Tier 1: grants during play** (the owner, 2026-11-23). A pickup grants an ability set: the player can use it at once, and the AI gets a behaviour for it if none of its behaviours already carries the ability's tag. The ability definition names that behaviour (`ai_behaviour`, a behaviour scene or definition). Needed then:
  - The granted list becomes rolled-back state (pushed to the store, rebuilt on a load).
  - Online, a grant happens on a scheduled tick (netcode spec 19.4), so every machine adds the nodes on the same tick.
  - A pawn that gains a behaviour moves to another shared brain; brains are shared by behaviour list, so pawns with the same pickups share one.
  - Tier 1 expands this (stacking, timed grants, losing a pickup on death) as the game needs it.

### 16.6 Build steps (tier 0)

0. The AI manager tree (16.0): `AIContextComponent` becomes `AIManager` (`pawn.ai`), the five AI components become its children, the six scenes and the code that names them move over, `PawnDefaultsRes.ai_brain` goes. Every AI suite unchanged.
1. Behaviour steps (`AIBehaviourStep`) and the shared step library; the decision module parted out (16.8).
1b. `AIBehaviourDefinition` and its subclasses; behaviour settings forward to them; the built-in behaviours move over. Generic `AIBehaviourModifier`s with `modifier_on_start` and `modifier_on_end`; persistence and the two setters go (16.8). Decider parity, replay and the behaviour tests unchanged.
2. `AbilitySet`, `BehaviourSet` (entries a scene or a definition), `add_behaviour` / `remove_behaviour` in play (16.8), and `grant_set` / `revoke_set` on both managers, with the name and order rules (16.3).
3. `PawnDefinition` in the pawn initializer: per component a scene, a definition or nothing, with the order of precedence of 16.1; `apply_definition` on the first components (abilities, AI, stats, look).
4. `Faction`, `SpawnList`, registry ids; spawning through them (`SpawnManager`, `PawnSpawner`, the spawn message).
4a. Memory as a fact table and senses as stimuli (16.8): awareness and certainty, interaction labels, column write rules, inputs over columns, `AIStimulusSource`, a damage sense, and t0 hearing with footstep sounds.
4b. Game-wide cleanups found in the review (16.8): one pawn number (an entity number), one deterministic random service, attack warnings through the target's ability manager.
5. The example sets and pawn definitions: swordsman and archer, and the four factions. The four-faction battle moves over: one body scene, two pawn definitions, four factions, one spawner per faction with a spawn list. The eight `faction_*_{archer,melee}.tscn` scenes go, and with them the AI changelog's refactor rows for roles carrying every ability.
6. Tests: pawns built from definitions match the scenes they replace (the same components, behaviours and abilities, in the same order, with the same names); a set entry as a scene and as a definition give the same node; name overrides; precedence (the scene's own component wins); grant and revoke by source; the archer switch and determinism checks pass on the new pawns; a mixed spawn list keeps its shares; spawn cost measured against today's scenes.

### 16.7 Decided and next

**Decided (the owner, 2026-11-23, agreeing Claude's recommendations):**
- Behaviour settings become definitions with variants, and a set tunes a behaviour with a variant.
- Same name in two sets: the later set wins.
- A faction holds team, look and its spawn list.
- `grant_set` and `revoke_set` are built in tier 0 and used by spawning; grants during play are tier 1.
- Ids aren't file paths. *(Revised 2026-11-24: the existing `DefinitionRegistry`'s UIDs, not a new `id` field.)*

**Decided (the owner, 2026-11-24):** the AI is one component, a node tree with the AI manager at its root (16.0). A pawn is built from a pawn definition that hands each component its own, through the pawn initializer. A component, an ability or a behaviour may be a premade scene, a definition built in code, or a designer's own node in the pawn scene; all three stay supported.

**Next, separately (from the same discussion):** context-driven scores beyond today's straight-line curves: more curve shapes (quadratic, logistic, step, as utility AI usually offers), score terms that add or take away an amount from an input, and a place for a game to plug in its own AI inputs (weaknesses and resistances, for example), keeping scoring code-free and in C++.

### 16.8 The components reviewed, one at a time *(the owner, 2026-11-24: each component looked at for redundancy and fit with this design before building)*

**The behaviour manager** (`AIBehaviourManager`). The decision itself is sound: numbered steps that match the C++ decider, no new
arrays per decision, modifiers worked out only on change. Decided:
- **Generic modifiers.** `AIScoreModifier` becomes `AIBehaviourModifier`: `applies_to` (a tag query over behaviour tags; empty: the
  behaviour that applied it), `ongoing_requirements`, `duration_ticks` (a tick deadline), `blocks`, `granted_tags`, `wakes_decision`,
  and **`changes`**: a list of property (any number setting of the behaviour, by name, `score` included), add, multiply and an optional
  override. Worked out as (setting + every add) × every multiply, then an override if any (the last added wins), in the order added,
  the shape `StatModifierPart` already uses for stats (Unreal's attribute, operation, magnitude). Behaviours read their numbers through
  the same getters; a getter adjusts only a property some modifier targets. The manager works the numbers out when modifiers or owned
  tags change; C++ gets the final numbers it uses (score bonus, jitter, interrupt threshold, cooldown, minimum run), not the operations.
  Statuses such as confusion (jitter × 10) or berserk (interrupt threshold overridden) then need no code of their own: a nice property
  of the design, not something to build towards now. A held effect part (`AIModifierPart`) can apply them when one is wanted.
- **`set_score_jitter` and `set_interrupt_threshold` go:** settings are read-only in play, and modifiers do their job. Only tests call
  them.
- **Persistence goes.** Its flip-flop use has no user (min_run_ticks, interrupt thresholds, the tie margin, decision intervals and tag
  gates hold choices); its one user, Look Toward's step aside after looking (−0.3 for about 15 s), becomes a modifier it applies to
  itself. A behaviour definition gets `modifier_on_start` and `modifier_on_end`. The fade profile per behaviour, the per-pawn mask, the
  speed and add-ticks calls and their C++ columns go. If flip-flopping shows up later, the standard fix is hysteresis: one
  `switch_margin` on the AI manager.
- **Behaviours can be swapped in play, in tier 0.** The AI runs only on the server and isn't rolled back, so this has no network or
  rollback cost (granting abilities in play stays tier 1). `add_behaviour` and `remove_behaviour`, which `grant_set` and `revoke_set`
  use: changes wait for the start of the pawn's next AI step; the name order is kept and the behaviours renumbered; inputs and modifier
  numbers are worked out again; C++ gets the new brain (moving to another brain already copies the pawn's decision state from the
  nodes); removing the running behaviour stops it ("removed") and asks for a decision.
- **Cleanups:** one function for the hard rules, used by the decision and the record; `decide()` split into a C++ path and a GDScript
  path with shared setup; the AI manager hands the behaviour manager its pawn and wires the events (death, abilities ending, paths
  ending), so the behaviour manager only judges and runs behaviours; brains found by the list of definition ids instead of describing
  and stringifying every spawned pawn's brain; the manager's own settings (default jitter, ties) move to the AI manager's definition.
- **The pattern, as with persistent orders:** say it once, and the holder carries it out until it's replaced, ends or runs out. The
  running behaviour (the choice), persistent orders (the hands) and modifiers (the adjustments) all work this way.

**The AI manager** (`AIContextComponent`, to be `AIManager`). The step order (forces, sensing, decision due, target, state, decision,
the running behaviour; `while_possessed`) and the shared data (target, last hit, swing coming, inputs, the decision request with its
strongest reason) are what the root should hold, as Unreal's AI controller and blackboard do. Decided:
- **No search for components:** its children register with it (step 0).
- **Facts reach C++ one way:** version counters the decision module reads before deciding (as owned tags and modifiers already do),
  not push calls from several components through a static reference (`target_changed`, `facts_changed`, `stopped`, ...). Parts then don't
  know the module.
- **One cache:** the per-tick lookups it keeps (the target's memory entry, the most aware entry) move into `AIInputs`, which already
  caches inputs per decision.
- **Its settings** (`decision_interval_ticks`, `while_possessed`, `random_seed`) and the behaviour manager's (default jitter, ties) go
  in the AI manager's definition. The order-replay hook (`order_source`, flagged REFACTOR) stays until the order stream.

**The state manager** (`AIStateManager`). A state is read only through its tag (behaviour gates), decision records, the debug
timeline and the diagnostics panel: it is a tag picker, one mutually exclusive tag chosen by priority and conditions. Decided:
- **One priority hold.** Forcing a value with a priority and a hold, which the state manager and the target selector each write
  (flagged REFACTOR), becomes one small shared helper.
- **One request inbox on the AI manager.** Every request from outside the AI (force or release a state or target, add or remove a
  behaviour, add or remove a modifier) is queued there and applied at the start of the pawn's AI step, in the order asked, so the
  result never depends on which pawn ran first. It replaces the per-component queues, and covers modifiers, which aren't queued today. It is
  the AI side of the standard entry points.
- **States use the behaviours' conditions.** A state becomes a priority, a tag and a list of `AICondition`s over AI inputs, so there
  is one condition system, as data, that C++ can evaluate. Awareness's settings become conditions over a few new inputs (the target's
  awareness, whether it's certain, ticks since it was seen, the highest awareness in memory); Idle is a state with no conditions. States
  go in the AI definition. A state can still override `prerequisites_met` with code, as a behaviour can.
- Forces refused or replaced go to the diagnostics session log, not the console.

**The target selector** (`AITargetSelector`). A weighted sum over memory entries (awareness, nearness, threat, a bonus for the
current target), looped in C++ (`AIMemoryStore.best_target`), or in GDScript when a game overrides `target_priority()`. Decided:
- **Forcing** goes through the priority hold and the AI manager's request inbox (above).
- **The current target lives only in the AI manager;** the selector picks it and doesn't keep its own copy.
- **Ties go by pawn number,** not Godot's instance id, which differs between runs and machines (both twins today); part of the one
  pawn number.
- **A switch margin replaces the sticky-target fade:** a challenger must beat the current target by a set amount, as hysteresis does
  for behaviours. One number instead of a fade curve.
- **Later, when a game needs it:** target scoring as data, a list of weighted terms per memory entry (awareness, nearness, threat and
  values a game writes per entry, such as a weakness to the pawn's damage), so game rules stay in C++; `target_priority()` stays for
  anything stranger.
- Targets become entity ids with the order stream (16.4). Its weights and margin go in the AI definition.

**Memory and senses** (`AIMemory`, its stores, `AISensingManager`). Today the memory store also runs the sight check and the target
loop, and the rules for awareness live inside memory. Decided *(the owner, 2026-11-24)*: senses push facts, memory only stores them.
- **Memory is a fact table** (a knowledge base): one row per entity this AI knows, keyed by entity number, for pawns and anything
  else an AI should track (structures players built, hazards, objectives); one column per property, as parallel arrays. Columns are
  named and typed (number, position, true or false, tag bits), each with a default, an optional fade (the value decays from when it
  was written) and a **write rule** (add up to a cap, keep the larger, overwrite, add tags). Default columns come from the AI
  definition on the same machinery as any other; a game or a GameMode module registers its own (`weak_to_fire`), and existing rows
  take the default. Forgetting is a rule as data (a row goes when its awareness has faded to 0 or its entity is gone). Each AI keeps
  its own table; C++ is the main path, with a GDScript twin. Like the state store's dynamic columns, without history or rollback.
- **Awareness and certainty are two numbers,** each 0 to 1 and fading. **Awareness:** how aware the AI is that the entity exists and
  is around; it drives states. **Certainty:** how sure it is of the details (true position, what the entity is doing); it drives
  targeting and responses. Details are only as good as certainty: an **observed tags** column holds the entity's tags as last sensed
  (`status.powered_up`), so a guard can flee a powered-up player only above a certainty threshold, and stay alert and search while
  aware but uncertain. A fade may be chosen by a true-or-false column (awareness fading one way for certain entries, another for
  uncertain ones).
- **Interaction labels:** a tag-bits column of what an entity did (`interaction.attacked_me`, `interaction.healed_enemy`), each
  label with an optional lifetime (a tick deadline); memory clears expired ones.
- **Senses send stimuli; memory applies them** (the standard split, as in Unreal's AI perception). A stimulus: the entity, an
  awareness gain, a certainty gain, a position and its precision, observed tags, interaction labels. Memory applies it by each
  column's write rule. The sight check moves out of memory into the sight sense (beside `AISensingJob` in C++), target scoring into
  the target selector, and the hit facts the AI manager keeps (last hit, last attacker) become stimuli from a damage sense.
- **Senses are nodes, any number per pawn, each with a definition:** range, cone, interval, and its weights (how much a stimulus
  raises awareness and certainty, with distance curves). A stimulus's strength is its source's strength × a distance falloff × the
  listening sense's multiplier (strong or weak sight or hearing). How a sense detects is code (a sense script); how it weighs what
  it detects is data, and the generic modifiers adjust it ("blinded": sight's certainty gain × 0). Two kinds: **polled** (sight,
  on an interval, batched in C++) and **event-driven** (hearing, damage: on a sound or a hit). An example of extending it, not a
  feature to build: echolocation spawns a sound stimulus from an entity in line of sight, and hearing reports that sound to memory.
- **Defaults, as for typical humanoid characters:** sight gives high awareness and high certainty; sound gives moderate awareness and
  low certainty.
- **Tier 0 now: basic sight and sound** *(the owner: hearing now, to get testing data on event-driven sensing; it was deferred from
  t0)*. Moving pawns make footstep sounds at set tick intervals, louder and more often with move speed; a sound is a stimulus heard by
  pawns in range, weighted by distance and each listener's hearing.
- **Reading memory from conditions:** generic inputs over columns (`target/threat`, `target/certainty`, `max/awareness`,
  `target/observed/<tag>`, `target/interaction/<label>`, `count/<column>`), so a designer's new column works in states and
  behaviours with no code. They replace special inputs such as `most_aware_certain`.
- **What can be sensed:** an `AIStimulusSource` component on any node an AI can perceive (Unreal: a perception stimuli source), with its
  kind as tags and the senses it can be detected by; pawns get one by default. The one pawn number becomes one entity number.
- **Memory stays its own component,** a child of the AI manager: the manager holds this AI's working state (target, decision requests,
  inputs), memory what it knows about others.
- Settings move into the AI definition, so the hooks for editing fades while playing go.

**The AI's direction, after the assessment** *(the owner, 2026-11-24)*:
- **Each pawn has its own brain, by default.** The AI tree on one pawn is the solid core: plug and play, with as little
  infrastructure as possible. Batching many pawns' AI in C++ is a per-game optimization towards the 1000-pawn aspiration, not the
  base. The base builds the generic case, the tooling and the hooks that make such extensions possible, and keeps the components modular
  enough to take them (the AI step in separable phases; data in columns a batch could read). Stable, extensible architecture first;
  hard optimization later.
- **The base provides a batching implementation, opt-in** *(the owner, 2026-11-24)*: built properly, as a module a game turns on to
  run many pawns' AI phases together, never required; pawns work without it. Tuning it towards 1000 pawns waits for a specific game
  with specific needs. The base is a toolkit, a stable scaffold for the owner's games, hence its general features.
- **The C++/GDScript twins stay** as long as they don't misbehave or cost too much of the development cycle; the aim is to finish the
  base's tier 1, or tier 2, with them intact.
- **Hearing is in tier 0 because it may be expensive:** event-driven sensing at crowd scale (footsteps from every moving pawn, checked
  against listeners in range) is to be measured, not avoided.

**The decision module, forcing, and a worked example** *(the owner, 2026-11-24)*. A squad shooter walked through the design
(detection, pin from cover or search below a certainty threshold, a squad coordinator making flankers, flank or charge, a grenade
overruling everything, weapon choice by range, cautious and aggressive presets): it maps onto the components above, and decided these:
- **The decision module goes; its jobs are parted out.** Each behaviour manager owns a small C++ decider for its own pawn (one row;
  `AIBatchDecider` renamed `AIDecider`, since it decides one pawn per call); compiled brains are shared through a static cache keyed by
  the list of definition ids; facts reach the decider through version counters the behaviour manager reads before deciding; where a
  pawn decides (C++ or GDScript) is a setting on the AI definition and a project setting; shadow mode, the stale-fact check and the F10
  switch move to diagnostics and tests. The opt-in batch runner (above) holds many pawns' rows when a game turns it on.
- **A behaviour with its own code doesn't send its pawn to GDScript.** Today one behaviour with `is_available()` or `score()` code
  makes the whole pawn decide in GDScript; the "given" path C++ already has is wired instead: GDScript answers for that behaviour
  only, C++ scores the rest.
- **Forcing goes.** `force_state` and `force_target` (and the shared priority hold planned for them) are replaced by the general
  machinery: a taunt is an interaction label and threat on the taunter's memory row, which target scoring weighs; a scripted state is
  a tag a state's conditions accept. Waking a decision stays as it is: `request_decision(priority, normal)`, which state changes,
  hits and modifiers already use. **Stimuli carry an urgency** that calls it (a grenade wakes a decision at a priority that breaks
  `min_run_ticks`).
- **Roles and squad assignments are status effects:** an effect whose tags the pawn owns while it lasts (`squad.role.flanker`), with
  an `AIModifierPart` raising the role's behaviours; application, stacking and cleanup (removal, expiry, death) come with effects. A
  role that also changes stats adds a `StatModifierPart`. Needed: a "lasts until removed" duration on effects, and `AIModifierPart`.
- **Memory sources are flexible.** A fact table can be any AI's own, a squad's, the world's or a game's own: the same column machinery,
  registered by name. An AI reads its own table plus the sources it's given (its squad's, the world's), and queries and inputs say which
  source they read. Map knowledge every AI has (cover markers, fixed weapon stations, objectives) lives in a shared source, not copied
  into each AI; what an AI perceives (pawns, vehicles, dropped pickups) lives in its own. Points of interest are entities with tags, on
  the same entity system as pawns. Attack slots (positions spread around a target for surrounding it) and attack tokens (permission to
  attack, so only a few do at once) are examples of what a game might keep in a shared source, such as slots around every player's
  pawn in a small co-op game.
- **Behaviours run queries over memory and expose results as the fewest values and tags a decision needs** (cached, with tick
  deadlines when expensive). A failing query then breaks only its own behaviour.
- **Behaviours choose which action to press** (melee within reach, fire otherwise); they have the target. The ability manager's own
  choice between abilities on one action runs on every machine and can't read the AI, so range logic stays in behaviours.
- **Orders and steps** (a naming and consolidation pass below): behaviours are built from a shared library of steps native to every
  pawn, each a small node parented to the behaviour, in order; a step gives orders and ends on a condition. Bespoke steps are code
  nodes in the same place.

**Orders and steps, named:**
- **Order** *(superseded below: orders became behaviour steps)*: what the old AI controller carried out at every input until replaced, the network contract (netcode spec 19.10). Every order
  persists except `press`, which lasts one tick, so "persistent order" stops being a separate term. Three channels, one standing order
  each, every channel with the same forms (to something, in a direction, stop): **move** (`move_to(point)`,
  `move_in_direction(direction)`, `follow(node, distance)`, `keep_away_from(node, distance)`, `stop_moving()`), **look**
  (`look_at(point or node, offset)`, `look_in_direction(direction)`, `stop_looking()`; facing a yaw is a look in a direction), **buttons**
  (`press(action)`, `hold(action)`, `release(action)`, `release_all()`). `look_at_node_quietly` is an internal helper and becomes
  private.
- **Step** (`AIBehaviourStep`): a node under a behaviour; the behaviour runs its steps in order. A step gives one or more orders and
  ends on a condition (arrived, a tick deadline, a condition over inputs, a wake-up); a step can also write a value for later steps
  (a query's chosen point). The shared library, examples only: move to a point (from a query, the target's last known position or a
  slot), follow, keep distance, look at, face, press, hold, wait, run a query, grant an AI tag. Behaviours' `tick()` code stays
  possible; steps make the common sequences data. The same pattern as ability steps (ordered child nodes), kept as separate classes:
  ability steps run on every machine on a timeline and roll back, behaviour steps run on the server on conditions.
- Today's behaviours (Chase, Keep Distance, Go To Point, Wander, Search, Investigate, Look Toward, Attack, Parry) become behaviour
  definitions built from library steps where they can, with code steps where they need them.

**Naming and consolidation pass** *(the owner, 2026-11-24)*:
- **Scoring is `data` or `scripted`:** a data behaviour is scored from its conditions and curves (in C++); a scripted one by its own
  code, whose answer C++ uses (was "conditions" and "given").
- **Version counters say what changed:** a number on whatever owns some data, raised by one at each change (`OwnedTags.version`,
  `modifiers_version`, `readiness_version`); a reader keeps the number it copied at and copies again only when it differs. They replace
  push calls, so owners don't know their readers. Not ticks: two changes in one tick, after a reader copied, would look like none, and
  a rollback moves the tick back while counters only go up. Tick deadlines stay for the other job, saying when something expires or is
  due again (a cached query, a fade, a label's lifetime).
- **`AIInputs` goes, parted out:** its name registry becomes the selectors that read memory sources; the AI's own facts
  (game-written values, `action_ready`) live in a **`self` source**, a table with one row, which is the AI manager's blackboard; the
  once-per-decision cache becomes part of how the decider reads selectors (each brain lists the selectors it reads). Inputs are named
  `<source>:<what>/<column>` (`target/certainty`, `max/awareness`, `count/hazard.grenade`, `nearest/cover/distance`,
  `squad:target/threat`, `self/action_ready/primary`), backed by a few operators (the target's row, max, count, nearest with a tag,
  a computed distance), each written once in C++ and once in GDScript. A new column or source works in conditions with no new code.
- **Column types:** number, ticks, position, true or false, tags, entity. "Ticks" is a type (times written at 60 a second, converted
  once when a definition is resolved), replacing the `ticks_` name prefix; distances are always metres, so there are no other units.
  The machinery is general: a game uses as many or as few columns, of whichever types, as it needs.
- **Many columns are cheap.** Each column is its own array, so costs follow the columns a decision or stimulus touches, not how many
  exist: selectors read only the columns brains name, stimuli write only what they carry, fades are worked out when read (a fading
  column keeps a second array, its written tick). What does grow with the column count: memory (100 number columns are about 800 bytes a
  row; an AI knowing 50 entities, about 40 KB; 200 such AIs, about 8 MB, with map knowledge shared, not copied) and adding or forgetting
  a row (one append or swap-remove per column: well under a microsecond for 100 in C++, a few in the GDScript twin). Memory isn't in the
  state store, so nothing copies it each tick. Columns are kept in packed arrays grouped by type, never one dictionary per row.

**Behaviour steps, the step timeline and the input-only controller** *(the owner, 2026-11-24)*:
- **The AI controller only gives input, exactly as a player's controller does:** a move direction, a look yaw and pitch, held
  buttons, handed to the controller manager each tick. Orders, pathing, following, aiming and their tuning leave it.
- **Behaviour steps live on behaviours,** as child nodes, the way ability steps live on abilities. A running behaviour's steps are
  queued on its timeline and run until the behaviour is overruled (a decision replaces it) or completes; while they run, they write the
  AI controller's input each tick. The step library replaces the orders: `MoveTo`, `Follow`, `KeepAwayFrom`, `StopMoving`; `LookAt`,
  `LookInDirection`, `StopLooking`; `Press`, `Hold`, `Release`; `Wait`, `WaitUntil`, `Repeat`, `RunQuery`, `GrantTag`; and background
  steps (Unreal's behaviour tree calls them services) that run alongside the sequence ("press dash when the target is 4 to 8 m away",
  "hold sprint while far"). Step values are selectors (`target/last_known_position`, `nearest/cover/position`, a random point near
  one). Bespoke steps are code nodes in the same place. Branching stays in decisions: Chase's "seen or not" becomes two behaviours.
- **One step and timeline machinery, two users.** The ability step timeline (entries that start at a tick, after another entry starts
  or ends, or on a condition; steps that end on a duration or when they say done; several at once; rolled back) becomes one shared core
  (a `Step` base and a `StepTimeline`), written once. Abilities and behaviours each run their own timeline over their own steps.
- **Steps run on every machine, like ability steps; the order stream stays.** The AI's decision (senses, memory, scoring) runs on the
  server; which behaviour runs and its timeline's state (which steps run, their values) are shared, rolled-back state, so every machine
  runs the steps and makes the same input. The order stream sends behaviour and step starts with their values. Step values are
  therefore shared things (positions, entity numbers, tags), never references into the AI's memory. On a client the AI manager runs
  execution only: no senses, memory or decisions.
- **The player's click-to-move is the same `MoveTo` step,** so player and AI pawns share the step library.
- **One eye height,** on the body (in the pawn definition): `LookAt` aims from it, sight looks from it, and a ranged attack's muzzle is
  an offset from it (today three separate 1.3 m values).
- **The controller's state is gone from the order stream's keyframe;** the keyframe is the running behaviour's timeline state.
  Dropping repeated orders becomes not restarting a step that's already running with the same values.
- **Naming: "component", not "part"** (the owner's preference, Unreal's term): the pawn's pieces are components (`PawnInitializer`'s
  default components, `fill_in_default_components`), and the spec uses the word throughout.

**Effects: modifiers and effectors** *(the owner, 2026-11-24)*. An effect's pieces (today `EffectPart`s in one list) split by timing,
which the owner wants explicit:
- **Modifiers** are held while the effect lasts and change a value: `StatModifier`, `ResistanceModifier`, `AbilityPriorityModifier`,
  and `AIBehaviourModifier` (the effect holds it directly, so no wrapper is needed).
- **Effectors** fire once when the effect is applied and again each period (on the server): `StatChangeEffector` (damage, heals),
  `KnockbackEffector`, `LifestealEffector`. "Effect" would clash with the resource's own name.
- **Two lists, a fixed timing:** on application the modifiers take hold first, then the effectors fire, so a hit's damage sees its own
  effect's modifiers (as in Unreal's GAS, modifiers before executions); each period only the effectors fire; at the end the modifiers
  go.
- Class names stay short where clear (`AIManager`, `AbilityManager`), called components in the docs.

**Input, the AI controller, navigation and targets** *(the owner, 2026-11-24)*:
- **Input is controller-agnostic, and blocked by tags.** The controller manager forwards no input while the pawn owns a tag matching its
  `input_blocked_by` query (`status.dead`, `status.stunned`, a cutscene's tag), the pattern of Unreal GAS's blocking tags. It replaces
  the three death paths (the controller manager's death hook, the AI's let-go, the pawn clearing input on dead ticks). UI input
  (menus, inventory, diagnostics, save and load) never goes through the pawn.
- **No controller registered, no input:** the input is cleared, not left as it was (today the last input stays when nobody is in
  charge).
- **The AI tree's root is the `AIController`** (named after Unreal's, which hosts the brain and possesses the pawn as a
  `PlayerController` does), renamed from "AI manager" throughout this section. It implements the controller interface
  (`take_input_command`); the running behaviour's step timeline writes its input command each tick, one step per channel (move, look,
  buttons; the later step on the timeline wins an overlap). No separate input node, which also saves a call per pawn per tick. Other
  drivers (cutscenes, scripted sequences, replay playback) register controllers of their own.
- **Navigation splits into finding and following,** as Unreal's navigation system and path-following component do. `NavServer` (C++,
  project-wide) finds paths from A to B, with its queue and budget (the per-tick budget moves into it). A **path follower**, a small
  helper owned by the movement steps (`MoveTo`, `Follow`, `KeepAwayFrom`), keeps a copy of the waypoints, gives the direction to the
  next one, moves on when close enough, presses a link's action, and holds the deadlines (link crossing, waiting for a queued search).
  Its state is the step's state, so it rolls back with the step timeline (the waypoints written once when found, then the index). The
  `NavigationManager` component goes; its settings move to the movement steps' definitions. Pawn components: 7.
- **Paths are refreshed from `NavServer`:** on a deadline (a periodic definitive update), and at once when the pawn is further off its
  path than a threshold (knockbacks, pushes, teleports), when the goal moved more than a threshold, or when a link timed out. Reaching
  a waypoint only moves on to the next.
- **Targets are query results in memory.** Picking the current target is a query over memory sources (the weighted terms the target
  selector uses), whose result is written to a key in the AI's `self` source; look targets, move goals and points of interest from
  queries are keys the same way, as entities, sets of entities, locations or sets of locations (Unreal's blackboard keys set by EQS
  queries). Steps read their goals from those keys and refresh their paths when a key's value moves past a threshold. The
  `AITargetSelector` component goes, subsumed into memory and its queries.
- **Step cost at scale:** a few microseconds per pawn per tick for a behaviour with two or three active steps (an estimate, to measure):
  about 1 ms at 200 pawns, 5 ms at 1000. Wake-ups and intervals cut it; the opt-in batch runner is where it would be cut further.

**The thin AI controller, the move step, and the status manager** *(the owner, 2026-11-24; revises the block above)*:
- **The AI tree's root is the `AIManager` again,** and a **thin `AIController`**, its child, hands over input: it registers with the
  controller manager, holds the input command the running behaviour's steps write, and hands it over each tick. The manager does far
  more than hand over input, so the two stay apart for clarity; merging them would save about one call per pawn per tick (roughly 0.5
  ms at 1000 pawns), easy to do later if a game needs it. A pawn without AI has no AI controller.
- **No input queue on the AI controller for now.** Presses due at a later tick are step timeline entries (`at_tick`, `after`), so the
  timeline is the queue, also for a behaviour that ticks rarely.
- **The move step:** one path follower class, written once; a `MoveStep` base holds an instance, and `MoveTo`, `Follow` and
  `KeepAwayFrom` extend it, differing only in how they pick their goal. Only one movement step runs per pawn (one writer on the move
  channel), so there's at most one active follower per pawn, and it rolls back with its step. The classes live in a shared step
  library (`Step`, `StepTimeline` and the library steps; ability steps extend the same `Step`); instances are child nodes of whatever
  runs a step timeline: behaviours, and a small step host in the `PlayerController` for click-to-move, which runs on the owner's
  machine and sends its result as input, as click-to-move does today.
- **Later:** multimodal movement (a dragon that walks and flies) needs paths in more than one domain; behaviours made domain-dependent
  work around it until then.
- **`StatManager` and `EffectManager` merge into a `StatusManager`:** the pawn's stats and the effects acting on them, as Unreal's
  Ability System Component holds attributes and active effects together. Applying an effect and reading its result happen in one
  place, and the effect manager no longer reaches into a separate stat manager. Entities with effects but no stats (a crate that's
  wet or burning) work: their stat list is empty. Stats stay nodes under it for now (the stats pass decides more). **Owned tags stay a
  component of their own:** every system reads them, and effects are only one of their sources.
- **Pawn components: 6:** controller manager, ability manager, status manager, owned tags, the AI tree (the AI manager, with the AI
  controller inside), streaming source.

**Hits: blocked versus ignored** *(the owner's clarification, 2026-11-24, noted to avoid drift)*:
- **Blocked:** the hit is still received (it registers: the AI notes the attack, records and diagnostics see it), but the rest of its
  payload doesn't apply. Parrying blocks it (and reflects it), and so do statuses such as invulnerable or dead. A parry's reply can
  itself be parried: the cooldown and frame-perfect timing keep chains from running on, except through bugs or cheats.
- **Ignored:** `status.hit_immune` (set pieces, environments, entities that react only to particular abilities for plot or progression)
  means the hit ability doesn't start at all: a start requirement on it. Hits that such an entity does react to are named by the hit's
  definition.
- **Reactions come from the hit giver:** the hit's definition names the reaction and its start values (a strong blow's long knockback,
  a quick strike's flinch), passed to the reaction ability as the event's payload.

**The ability manager** (`AbilityManager`, `AbilityBase`) *(the owner, 2026-11-24)*. Starting, cancelling, press priority, locks,
combos and rollback are sound and stay. Decided:
- **Each ability and each behaviour owns its own `StepTimeline`** (a class, instanced per owner, as each ability's timeline is today);
  there is no shared per-pawn timeline. Behaviour steps write input and ability steps read it, so the two never compete; within each,
  the existing rules hold (one running behaviour, one writer per input channel; abilities' locks and interrupts). The ~300 lines of
  timeline code leave `AbilityBase` for the shared core. Ability-only step settings (a step's interrupt threshold, ending when its
  action is released) stay on `AbilityStep`, which extends the shared `Step`.
- **Settings: typed reads, generic writes.** Code reads `settings.<name>` directly (typed, fast); writes from outside
  (`ability.cooldown = x`) go through one generic `_set` (and `_get`) that routes them to the node's own variant, with the same "no writes
  to a shared definition in play" error. The 25 hand-written forwarders go (and behaviours' 36 are never written).
  `_get_property_list` can show a node's settings as overrides in the inspector.
- **Interrupts stay as they are** (the dials are built; their feel is tuned when a game is made): `category`, `locks_out`,
  `interrupt_priority`, `interrupt_threshold`, `cancelled_by`, per-step thresholds (cancel windows), and effects adding to priority and
  threshold. No separate lane for reactions: the hit ability's category is in no ability's `locks_out`, so it runs alongside anything,
  gated only by tags; reactions cancel by the numbers (Knockback 30 beats a swing's 15); hyper armour is a higher threshold (per step
  for part of a swing); Death (1000) cancels everything.
- **Hits are resolved by an ability.** The attacker's step books the hit with the tick scheduler (delivered after simulate, ordered by
  attacker, target and queue order; the static hit queue goes). On delivery, the target's **hit ability** runs, gated by start
  requirements (`status.hit_immune` ignores the hit). It's instant, resolving each hit in the tick it's delivered: a blocked hit
  (parrying, invulnerable, dead) is received but its payload stops, and a parry reflects it to the attacker; otherwise the status
  manager applies its effects; then events go out. Hit resolution runs on the server; reactions are ordinary abilities on every
  machine. Parry and invulnerability are status effects granting tags; details a tag can't carry (the parry's cone, its reply) come
  from the effect or ability that granted it. The `HitInterceptor` nodes go.
- **Effects change values; abilities react.** Damage and heals are effects (`StatChangeEffector`), applied by the status manager, never
  blocked by an ability's lock. Reactions (`HitReact`, `Knockback`, `Death`, a revive) are abilities **started by gameplay events**
  (`event.hit.taken`, `event.health.depleted`) as well as by input actions, through the same start rules; the event carries a payload
  (the hit, and the reaction's start values from its definition), as Unreal's gameplay events do.
- **Charges belong to each ability:** spending, restore deadlines, refilling on a revive event. It exposes a tag (`status.has_ammo.ranged`)
  and an observable charge count with a version counter (for the UI, a debug inspector, the AI's `self` source). The manager's charge
  list goes. Restoring Health is an effect; a revive ability applies one.
- **Time: ticks at 60 a second everywhere,** abilities and effects included (cooldowns, durations, periods, link timeouts), with a
  designer helper converting to and from seconds and the inspector showing seconds beside each value. `ticks_for(seconds)` goes.
- The interrupt table's text dump moves to diagnostics; OnHit and interceptor child scans go as those move into definitions.

**The status manager** (`StatusManager`: today's `StatManager` and `EffectManager` merged) *(the owner, 2026-11-24)*:
- **Stats:** nodes to start with, each with three values: **base** (the designer's number), **max** (base with modifiers; called
  `value` on a stat that doesn't run down) and **current** (for stats that run down, such as Health: rolled back, changed only on the
  server). Version counter as today. In a game that uses the central table, a stat with no column there asks for one when it
  initializes.
- **Active effects:** the compact rolled-back list, each entry the effect's id, the tick it ends, the tick of its next period, stacks
  and its source's entity number. **No countdowns:** the status manager does nothing between deadlines, and remaining time (for UI) is
  the deadline minus the current tick. Durations and periods are ticks at 60 a second.
- **Modifiers, one shape and one rule** for stats, abilities and behaviours: what they target (a stat by name, abilities by tag,
  behaviours by tag), which number, and multiply, add and an optional override (the last added wins). **The order is the designer's:**
  a game-wide default in the game mode, which a stat (or a modifier target) can override; the base's default is multiply, then add
  (`base × multiplies + adds`), which curbs stat inflation. Multiplies combine (×0.7 twice is ×0.49). `AbilityPriorityModifier` becomes
  `AbilityModifier`, able to target any ability number (cooldown, maximum charges, priority, threshold); stats gain override.
- **Thresholds fire from the one write path:** every change to a current value goes through `change_current(stat, amount, source)`,
  which checks the stat's thresholds (data: Health at or below 0 sends `event.health.depleted`, at or below 25% `event.health.low`) and
  sends an event when a change crosses one, at once, carrying its source. No polling. A value restored by a snapshot or a rollback
  fires nothing; clients see the outcome through rolled-back state.
- **Resistances:** base values from its definition (in the pawn definition), resistance modifiers from effects on top.
- **In the hit and event flow:** the hit ability applies a hit's effects through it; it doesn't receive hits. Damage taken goes out as
  an event with its source (how the AI notes threat; effects no longer write into memory). A harmful effect's periodic tick is blocked
  by the same tags as a hit (`status.invulnerable`, `status.dead`).
- **Which effects apply when moves into definitions:** `HitDefinition.effects` (to the target, on a hit) and
  `AbilityDefinition.start_effects` (to the pawn itself, on start) replace the `EffectApplier` child nodes and the ability manager's
  scan for them. Intercept is gone entirely (`HitInterceptor` and its trigger).
- **The central table** (`PawnTable`, renamed **`EntityTable`**, with `SharedPawnTable` becoming `SharedEntityTable`): keyed by entity
  number, it will hold structures, hazards and points of interest as well as pawns. Columns can already be added, switched on and off
  at any time, and rows join and leave. The state store, by contrast, fixes an entity's columns when it's created (its layout): a stat
  granted in play would need the entity moved to a new layout, a known gap for tier 1.
- **One column architecture** for the entity table and memory's fact tables (the owner), and the same column types and registration for
  the state store: number, ticks, position, true or false, tags, entity. Storage stays separate (this tick's shared data, each AI's
  knowledge, rolled-back history).
- **For the stats pass:** stats as state store columns instead of nodes.

**Owned tags and the streaming source** *(the owner, 2026-11-24)*:
- **Owned tags on any entity,** not only pawns (a burning crate, a structure, a hazard), like Unreal's tag container on any actor. Its
  features stay: counted tags, owning a tag owns its parents, sources (each component sets its own list: running abilities' categories,
  held effects' tags, `status.dead`, the AI state's tag) and loose tags (game code; counted, pushed, rolled back), a version counter, a
  `changed` signal, and the bitmask words C++ reads.
- **The streaming source stays on every pawn** (any unit can be possessed). Its features: it keeps the world loaded around its pawn while
  a player has the pawn, or always with `keeps_world_loaded` (a hero); an **off switch**, `active`, which can be changed at any time and
  stops it counting whatever else is set; it joins the streaming group only while it might count, so streaming looks at few sources;
  its load and nav distances are handed to it by the pawn initializer from the pawn definition (the game's defaults as fallback),
  replacing its lookup through the game mode.

**The pawn, the player controller and spawning** *(the owner, 2026-11-24; camera and player controller tuning come in a later pass)*:
- **The pawn:** the dead branch in its input phase goes (input blocking by tags); **pawns sleep until their next deadline** (components
  report their next deadline and the pawn sets `due_tick` to the earliest, so running cooldowns and buffs no longer keep a pawn awake);
  **one join point**: the pawn registers once with an entity registry that tells the services subscribed to it (entity table, crowd
  mover, tick driver, activation) instead of reaching five services itself; `dead` becomes an entity table column mirrored from
  `status.dead`; the stagger uses the entity number; **team** becomes an entity table column (structures and hazards can have one),
  set by the faction at spawn.
- **`yaw` becomes `facing`, a normalized Vector3,** for looking and every other use (a flyer's full 3D direction included). The body
  itself still never rotates (rotating it caused local-versus-global mistakes); only the visual turns. On the wire and in the state
  store a unit vector can be sent compactly (as yaw and pitch, or an octahedral encoding: two numbers).
- **Linger is general:** an entity that's despawned can linger, hidden, not ticking and not colliding, until whatever still needs it
  ends: its projectiles today, and equally effects it applied, sounds, scheduled actions it booked. `linger_until(tick)` takes the
  latest of all the reasons.
- **The player controller:** click-to-move is a `MoveTo` step in a small step host (decided); camera handling moves to a player camera
  component, as Unreal's `PlayerCameraManager` sits beside its `PlayerController`; input mapping contexts (switchable key binding
  sets, Unreal's Enhanced Input) wait for a game that needs them.
- **Spawning and the game mode modules:** spawning takes pawn definitions, spawn lists and factions with entity numbers (decided);
  delays (`SpawnManager.after_seconds`, the spawner's respawn and body-removal waits) become actions booked with the tick scheduler, in
  ticks at 60 a second; team counts come from the entity table's team column; **AI activation and the load ladder merge into one
  significance manager** (freezing where the ground isn't loaded, stepping by distance, the overload rule), Unreal's Significance
  Manager idea, which also takes the ladder out of the tick driver; `possessable` stays a flag on the controller manager.

**Found along the way, game-wide** *(the owner: cull redundancies intelligently; centralize what every system uses)*:
- **One pawn number.** The AI's `number_of` (network id, else a hash of the name) and hits' `HitInfo.key_of` (network id, else Godot's
  instance id, which differs between runs) become one number on the pawn, with the name-hash fallback.
- **One deterministic random service, game-wide.** Today the AI has a hash of its own (seed, pawn number, tick, salt; a bit-for-bit
  twin in C++) and abilities and spawning use `TickDriver.tick_rng` (a Godot generator reseeded each call). They become one stateless,
  counter-based generator (the standard term: a number is a hash of seed, key, tick and salt, so nothing is stored and skipping a call
  never shifts the next): a static class with no autoload, since it holds no state, with `unit`, `signed`, `range`, `int_range` and
  `pick`, and the match seed from the game mode. The AI's hash is the one kept, since C++ already has it. What stays apart: debug tools
  that are meant to be random (the network fault simulator) and terrain noise.
- **Pawns are called through standard entry points, whoever calls, itself or another.** No system reaches into another pawn's components.
  First case: melee swings and fired projectiles call `other.ai_context.note_incoming_attack(...)`; instead the warning goes to the
  target's ability manager as a signal (`attack_incoming`), as `hit_arrived` already does, and the AI manager listens (a player's
  pawn can use it for a warning on screen). The same rule is checked for every component as the review goes on.
