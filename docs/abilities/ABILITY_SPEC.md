# Ability Spec v0.2 (agreed direction, nothing built)

*Written by Claude (claude-opus-5-5), 2026-11-19, from the discussion with the owner the same day.*

**Status:** agreed direction. Abilities v2 are part of the full refactor on its own branch ([STATE_STORE_SPEC.md](../state_store/STATE_STORE_SPEC.md), "How it's built"), written straight against the state store, after the tick driver, the store and the pawn (the owner, 2026-11-19).

**What it changes:** how abilities and their steps are built, so they fit the state store: settings move into shared definitions, timers become tick deadlines, steps are sequenced by no-code chains, and state is read and written through one small layer that the store can later sit behind. The rules players and AI see (actions, priorities, interrupts, combos, buffering, hits) don't change. Today's design is pawn spec 8 (8.20 steps, 8.23 interceptors, 8.24 projectiles).

**Written against the store.** An earlier plan built this first on today's recording; with the rewrite in place, abilities read and write their state in the store from the start.

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
| Sequencing | No-code chains are the typical way; a bespoke script running the same step nodes is the alternate | the owner |
| Chains | A relative tick timeline with start rules, steps able to run at the same time | the owner's idea |
| Extending | New data before new code; a subclass for new logic (a double swing can extend MeleeAttack, or be a longer chain) | the owner and Claude |
| Order | In the full refactor, after the tick driver, the store and the pawn; written straight against the store (2026-11-19, replacing "before the store") | the owner |

## 2. The three layers

| Layer | What it is | Example | Where it lives |
|---|---|---|---|
| Kind | The code: how a melee attack, a dash or a jump works | `MeleeAttackAbility.gd`, `MeleeSweepStep.gd` | The node's script, one copy for every pawn |
| Definition | One variant's values | "Goblin Swing": windup 8 ticks, arc keys, reach 1.8 m, hit radius 0.8 m, on-hit effects | A Resource file the node references, or one embedded in the node |
| State | What one pawn's ability is doing now | ready at tick 4120, chain entry 2 started at tick 4108 | Today the node's rolled-back variables; later the store |

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
- **Checked once, when loaded:** a chain naming a step the ability doesn't have, a bad start rule, a loop.

## 4. State, as tick deadlines

Every timer becomes the tick something happens, not a count of ticks left. The value doesn't change while the timer runs, so there's no per-tick countdown (the ability manager's `_timed` list and its dirty flags go), deltas are empty, rollback restores less, and a pawn running every Nth tick needs nothing special: it checks `tick >= deadline` on its next run.

| Today (counts down) | Becomes |
|---|---|
| `AbilityBase.ticks_left` | `started_at` (with the duration in the definition), or the chain's state |
| `cooldown_ticks_left` | `ready_at` |
| `buffer_ticks_left` | `buffer_until` |
| `AbilityManager.combo_window_ticks_left` | `combo_open_until` |
| `step_state` (running, step ticks) | each chain entry's `started_at` and `ended_at` (section 6) |
| `JumpAbility.ticks_off_ground` | `left_ground_at` |
| `KnockbackAbility.push_ticks` | `push_until` |
| An effect's ticks left and period left | `ends_at` and `next_pulse_at` |
| A projectile's ticks left and distance travelled | its launch tick (section 9) |

Values that aren't timers stay as they are: Dash's direction, Knockback's push velocity, the combo position.

**Re-basing:** when a timer's rate changes (a haste effect on cooldowns) or it pauses (a freeze), the remaining time is worked out and a new deadline set. Sleeping is an optimisation and must not change results, so deadlines keep running while a pawn sleeps; Death's current "its timer waits with the pawn" is checked against this (section 12).

## 5. Reading and writing state: the layer the store sits behind

Ability and step code never touches its state variables directly. It goes through a few calls on `AbilityBase` and `AbilityStep`:

```gdscript
func declare_state(layout) -> void:            # once, before the first recorded tick: what this ability keeps
	_ready_at = layout.add_column(self, &"ready_at", TYPE_INT)
func state_int(column: int) -> int             # read
func write_int(column: int, value: int) -> void # write
```

- **Backed by the store's columns** (and its GDScript twin). Ability code never holds its state in its own variables.
- **Cost:** a read through the store is a call into C++, a little more than a member variable. If the dispatch measurement says it matters, an ability reads its columns once at the start of its tick and writes them back at the end.

## 6. Steps and chains

### 6.1 Steps

- **Thin child nodes** of the ability: windup, turn, sweep, wait, fire a projectile, apply an effect, open the combo window. Each kind's code is shared.
- **Building blocks:** the ability declares the steps it uses by having them as children. A step node can run several times in one ability, with different values each time (a second sweep on a backswing arc).
- **Values per run** come from the chain entry (or the bespoke script), falling back to the step's own.
- **A step decides its own end:** its length, or its condition. It ends with a reason: done, released, failed or cancelled.
- **Steps can run at the same time** (a turn alongside a windup). The ability's interrupt threshold is the strictest of its running steps', as now; a step can go along without holding the ability open (`keeps_ability_running`, as now).

### 6.2 No-code chains

The typical way to sequence steps. The definition holds a chain: a list of entries, each naming a step node, the values it runs with, and a **start rule**. Ticks are relative to the ability's start.

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
- **State:** each entry's `started_at` and `ended_at` (-1 if not yet), one packed array per ability, as `step_state` is now. "At +10" is the ability's `started_at` plus 10: a deadline.
- **Order within a tick:** rules are checked in list order. A step that ends can start the next in the same tick; a step started during a tick gets its first tick on the next, as now. The existing guard stops steps starting each other in a loop.
- **Today's links** (`starts_first`, `starts_when_finished` on the step nodes) become chain entries ("at +0", "on end of"), and leave the step nodes.

### 6.3 Conditions

Small data Resources over named values, so chains stay no-code and C++ can judge them later: the angle to the look or the target, an action held, grounded, a stat compared with a number. The AI's conditions (`AICompareCondition` over `AIInputs`) work the same way; the two may share one base (section 12).

### 6.4 Bespoke scripts

The alternate path: an ability's script sequences its step nodes itself (`run_step(sweep, values)`), for logic a chain can't express, such as branching on what the swing hit or a swing that homes in. It uses the same steps, state layer and deadlines.

## 7. Swing arcs as keys

A sweep's path is a list of keys: (time from 0 to 1 through the hit window, angle, height, reach), interpolated. Two keys is today's start and end. The hit test already sweeps from one tick's position to the next, so more keys change nothing there. Animation reads the same keys for the weapon's path (`weapon_point`), so what's drawn and what hits can't disagree.

## 8. References become ids

| Today | Becomes |
|---|---|
| `pawns_hit_this_run` (instance ids, not rolled back: a rewind mid-swing could hit a pawn twice) | Fixed slots of entity ids, rolled back, with a cap and a rule when full |
| A projectile's shooter, ability and on-hit effects | The shooter's entity id, the ability's index, effect resource ids |
| `HitInfo`'s attacker and ability | Entity id and ability index (a hit is delivered in the tick it's made, so it's never state between ticks) |

Resource ids come from a registry of definitions and effects, the same on every machine (part of the join check).

## 9. Projectiles

- **A definition:** speed, gravity, radius, range, lifetime, hits the world, model and particles, on-hit effects. The firing ability's definition names it.
- **Flight worked out, not stepped:** a bolt's position at any tick follows from its launch tick, origin, velocity and gravity. Its state is a launch record plus the tick it ended, which doesn't change in flight, so deltas are empty and clients draw the flight themselves; only the launch and the end are sent. The server still sweeps each tick for hits.

## 10. Visuals and events

- Visuals follow state where they can: an ability or entry whose `started_at` changes has started. So a replay's playback, which runs no simulation, can drive the same visuals.
- One-tick things that leave no state (a hit landing, damage numbers) stay as events, recorded in the replay.
- To be settled with the visuals review and animation v0.

## 11. What happens to today's code

| File | Change |
|---|---|
| `AbilityBase.gd` | Settings move to `AbilityDefinition`; timers become deadlines; the state layer (5); runs the definition's chain by default |
| `AbilityManager.gd` | No per-tick countdowns (`_timed`, timer dirty flags); combo window as a deadline; readiness checked against deadlines |
| Each ability kind | Its settings move to its definition; its timers become deadlines |
| `MeleeAttackAbility.gd` | Its default steps come from its definition's chain; the arc as keys |
| `steps/*` | Values per run; links move to chain entries; the step state moves into the chain's state |
| `interceptors/*` | To be checked: settings into definitions, the same pattern |
| `projectiles/Projectile.gd` | A definition; flight worked out from the launch record; ids for the shooter and effects |
| `effects/EffectManager.gd` | Its list's countdowns become deadlines |

Refactor rows from the abilities changelog folded in: Death and Knockback found by tag rather than class; the unused `_stepped` list; the test-only `_sweep_centres` helper; hit signals declared once.

**Tests:** the ability, rollback, network and projectile suites check that play is unchanged. New: chains (start rules, simultaneous steps, end reasons, loops), definitions (variants, embedded, fallback), and a check that no ability keeps state outside what it declares, as `rollback_coverage_selftest` does for the pawn.

## 12. Open

- **Sleeping and Death:** deadlines keep running while a pawn sleeps; Death's timer "waits with the pawn" today. Check what Death's timer is for and keep its behaviour.
- **One condition base** for abilities and the AI, or two that look alike.
- **The registry** that gives definitions and effects their ids, and how it's built (scanned folders, or a list).
- **Authoring chains:** a list of entries in Godot's inspector works; a timeline editor belongs to the design studio on the roadmap.
- **Locomotion** (Walk, Sprint): whether they have chains at all, or stay code with a definition.
- **Interceptors:** settings into definitions, and whether one can be started by a chain entry.
- **C++ for hot built-ins** (the sweep, the dash): only where the dispatch measurement shows real gains.
