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
 AbilityManager ──► abilities (its children): Walk, Sprint, Jump, Dash, MeleeAttack, Parry, Knockback, Death
                        │
                        ├─► steps (children of an ability): Windup ─► TurnToFace, Sweep ─► OpenCombo, Recovery
                        └─► HitInterceptors (under an ability or a step): Invulnerability, Parry

 a Sweep step's hit ─► HitInfo ─► target's AbilityManager.receive_hit ─► its interceptors ─► its EffectManager (effects/)
```

- **`AbilityManager`** is a part on every pawn, with the abilities as its children. Each tick it runs one locomotion ability, then the actions: a press starts the ready ability on that action with the highest priority. It owns the cancelling rules, the combo counter, and the hit path (`receive_hit`), including death.
- **`AbilityBase`** is one thing a pawn can do. LOCOMOTION moves the pawn every tick (Walk by default, Sprint while held); ACTION starts on a press, at once (Jump) or for a while (Dash, a swing). Its timers roll back.
- **The t0 abilities:** `WalkAbility`, `SprintAbility`, `JumpAbility`, `DashAbility`, `MeleeAttackAbility`, `ParryAbility`, and two with no key: `KnockbackAbility` (on the pawn being hit) and `DeathAbility` (runs while Health is 0).
- **Steps** (`steps/`): an ability can be built from `AbilityStep` children that start each other and run side by side. A swing is Windup (which starts TurnToFace), then Sweep (the hit window), then OpenCombo and Recovery. MeleeAttack makes these from its settings if it has none.
- **Hit interceptors** (`interceptors/`): a `HitInterceptor` under an ability or a step can stop hits while it runs. MISS: the hit never arrives (`InvulnerabilityInterceptor`, a dash's first 0.18 s). TURN_AWAY: the hit arrives, then is stopped (`ParryInterceptor`, hits from the front).
- **`HitInfo`** is one hit: attacker, target, direction, and the effects it carries. What a hit does is the effects system's job ([effects/README.md](../effects/README.md)).
- Tags (`tags/TagRegistry`, `Tags` constants) name ability categories; `controllers/InputActions` turns action names into bits. `abilities/debug/AbilityDebugDraw` draws swing spheres and dash trails for samples and tests.

## How to use it

**Make a new attack from steps.** Add a `MeleeAttackAbility` (or any `AbilityBase`) under the pawn's AbilityManager, set its `trigger_action`, and give it step children: a `WindupStep` (set `turn_step` to a `TurnToFaceStep` and `starts_when_finished` to the sweep), one or more `MeleeSweepStep`s (start and end angle, height and reach), then a `WaitStep` for recovery. Several sweeps in a row make a zig-zag or a spin. Steps with `starts_first` start with the ability; the ability ends when no step is left running. Put an `EffectApplier` (ON_HIT, TARGET) under the ability with the effects a hit applies, such as `resources/effects/swing_hit.tres`.

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

**Write a new ability in code.** Extend `AbilityBase`, set `kind`, `trigger_action`, `category` and the numbers in `_init()`, and override `can_start()`, `start()`, `tick(dt)` or `stop()`. Anything it keeps between ticks goes in `get_rollback_properties()`.

**Hit a pawn from game code** (a trap, say), on the server:
```gdscript
var hit := HitInfo.new()
hit.target = pawn
hit.effects = [Effect.make_damage(20)]
pawn.ability_manager.receive_hit(hit)
```

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

`abilities/tests/`: `ability_selftest` (the manager's rules, Walk, Sprint, Jump, rollback), `ability_steps_selftest` (steps in order and side by side, failing, the safety limit, cancel windows, step rollback), `combat_selftest` (Dash, MeleeAttack, Knockback, the interrupt rules, hits on the server), `fight_selftest` (Health, damage, Death, revive), `attack_request_selftest` (presses as requests, jitter, combos), `attack_feel_selftest` (sweeps, turning, the hop, invulnerability), `hit_interceptor_selftest` (interceptor rules), `parry_selftest` (the parry and the AI's parry). Run them with `bash tools/run_tests.sh <name>`.
