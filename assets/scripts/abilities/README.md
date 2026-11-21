<!-- Written by Claude (claude-opus-5-5), 2026-11-17: the abilities system's overview, beside its code. -->

# Abilities

Everything a pawn does, from walking to a three-hit combo: abilities started by named actions (the same for a player's keys and the AI), the rules for what cancels what, attacks built from steps, and the hits that land on a pawn.

**Status:** built, tier 0. Not yet: attacks that move while they swing (`moving_attack`), interceptors switched on by state tags with no ability running, and a stats pass for the numbers.

| File | What it's for |
|---|---|
| [README.md](README.md) | This overview: what's here and how to use it |
| [REFERENCE.md](REFERENCE.md) | Every class, setting and function, generated from the code's doc comments (`python tools/docs/make_reference.py abilities`) |
| [CHANGELOG.md](CHANGELOG.md) | What changed and why, newest first, and the refactor candidates |
| [PAWN_SPEC.md](../../../docs/pawn/PAWN_SPEC.md) | The design: section 8 (abilities 8.3 to 8.6, attack requests 8.8, tags 8.10, parry 8.15, hits and death 8.16, steps 8.20, interceptors 8.23) and section 15 (tick rules) |

## The pieces

```
 player keys / AI ─► ControllerManager (held actions, move, look)
                              │ read every tick
                              ▼
 AbilityManager ──► abilities (its children): Walk, Sprint, Jump, Dash, MeleeAttack, RangedAttack, Parry, Knockback, Death
                        │
                        ├─► steps (children of an ability): Windup ─► TurnToFace, Sweep ─► OpenCombo, Recovery
                        │                                    or Windup ─► TurnToFace, Fire ─► Recovery
                        └─► HitInterceptors (under an ability or a step): Invulnerability, Parry

 a Sweep step's hit ─┐
 a Fire step ─► Projectile (a networked entity, flown by the server) ─┴─► HitInfo ─► target's AbilityManager.receive_hit
                                                                           ─► its interceptors ─► its EffectManager (effects/)
```

- **`AbilityManager`** is a part on every pawn, with the abilities as its children. Each tick it runs one locomotion ability, then the actions: a press starts the ready ability on that action with the highest priority. It owns the cancelling rules, the combo counter, and the hit path (`receive_hit`), including death.
- **`AbilityBase`** is one thing a pawn can do. LOCOMOTION moves the pawn every tick (Walk by default, Sprint while held and it has charge: it drains while sprinting and refills at half rate a second after it stops); ACTION starts on a press, at once (Jump) or for a while (Dash, a swing). Its timers roll back.
- **The t0 abilities:** `WalkAbility`, `SprintAbility`, `JumpAbility`, `DashAbility`, `MeleeAttackAbility`, `RangedAttackAbility`, `ParryAbility`, and two with no key: `KnockbackAbility` (on the pawn being hit) and `DeathAbility` (runs while Health is 0).
- **Steps** (`steps/`): an ability can be built from `AbilityStep` children that start each other and run side by side. A swing is Windup (which starts TurnToFace), then Sweep (the hit window), then OpenCombo and Recovery. MeleeAttack makes these from its settings if it has none.
- **Projectiles** (`projectiles/`): a `Projectile` is a networked entity, one per shot, spawned by a `FireProjectileStep`. The server (or the offline game) moves it each tick and hits the first pawn or wall in its path; clients draw it from snapshots. Its hit carries the firing ability's on-hit effects. Design: pawn spec 8.24.
- **Hit interceptors** (`interceptors/`): a `HitInterceptor` under an ability or a step can stop hits while it runs. MISS: the hit never arrives (`InvulnerabilityInterceptor`, a dash's first 0.18 s). TURN_AWAY: the hit arrives, then is stopped (`ParryInterceptor`, hits from the front).
- **`HitInfo`** is one hit: attacker, target, direction, and the effects it carries. What a hit does is the effects system's job ([effects/README.md](../effects/README.md)).
- Tags (`tags/TagRegistry`, `Tags` constants) name ability categories; `controllers/InputActions` turns action names into bits. `abilities/debug/AbilityDebugDraw` draws swing spheres and dash trails for samples and tests.

## How to use it

**Make a new attack from steps.** Add a `MeleeAttackAbility` (or any `AbilityBase`) under the pawn's AbilityManager, set its `trigger_action`, and give it step children: a `WindupStep` (set `turn_step` to a `TurnToFaceStep` and `starts_when_finished` to the sweep), one or more `MeleeSweepStep`s (start and end angle, height and reach), then a `WaitStep` for recovery. Several sweeps in a row make a zig-zag or a spin. Steps with `starts_first` start with the ability; the ability ends when no step is left running. Put an `EffectApplier` (ON_HIT, TARGET) under the ability with the effects a hit applies, such as `resources/effects/swing_hit.tres`.

**Make a ranged attack.** Add a `RangedAttackAbility` under the AbilityManager, set its `trigger_action` and `projectile_scene` (such as `scenes/projectiles/bolt.tscn`: a `Projectile` with a `TickStateComponent` recording position and velocity, and a `NetworkEntity`), and put an `EffectApplier` (ON_HIT, TARGET) under it, such as `resources/effects/bolt_hit.tres`. Register the projectile scene on every machine at startup, before hosting or joining: `Projectile.register_scene(scene)` (the type list is part of the join check). For the AI, give its brain an `AIAttackBehaviour` with `presses_action` set to the same action; it shoots from within the ability's `attack_range`. A volley is several `FireProjectileStep`s in a row.

**Give a step its own rules.** A step's `interrupt_threshold` makes a cancel window (low during recovery, say); `ends_when_released` ends it when the key is let go. An `ApplyEffectStep` applies effects to the pawn at a moment in the ability.

**Make a combo.** Set `combo_positions` on each attack: `[1]` for an opener, `[2]` for a second hit, `[2, 3]` for one that fits either. Put an `OpenComboStep` after the hit, and give follow-ups a higher `priority` than the opener on the same key, so they win while the window is open.

**Make a parry, a block or i-frames.** Add a `ParryInterceptor` or an `InvulnerabilityInterceptor` under the ability (on while it runs) or under a step (on while that step runs); `active_seconds` limits it to the start. Under a parry, an `EffectApplier` with `ON_INTERCEPT` says what the attacker gets (`parry_knockback.tres`). A Dash or a Parry with none makes its default.

**Decide what cancels what.** Two abilities conflict when either one's `locks_out` covers the other's category. The starting one cancels the running one if its `interrupt_priority` is at least the running one's `interrupt_threshold`; `cancelled_by` lists exceptions. `pawn.ability_manager.get_interrupt_table_text()` prints the result for a pawn.

**Press an ability from the AI.** The AI presses actions like a player. To ask for a kind of ability rather than one by name:
```gdscript
var action := pawn.ability_manager.action_for_tag(Tags.MOVEMENT_ADVANCED) # a dash, a grappling hook...
if action != &"":
    pass # hold or press it through the AIController
```

**Write a new ability in code.** Extend `AbilityBase`, set `kind`, `trigger_action`, `category` and the numbers in `_init()`, and override `can_start()`, `start()`, `tick(dt)` or `stop()`. Anything it keeps between ticks goes in `get_pushed_properties()`, with a setter that calls `push_state` (the cheap way), or in `get_rollback_properties()` (read at every commit, no setter needed). Timers are tick deadlines: store the tick something happens, and compare with `TickDriver.tick`.

**Hit a pawn from game code** (a trap, say), on the server:
```gdscript
var hit := HitInfo.new()
hit.target = pawn
hit.effects = [Effect.make_damage(20)]
pawn.ability_manager.receive_hit(hit)
```

## How it works

**A tick.** The pawn calls `AbilityManager.tick_abilities` after its input arrives and before `move_and_slide`. In order: (1) deadlines: if a cooldown, a waiting press or the combo window ended since the last look, `readiness_version` moves on, and `every_tick()` runs on abilities that override it; (2) locomotion: exactly one runs, a held-action one that can run (Sprint) by priority, else the default (Walk); (3) actions: running timed ones tick and run their steps, then a pressed action starts the ready ability on it with the highest priority (plus `priority_jitter` and what effects add), else the first in the tree. A press that can't start yet waits for its `buffer_window`, and when the wait ends every ready ability on that action competes. Each step only does work that has a reason to run (pawn spec 15.2), and only one ability starts per press. A pawn without a `TickStateComponent` works, but nothing rolls back.

**Lockouts and cancelling** (pawn spec 8.6). While an ability runs, the categories in its `locks_out` can't start, and a locked-out locomotion stops steering. Categories are tags, so locking `&"movement"` also locks `&"movement.jump"`. Two abilities conflict when either one's `locks_out` covers the other's category; a conflicting ability starts only if its `interrupt_priority` is at least the `interrupt_threshold` of every conflicting ability running, and those are cancelled (their cooldowns start and `ability_cancelled` goes out). `cancelled_by` lists exceptions. `pauses_locomotion` (Dash) stops Walk running at all, so the two don't fight. The rules live in the manager, not the controllers, so a player and the AI cancel the same way and a rollback replays the same cancels. Effects on the pawn add to priority, interrupt priority and threshold while they last (`AbilityPriorityPart`, pawn spec 8.11).

**Steps** (pawn spec 8.20, the Unreal ability-task model). Steps marked `starts_first` start with the ability (else the first step); a step that finishes starts those in its `starts_when_finished`; a step's own code can start or stop others (`start_step`, `stop_step`). Several run at once. The ability ends when no step with `keeps_ability_running` is left; a step that fails ends it, and the rest get `exit("failed")`. A step started during a tick enters at once and ticks from the next one, so hand-overs have no gap and tree order doesn't matter. At most 32 steps start per tick (a guard against steps that start and stop each other). With `ends_when_released` a step ends on the first tick its action isn't held, with the reason `"released"`; held input is rolled-back input, so server, prediction and replay agree. A new step overrides `enter()`, `tick()` (RUNNING, DONE, FAILED) and `exit(reason)`; `counts_this_tick()`, `setup()`, `can_end_on_release()` and `weapon_point()` are optional.

**Rollback.** What an ability keeps between ticks is registered by the manager with the pawn's `TickStateComponent`: pushed (`get_pushed_properties()`, recorded in the state store when the setter calls `push_state`, never read at the commit) or read at every commit (`get_rollback_properties()`). The base pushes its own timers and, with steps, one `step_state` array (a value per step cost 2.4 ms a tick at 150 pawns; steps write it through `set_step_value`). The combo counter rolls back too. A rollback restores values without calling `enter()` or `exit()` again.

**Timers are tick deadlines** (ability spec 4): a run's `started_at` and `ends_at`, `ready_at` for the cooldown, `buffer_until` for a waiting press, the manager's `combo_open_until`. They don't change while they run, so nothing counts down or is sent, and a pawn running every Nth tick just compares with the tick on its next run. `ticks_left()`, `cooldown_ticks_left()`, `buffer_ticks_left()` and `combo_window_ticks_left()` work out what's left, for readouts. Times are set in seconds and kept in ticks (`ticks_for`, 60 a second).

**Swing hits.** A `MeleeSweepStep` checks every spot its sphere passes through each tick, no more than half the radius apart, so a fast sweep or a 30 Hz match leaves no gaps. In a session it checks through lag compensation (against where the player saw others); when nothing would be rewound (AI swings, offline play) through the C++ pawn grid; without the C++ library, through physics. Each pawn is hit once per ability run, an invulnerable pawn isn't hit or marked (a later tick can catch it), and nothing is decided in a rollback replay. `TurnToFaceStep` turns toward the look only while the attack's action is held and at least `min_turn_degrees` first; the windup's timer waits until the pawn is within 90 degrees of the look.

**Hits.** `receive_hit` runs on the server. During simulate a hit is queued and delivered after every pawn has simulated, sorted by the attacker's entity id, then the target's, then queue order, so the result never depends on who simulated first (pawn spec 15.4). Delivery: a dead or invulnerable pawn ignores it; `hit_arrived` goes out (the AI notes it); an active TURN_AWAY interceptor, highest `priority` first, may stop it and its response goes out instead; otherwise the `EffectManager` applies the hit's effects (damage, knockback, threat) and `hit_received` goes out and the attacker gets its `attacker_effects`. At 0 Health the Death ability starts and `died` goes out.

**Dash numbers.** It adds 100 m/s^2 for 0.1 s (+10 m/s), then takes 50 m/s^2 off for 0.2 s, never below 0 along the dash. Left alone the pawn ends at its starting speed: standing it peaks at 10 m/s over about 1.5 m, walking about 15 m/s and 3 m, sprinting about 19 m/s and 4.2 m.

**What the manager does in odd cases** (checked in `tests/ability_selftest.gd`): a parent that isn't a `Pawn` warns and does nothing; with no default locomotion nothing steers and the pawn keeps its velocity; two abilities on one action start one per press and drop the others' waiting presses.

## Settings worth knowing

| Setting | Where | Default | What it does |
|---|---|---|---|
| `trigger_action` | `AbilityBase` | per ability | The named action that starts it; empty for Walk, Knockback, Death |
| `priority` | `AbilityBase` | 0 | Which ability a press picks among those on one action (higher wins) |
| `interrupt_priority` / `interrupt_threshold` | `AbilityBase` | 0 / 100 | How hard it cancels others; how hard it is to cancel. Walk 0, Jump 5, Sprint 10, swing 15, Knockback 30 (35), Dash 40 (25) |
| `locks_out`, `cancelled_by` | `AbilityBase` | empty | Categories it stops while running; categories that can always cancel it |
| `cooldown`, `buffer_window` | `AbilityBase` | 0 | Seconds before it can start again; seconds an early press waits |
| `combo_positions` | `AbilityBase` | empty | Which combo positions it can fill |
| `windup_ticks`, `hit_ticks`, `recovery_ticks` | `MeleeAttackAbility` | 8, 4, 12 | The default swing's timing, at 60 ticks a second |
| `attack_range`, `hit_radius`, `sweep_degrees` | `MeleeAttackAbility` | 1.8 m, 0.8 m, 100° | The default swing's reach and arc; attack_range is also the AI's reach |
| `active_seconds` | `HitInterceptor` | 0 (whole run) | How long it's on from the start |
| `front_degrees` | `ParryInterceptor` | 120° | How wide the parried front is |

## Tests

`abilities/tests/`: `ability_selftest` (the manager's rules, Walk, Sprint, Jump, rollback), `ability_steps_selftest` (steps in order and side by side, failing, the safety limit, cancel windows, step rollback), `combat_selftest` (Dash, MeleeAttack, Knockback, the interrupt rules, hits on the server), `fight_selftest` (Health, damage, Death, revive), `attack_request_selftest` (presses as requests, jitter, combos), `attack_feel_selftest` (sweeps, turning, the hop, invulnerability), `hit_interceptor_selftest` (interceptor rules), `parry_selftest` (the parry and the AI's parry), `projectile_selftest` (bolts offline: hits, misses, walls, teams, parry, dash, gravity, an AI shooting, an AI keeping its distance and switching to melee up close), and `net_projectile_selftest` (bolts between processes at several network conditions, hits once on the server, hit rollback; about a minute, run by name or with `full net`). Run them with `bash tools/run_tests.sh <name>`.
