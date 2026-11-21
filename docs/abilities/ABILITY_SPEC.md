# Ability Spec v0.2 (agreed direction; parts 1 to 3 built: state pushed, timers as deadlines, definitions, step timelines)

*Written by Claude (claude-opus-5-5), 2026-11-19, from the discussion with the owner the same day.*

**Status:** agreed direction. Abilities v2 are part of the full refactor on its own branch ([STATE_STORE_SPEC.md](../state_store/STATE_STORE_SPEC.md), "How it's built"), written straight against the state store, after the tick driver, the store and the pawn (the owner, 2026-11-19).

**What it changes:** how abilities and their steps are built, so they fit the state store: settings move into shared definitions, timers become tick deadlines, steps are sequenced by no-code step timelines, and state is read and written through one small layer that the store can later sit behind. The rules players and AI see (actions, priorities, interrupts, combos, buffering, hits) don't change. Today's design is pawn spec 8 (8.20 steps, 8.23 interceptors, 8.24 projectiles).

**Written against the store.** An earlier plan built this first on today's recording; with the rewrite in place, abilities read and write their state in the store from the start.

**Built in parts** (Claude, 2026-11-21), each tested and measured before the next:

1. **State pushed, timers as deadlines** (sections 4 and 5): built 2026-11-21 ([state store spec 13.10](../state_store/STATE_STORE_SPEC.md)).
2. **Definitions** (section 3), and the registry that gives them ids (section 3.1): built 2026-11-21 (as built: 3.2).
3. **Step timelines and conditions** (section 6), replacing the steps' links and their counting `step_state`: built 2026-11-22 (as built: 6.5).
4. **References as ids, projectiles and arcs** (sections 7 to 9), with projectile penetration and lag compensation (9).

## 1. Decided

| Question | Answer | Whose call |
|---|---|---|
| Layers | Kind (code, on the ability node's script), definition (a variant's values, a Resource), state (per pawn) | the owner |
| Nodes | Thin nodes: an ability node holds its definition reference and its state's place, nothing else. The code is its script, compiled once and shared | the owner |
| Variants | Shared definition files, one based on another: the intended workflow for the shipped base, designers and modders | the owner |
| Quick tweaks | A definition embedded in the node (Godot's "Make Unique"), for rapid prototyping. Saving it as a file makes it a variant | the owner |
| Broken references | Fall back to the kind's own defaults, and announce it | the owner |
| Timers | Tick deadlines, never countdowns | the owner |
| Steps | Thin child nodes: building blocks the ability declares it uses | the owner |
| Sequencing | No-code step timelines are the typical way; a bespoke script running the same step nodes is the alternate | the owner |
| Step timelines | A timeline in ticks from the ability's start, with start rules, steps able to run at the same time (called "chains" until 2026-11-21) | the owner's idea |
| Extending | New data before new code; a subclass for new logic (a double swing can extend MeleeAttack, or be a longer timeline) | the owner and Claude |
| Ids | A definition's permanent id is its Godot resource UID; a small index at runtime; replays and saves keep a table from one to the other (3.1) | the owner (2026-11-21) |
| Locomotion | Walk and Sprint stay code with a definition, no step timeline: they run every tick with no sequence of steps | the owner (2026-11-21) |
| Order | In the full refactor, after the tick driver, the store and the pawn; written straight against the store (2026-11-19, replacing "before the store") | the owner |

## 2. The three layers

| Layer | What it is | Example | Where it lives |
|---|---|---|---|
| Kind | The code: how a melee attack, a dash or a jump works | `MeleeAttackAbility.gd`, `MeleeSweepStep.gd` | The node's script, one copy for every pawn |
| Definition | One variant's values | "Goblin Swing": windup 8 ticks, arc keys, reach 1.8 m, hit radius 0.8 m, on-hit effects | A Resource file the node references, or one embedded in the node |
| State | What one pawn's ability is doing now | ready at tick 4120, timeline entry 2 started at tick 4108 | The node's variables, pushed to the store when they change |

A pawn's ability nodes look as they do today; only what they hold changes:

```
Goblin (Pawn)
└─ AbilityManager
   ├─ Walk   (WalkAbility)          definition = walk_default.tres
   ├─ Swing  (MeleeAttackAbility)   definition = goblin_swing.tres         (shared variant)
   │  ├─ Turn    (TurnToFaceStep)
   │  ├─ Windup  (WindupStep)
   │  └─ Sweep   (MeleeSweepStep)
   └─ Shoot  (RangedAttackAbility)  definition = <embedded>                (a quick tweak)
```

## 3. Definitions

- **A definition is a Resource per kind**, such as `MeleeAttackDefinition` extending `AbilityDefinition`. The base holds what every ability has today: trigger action, category and extra categories, priority and jitter, combo positions, duration, cooldown, lockouts, buffer window, interrupt priority and threshold, cancelled-by, locomotion pausing, full movement. A kind adds its own (a melee attack's timings, arc and hitbox).
- **Variants:** a definition can be based on another and change only what differs ("Goblin Swing (fast)" based on "Goblin Swing").
- **Embedded definitions** are the same type, saved inside the node. Diagnostics lists pawns running embedded definitions, so a prototype tweak left in by accident is easy to spot.
- **Read-only while playing.** A definition is shared by every pawn that uses it; changing one at runtime changes them all. Per-pawn differences come from variants or from stats and effects (as ability priority bonuses work today), never from writing a definition.
- **In the join check:** definitions go into the content hash, so connected machines have the same ones.
- **Fallback:** a missing or broken definition falls back to the kind's defaults, with a warning in the session log and diagnostics naming the pawn, the ability and what was missing. Connected machines fall back the same way (the hash); the replay records it.
- **Checked once, when loaded:** a step timeline naming a step the ability doesn't have, a bad start rule, a loop.

### 3.1 Ids and the registry

Definitions and effects need an id that's the same on every machine, so the store, the network and replays can name one in a few bytes instead of a file path. Two kinds, as engines usually do it (Unreal's asset ids and network handles, Source's string tables):

- **The permanent id is the definition's Godot resource UID** (`uid://...`): a 64-bit number Godot stores with the file. It's part of the file, so it's the same on every machine, and it survives renames and moves. Replays and save files record this one.
- **The runtime index** is small and dense: the registry scans the configured folders when the game loads, sorts what it finds by UID and numbers it 0, 1, 2 and so on. The store and the network use the index. Sorted by UID, not by path or by the order the disk lists files, so every machine with the same files gets the same numbers.
- **Between machines:** the join check's content hash already covers the definitions, so two machines whose indexes could differ never play together.
- **Replays:** a replay's header holds its table from index to UID. Playback maps each recorded index to its UID, then to whichever file has that UID now, so added or renamed files don't break an old replay. A definition whose content changed since the recording is still found, but the run can't come out exactly the same (true of any engine's replays across a patch), so the replay also records the content hash and playback warns when it differs.
- **Duplicates:** a file copied outside the editor can carry the same UID as its original. The registry checks for that when it scans and says which files clash.

### 3.2 As built (part 2, Claude, 2026-11-21)

- **Classes:** `AbilityDefinition` and one per kind (`MeleeAttackDefinition`...), in `abilities/definitions/`. A kind's defaults are set in its definition's `_init()`.
- **No default files.** An empty `definition` means the kind's defaults, made in code and shared per kind. A default `.tres` per kind would freeze the code's defaults at the moment it was saved (Godot saves values that differ from a property's declared default, and a kind's defaults are set in `_init()`), so the two could drift. A designer starts a new definition of the kind, which shows the defaults.
- **Readers didn't change.** The node keeps a read-only property per setting, by the old name, reading its worked-out settings. A write before the manager sets the node up (a script's `_init()`, a value an old scene sets) goes into a variant of the node's own on top of its definition; after that, only once `make_definition_unique()` gave it one.
- **Changes are tracked only on a variant** (one with a base), so a kind's `_init()` defaults never count as changes. Give a variant its base first, then change what differs. A value set back to the base's value follows the base again.
- **Embedded definitions have no index yet.** The plan was the scene's UID plus the definition's place in it; the registry only scans definition files, and nothing reads ids until part 4, which settles it.
- **Measured** (300-pawn mass battle, headless, `--size=100`, 0.42 ticks a frame): `pawn.abilities` 0.36 to 0.37 ms a frame before, 0.41 to 0.46 with every setting read through the node's property, 0.36 to 0.37 once the reads made every tick (the manager's action check, Walk's stat check) use the input bit or the typed settings directly. Code that runs every tick reads `settings` (or the kind's typed copy) rather than the property.

## 4. State, as tick deadlines

Every timer is the tick something happens, not a count of ticks left (built in part 1). The value doesn't change while the timer runs, so there's no per-tick countdown, deltas are empty, rollback restores less, and a pawn running every Nth tick needs nothing special: it checks `tick >= deadline` on its next run.

| Counted down before | Now |
|---|---|
| `AbilityBase.ticks_left` | `started_at` and `ends_at` |
| `cooldown_ticks_left` | `ready_at` |
| `buffer_ticks_left` | `buffer_until` |
| `AbilityManager.combo_window_ticks_left` | `combo_open_until` |
| `JumpAbility.ticks_off_ground` | `left_ground_at` |
| Knockback's fade | worked out from the run's `started_at` (`push_ticks` stays: it's a length) |
| Sprint's charge | the charge and the tick it last started or stopped (`charge_at_switch`, `switched_at`); `ready_at` when it can start again |
| `step_state` (running, step ticks) | each timeline entry's start, end, end reason and count origin (6.5) |
| An effect's ticks left and period left | not yet: `ends_at` and `next_pulse_at` |
| A projectile's ticks left and distance travelled | not yet: its launch tick (part 4, section 9) |

Values that aren't timers stay as they are: Dash's direction, Knockback's push velocity, the combo position.

**Re-basing:** when a timer's rate changes (a haste effect on cooldowns) or it pauses (a freeze), the remaining time is worked out and a new deadline set. Sleeping is an optimisation and must not change results, so deadlines keep running while a pawn sleeps. Death runs with `ends_at = NEVER` while Health is 0, so sleeping doesn't touch it. A locomotion paused by an action (`pauses_locomotion`) moves its deadlines on (`delay_run`).

## 5. Reading and writing state

Built in part 1: an ability's state stays in variables on its node, the working copy during a tick (state store spec 4), and each one's setter pushes the new value to the store (`push_state`), so the commit never reads an ability node and a read costs a member variable. A layer that reads and writes only through the store's columns (an ability declaring its columns, then reading and writing them by index) is the next step if a worker job ever runs abilities off the main thread.

## 6. Steps and step timelines

### 6.1 Steps

- **Thin child nodes** of the ability: windup, turn, sweep, wait, fire a projectile, apply an effect, open the combo window. Each kind's code is shared.
- **Building blocks:** the ability declares the steps it uses by having them as children. A step node can run several times in one ability, with different values each time (a second sweep on a backswing arc).
- **Values per run** come from the timeline entry (or the bespoke script), falling back to the step's own.
- **A step decides its own end:** its length, or its condition. It ends with a reason: done, released, failed or cancelled.
- **Steps can run at the same time** (a turn alongside a windup). The ability's interrupt threshold is the strictest of its running steps', as now; a step can go along without holding the ability open (`keeps_ability_running`, as now).

### 6.2 No-code step timelines

The typical way to sequence steps. The definition holds a **step timeline**: a list of entries, each naming a step node, the values it runs with, and a **start rule**. Ticks count from the ability's start. It's a timeline in the usual sense (Unity's Timeline, Unreal's Sequencer, Godot's animation tracks): entries can overlap, and besides a fixed tick an entry can be started by another entry or a condition, as an event track does.

```
Goblin Swing
  1. Turn     start: at +0
  2. Windup   start: first of [at +10, when angle_to_look < min_angle]
  3. Sweep    start: on end (done) of 2        values: arc = goblin_arc

Goblin Swing (simultaneous)
  1. Turn     start: at +0
  2. Windup   start: at +0
  3. Sweep    start: on end (done) of 2

Goblin Swing (double): the three entries of Goblin Swing, then
  4. Turn     start: on end (done) of 3
  5. Windup   start: on end (done) of 4
  6. Sweep    start: on end (done) of 5        values: arc = backswing_arc
```

- **Start rules:**
  - at +N ticks from the ability's start
  - on another entry's start, or its end with the reasons that count (so a cancelled windup doesn't swing), optionally plus a delay
  - when a condition holds
  - the first of several of these
- **End:** the step's own end, or with another entry, or with the ability. The ability ends when no entry that keeps it running is running or due, or at its longest length (today's `max_steps_ticks`).
- **State:** each entry's start and end ticks (-1 if not yet), one packed array per ability. "At +10" is the ability's `started_at` plus 10: a deadline.
- **Order within a tick:** rules are checked in list order. A step that ends can start the next in the same tick; a step started during a tick gets its first tick on the next, as now. The existing guard stops steps starting each other in a loop.
- **The old links** (`starts_first`, `starts_when_finished` on the step nodes) became timeline entries ("at +0", "on end of"), and left the step nodes.

### 6.3 Conditions

Small data Resources over named values, so step timelines stay no-code and C++ can judge them later: the angle to the look or the target, an action held, grounded, a stat compared with a number. The AI's conditions (`AICompareCondition` over `AIInputs`) work the same way; the two may share one base (section 12).

### 6.4 Bespoke scripts

The alternate path: an ability's script sequences its step nodes itself (`run_step(sweep, values)`), for logic a timeline can't express, such as branching on what the swing hit or a swing that homes in. It uses the same steps, state layer and deadlines.

### 6.5 As built (part 3, Claude, 2026-11-22)

- **Classes:** `TimelineEntry` and `AbilityCondition` (`abilities/steps/`); the runner is in `AbilityBase`. The definition's `step_timeline` is a setting like any other, so a variant can have its own.
- **Which timeline:** the definition's; else the kind's default for the steps it made (`default_timeline()`: MeleeAttack's and RangedAttack's standard sequences); else the steps one after another in tree order. A step no entry names gets a manual entry, so code can still start it (`start_step`, the bespoke path of 6.4).
- **Labels:** an entry is found by its label, its step's name unless given one; one step in two entries needs a label on one.
- **No rule set** means it starts with the ability.
- **State:** four numbers per entry in `timeline_state`: start, end, end reason, and where its step's count starts. A step's length is a deadline from that origin; a tick that doesn't count (the windup waiting for the turn) moves the origin on, the only write while it runs. `step_ticks` is worked out from it.
- **Due:** an entry not yet started is due if its tick hasn't come, the entry it follows is still to run or end, or its delay is running. An entry with only a condition isn't, so it can't keep the ability going on its own.
- **Values:** an entry's `values` go onto its step when it starts; the step's own come back when the ability ends, and a rollback puts the running entries' values back.
- **Windup and turn:** the windup no longer starts the turn (the timeline does) and counts while facing the look or while no turn step runs. A recovery and a windup find their sweep from the timeline, for visuals.
- **Conditions** stay separate from the AI's for now: one value (look angle, an action held, grounded, a stat, ticks running) against a number.
- **Measured:** 300 pawns, `pawn.abilities` 0.36 ms a frame and the commit 0.67 to 0.75 ms a tick, as before.

## 7. Swing arcs as keys

A sweep's path is a list of keys: (time from 0 to 1 through the hit window, angle, height, reach), interpolated. Two keys is today's start and end. The hit test already sweeps from one tick's position to the next, so more keys change nothing there. Animation reads the same keys for the weapon's path (`weapon_point`), so what's drawn and what hits can't disagree.

## 8. References become ids

| Today | Becomes |
|---|---|
| `pawns_hit_this_run` (instance ids, not rolled back: a rewind mid-swing could hit a pawn twice) | Fixed slots of entity ids, rolled back, with a cap and a rule when full |
| A projectile's shooter, ability and on-hit effects | The shooter's entity id, the ability's index, effect resource ids |
| `HitInfo`'s attacker and ability | Entity id and ability index (a hit is delivered in the tick it's made, so it's never state between ticks) |

Resource ids come from the registry of definitions and effects (3.1).

## 9. Projectiles

- **A definition:** speed, gravity, radius, range, lifetime, hits the world, model and particles, on-hit effects. The firing ability's definition names it.
- **Flight worked out, not stepped:** a bolt's position at any tick follows from its launch tick, origin, velocity and gravity. Its state is a launch record plus the tick it ended, which doesn't change in flight, so deltas are empty and clients draw the flight themselves; only the launch and the end are sent. The server still sweeps each tick for hits.
- **Hits are queries made in the tick** (the owner, 2026-11-21), as now: a sphere swept along the tick's step against the pawns' capsules, and a ray against the world. Not physics overlap events: those come after the physics step, in the engine's order, only where the area is at that moment (a fast bolt skips past), and only against where pawns are now, so they can't be rewound. If many bolts cost real time, all of them go to C++ in one call per tick, as the crowd mover does.
- **Penetration** (the owner, 2026-11-21): `max_hits` in the definition, 1 by default (stops at the first pawn), 0 for no limit. Within a tick's step the pawns touched are taken in order along the path until the count runs out; the bolt keeps the entity ids of the pawns it hit (section 8), so none is hit twice. Whether walls stop it stays its own setting. Damage falling off per pawn passed is an effect's job.
- **Lag compensation** (the owner, 2026-11-21), by catching up at spawn: the shooter's view delay (`view_ticks_behind`, capped by the session as for melee) is taken when it fires, and the server flies the new bolt forward by that many ticks at once, testing those ticks against pawns rewound to where the shooter saw them (`LagCompensation`, as melee uses); after that it flies normally. So lag bends only the start of a flight, and rewound tests cost a few ticks per bolt. Rewinding for a bolt's whole flight is the alternative: simpler, but targets are hit behind cover for longer.
- **Seen at once by the shooter:** the shooter's client draws a predicted copy of its bolt the moment it fires, a visual with no hits, replaced by the server's bolt when that arrives. Today the shooter sees its own bolt a round trip late.

## 10. Visuals and events

- Visuals follow state where they can: an ability or entry whose `started_at` changes has started. So a replay's playback, which runs no simulation, can drive the same visuals.
- One-tick things that leave no state (a hit landing, damage numbers) stay as events, recorded in the replay.
- To be settled with the visuals review and animation v0.

## 11. What happens to today's code

| File | Change |
|---|---|
| `AbilityBase.gd` | Done: settings in definitions (part 2), timers as deadlines and state pushed (part 1). Part 3: runs the definition's step timeline by default |
| `AbilityManager.gd` | Done (part 1): no countdowns; it keeps the soonest deadline, and readiness is checked against deadlines |
| Each ability kind | Done: settings in its definition, timers as deadlines |
| `MeleeAttackAbility.gd` | Its default steps come from its definition's step timeline; the arc as keys |
| `steps/*` | Done (part 3): values per run, links became timeline entries, the step state is the timeline's |
| `interceptors/*` | To be checked: settings into definitions, the same pattern |
| `projectiles/Projectile.gd` | A definition; flight worked out from the launch record; ids for the shooter and effects |
| `effects/EffectManager.gd` | Its list's countdowns become deadlines |

Refactor rows from the abilities changelog folded in: Death and Knockback found by tag rather than class; the unused `_stepped` list; the test-only `_sweep_centres` helper; hit signals declared once.

**Tests:** the ability, rollback, network and projectile suites check that play is unchanged. New: step timelines (start rules, simultaneous steps, end reasons, loops), definitions (variants, embedded, fallback), and a check that no ability keeps state outside what it declares, as `rollback_coverage_selftest` does for the pawn.

## 12. Open

- **One condition base** for abilities and the AI, or two that look alike.
- **Authoring step timelines:** a list of entries in Godot's inspector works; a timeline editor belongs to the design studio on the roadmap.
- **Interceptors:** settings into definitions, and whether one can be started by a timeline entry.
- **C++ for hot built-ins** (the sweep, the dash): only where the dispatch measurement shows real gains.
