<!-- Written by Claude (claude-opus-5-5), 2026-11-28: a refresher on the pawn redesign and the project's state, for picking the pawn back up. Built from pawn spec 16, the redesign log, the roadmap, the system READMEs and changelogs, and the code at commit 347354a. -->

# Pawn checkpoint (2026-11-28)

A refresher, not a spec. The design is [pawn spec 16](PAWN_SPEC.md); the reasons behind it are in [REDESIGN_LOG.md](REDESIGN_LOG.md).

## In one minute

- **The pawn redesign is 7 of 11 steps in.** Foundations, steps, status, hits, input, AI decisions and behaviour steps are built. Next is **step 8, memory and senses**, the biggest AI step left.
- **Today the pawn has the 6 planned components:** ControllerManager, StatusManager, OwnedTags, AbilityManager, the AI tree, and PawnStreamingSource.
- **Abilities and behaviours share one step system.** A behaviour acts only by starting steps (move, look, press), and the steps write the pawn's input.
- **Cost:** about 75 µs of GDScript per AI pawn per tick. The mass battle at size 25 (about 94 pawns) runs a 10.5 ms tick, about 60% of the budget. GDScript tuning is done; the next big saving is common steps in C++, later.
- **⚠ Nothing since the redesign began is pushed.** That's 22 commits, from `22927f0` to `347354a`, only on this machine.

## Where the project stands

| Area | State |
|---|---|
| Tick driver, state store, rollback, replay v0, diagnostics v0 | Built |
| Netcode | Delta snapshots built. v2 direction agreed (100-200 players, orders for AI crowds), not built |
| Navigation, terrain, crowd mover (C++) | Built for tier 0 |
| **Pawn redesign** (roadmap 5a) | **Steps 1 to 7 of 11 built** |
| After the pawn | Animation v0 and the design studio, then effects handler v0, then UI v0 |

The roadmap's "Now" section still says Diagnostics v0, which is done. The pawn redesign is what's current (see "Stale docs").

## The pawn today

```
Pawn (CharacterBody3D)             body, tick order, flags (dead, frozen, sleeping, tick_step), component refs
├─ ControllerManager               who's in charge + this tick's input (rolled back); blocks input by tag (status.dead)
├─ StatusManager                   stats (base, max, current) + active effects; thresholds send events
├─ OwnedTags                       tags the pawn owns now, counted
├─ AbilityManager                  starts/runs/cancels abilities from input actions or events
│  └─ Walk, Jump, Sprint, Melee, Ranged, Parry, Dash, ReceiveHit, Knockback, Death ...
├─ AIManager (pawn.ai)             the AI step, shared AI state, the request inbox
│  ├─ AIController                 hands over the input the running behaviour's steps wrote
│  ├─ AISensingManager └─ SightSense
│  ├─ AIMemory                     awareness per sensed pawn, fading      ← rewritten in step 8
│  ├─ AITargetSelector             picks the target                       ← goes in step 8 (a query)
│  ├─ AIStateManager   └─ Idle, Alert, Combat (AIAwarenessState)         ← states as conditions in step 8
│  └─ AIBehaviourManager           owns its AIDecider (C++), scores and runs one behaviour
│     └─ Wander, GoToPoint, LookToward, Investigate, Search, Chase, GoToLastKnown, KeepDistance, Attack, Parry
│        (each with its own StepTimeline of library steps)
├─ PawnStreamingSource             keeps the world loaded while a player has it (or keeps_world_loaded)
└─ TickStateComponent, NetworkEntity, Visual, collision shape (in the scene)
```

`PawnInitializer` fills in whatever the pawn's scene lacks, from `resources/pawn_defaults.tres`. A pawn's own node of the same name wins.

### One tick

1. **Input phase.**
   - The AI step (server or offline only): apply the inbox, sense, decide when due, then run the running behaviour.
   - Then the ControllerManager asks whoever is in charge (the player or the AIController) for input. The AIController runs the behaviour's step timeline, and the steps write a `StepInput`: move, look, buttons.
2. **Simulate phase.**
   - Status deadlines that are due, then abilities (they read the input and write velocity and facing), then gravity.
   - Then one move: the crowd mover's, or `move_and_slide`.
3. **After simulate.** The `TickScheduler` delivers hits, in a fixed order: attacker, target, queue order. The target's `ReceiveHitAbility` decides whether each hit is **ignored** (`status.hit_immune`), **blocked** (parrying, invulnerable or dead) or **landed**.
   - A landed hit applies its effects and sends events. The reaction (knockback, flinch) and Death are abilities started by those events.
4. **Record.** The state store copies the tick.

### Who talks to whom

- **Nobody reaches into another entity's components.** They call its entry points or send an event (`pawn.send_event`).
- **Outside code asks the AI through the inbox** (`pawn.ai.add_modifier`, `remove_modifiers`, `set_input`). Requests apply at the start of that pawn's next AI step, so the order pawns run in never changes a result. Nothing can force the AI into a state or target.
- **Controllers only give input** (`take_input_command`). The player's click-to-move runs a `MoveTo` step through `ControllerStepHost`.
- **Effects** hold **modifiers** (kept while the effect lasts) and **effectors** (fired on application and each period). Every modifier in the base works the same way: multiply, then add, with an optional override.

### Rules of thumb that hold everywhere

- **Every timer is a tick deadline** (the tick it ends), and **version counters** say whether something changed. Settings are in ticks at 60 a second.
- **Definitions hold settings** (abilities, behaviours, hits, effects), with `based_on` variants. A node holds only its running state, and outside code reads and writes settings by name.
- **Sleeping, frozen and paused are three different things:**
  - **Sleeping:** an idle pawn skips simulate until woken.
  - **Frozen:** there's no ground loaded around it, so it doesn't tick at all.
  - **Paused:** the whole game is stopped.
- **The AI decides in C++.** GDScript is the backup, and it also answers for behaviours that have their own code. Brains are shared through a store keyed by their description.

## The build order (spec 16.10)

| # | Step | State | Left over |
|---|---|---|---|
| 1 | Foundations: entity number, deterministic random, ticks at 60, tick scheduler | Built | Sending the match seed to clients. Effect sources by entity number offline (step 9) |
| 2 | Step core; generic `_set`/`_get` settings | Built | Showing a node's settings as overrides in the inspector |
| 3 | Status manager: the merge, modifiers and effectors, thresholds | Built | — |
| 4 | Hits through the scheduler; parry and invulnerability as effects; event starts; charges | Built | — |
| 5 | Input blocked by tags; the AI tree; path follower in `MoveStep`; NavigationManager gone | Built | `ai_brain` still exists (goes in step 10) |
| 6 | AI decisions: decider per manager, behaviour definitions, generic modifiers, inbox; AI scoring | Built | States as conditions, moved to step 8 |
| 7 | Behaviour steps: the step library; behaviours act only through steps; order-stream hooks | Built | Query steps, grant-tag steps and selector values (step 8). The timeline in the state store (tier 1) |
| **8** | **Memory and senses** | **Next** | |
| 9 | Entities: `EntityTable`, entity registry, tags on any entity, `facing`, linger, sleeping until the next deadline, significance manager | Not built | |
| 10 | Units: `PawnDefinition`, ability and behaviour sets with grant and revoke, factions, spawn lists | Not built | |
| 11 | Content and tests: swordsman and archer, four factions; the eight role scenes go | Not built | |

### Step 8 in brief: what changes

| Today | After step 8 |
|---|---|
| `AIMemory`: one awareness value per sensed pawn, fading | A **fact table**: a row per known entity, typed columns with write rules and fades. Two numbers, **awareness** and **certainty**. Interaction labels such as `interaction.attacked_me` |
| `SightSense` writes memory directly | Senses send **stimuli** and memory applies them. Sight, **hearing** (footsteps) and a **damage sense**. An `AIStimulusSource` on anything that can be sensed |
| `AIInputs`: named numbers, worked out per decision | **Selectors** such as `target/certainty`, `nearest/cover/distance` and `self/action_ready/primary`, in C++ and GDScript |
| `AITargetSelector` | The target is a **query** over memory that writes a `self` key |
| `AIAwarenessState`: code over memory | States are **conditions over selectors** |
| — | Steps can run queries, grant tags and take their values from selectors |

It touches both deciders (the C++ one reads selectors in place of inputs), every behaviour's conditions, and the sensing job in C++. It's worth splitting into parts (8a, 8b and so on), as steps 5 to 7 were, and agreeing the split before building.

## Flagged hacks touching the pawn

The "rock-solid base" rule says to fix flagged hacks before the next step. The small ones were fixed in the cleanup pass after this checkpoint (the changelogs' 2026-11-28 rows):
- Death and Knockback are found by category (`ability.death`, `ability.combat.knockback`), not class.
- One default-steps pattern in `AbilityBase`, not a copy in each attack.
- The missing-input defaults are shared constants.
- The test hooks left `InputActions`, `StatusManager`, `MeleeAttackAbility` and `VisualSmoother`.
- The shooter's predicted projectile asks `HitQuery`.

Still open, each fixed by a later step:

| What | Where | Fixed by |
|---|---|---|
| States written as code over memory | `AIAwarenessState` | Step 8 |
| A third copy of the sight rule | `SightSense` | Step 8 (sight out of memory) |
| One static order hook for every pawn | `AIManager.order_source`, `AIBehaviourManager.order_listener` | The order stream (tier 1) |
| Roles carry every ability | mass battle role scenes | Steps 10 and 11 |
| Effect sources kept by instance id offline | `StatusManager._source_key` | Step 9 |
| Stat, effect and status classes in three folders | `stats/`, `effects/`, `status/` | M; saved resources name their scripts by path |

**Not hacks, just not done yet:**
- The code still says "parts" (`fill_in_default_parts`, `skip_default_parts`, `PawnDefaultsRes.parts`), where the spec says these get renamed to components.
- The body still keeps `yaw`; `facing` comes in step 9.

## Stale docs found

All fixed in the cleanup pass after this checkpoint:
- Pawn spec 16's heading.
- Sections 2 (today's tree), 12 (marked as the first build) and 14 (each item marked built, superseded or moot).
- The note on 13 #9.
- The roadmap's "Now".
- The pawn, AI and status READMEs.
- CLAUDE.md's map.
- The abilities changelog's stale rows.

## Open decisions

**From pawn spec 13, still open:**

| # | Question |
|---|---|
| 4 | Turning on the spot without an ability: who turns the pawn? `facing` in step 9 is the natural place to settle it |
| 7 | Which component plays animations. This is animation v0's question |
| 10 | A debug readout above each AI pawn (state, awareness, top scores). Useful early in step 8 |
| 11 | Spreading AI work: per-pawn offsets (today) or a central budgeted queue. It overlaps the significance manager (step 9) |
| 12 | A cap on sensing rays per pass |
| 13 | A switch that turns stealth off for a game |
| 14 | Personality jitter. Partly covered: jitter can be drawn once per pawn as an option (AI scoring) |
| 15 | The `detectability` name. In use, so probably settled |

**For step 8:**
- How to split it into parts, and in what order.
- Which default memory columns a humanoid gets.
- How often footsteps sound, and how far they carry.
- Whether the debug readout (#10) comes first.

**Later (16.11):** ability grants in play (tier 1), the stats pass, more scoring curve shapes, multimodal movement, the camera component, squads, the batch runner and relevancy.

## Suggested next

1. **Push** the 22 local commits to `vibe` after a full suite run (the last full run was 2 commits ago).
2. **A small cleanup pass:** the stale docs and the small hacks. *(Done.)*
3. **Design step 8 together before building:** its split, the columns, the selectors' names and the stimulus shape. That's a big design, so it gets discussed first.
