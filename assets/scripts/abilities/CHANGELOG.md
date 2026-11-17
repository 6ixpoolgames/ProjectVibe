<!-- Written by Claude (claude-opus-5-5), 2026-11-17: the abilities system's running changelog (the owner's call: history leaves the
code comments and lives here, next to the code). Newest first. Add an entry with every change; code comments say what the code does
now, this says how it got here and why. -->

# Abilities changelog

Abilities are this folder: `AbilityManager` and `AbilityBase`, the t0 abilities (Walk, Sprint, Jump, Dash, MeleeAttack, Knockback, Death, Parry), `HitInfo`, ability steps (`steps/`) and hit interceptors (`interceptors/`). What a hit or an ability does to a pawn is the effects system (`effects/`, its own changelog). Design: [docs/pawn/PAWN_SPEC.md](../../../docs/pawn/PAWN_SPEC.md), section 8 (8.3 to 8.6, 8.8 to 8.10, 8.15, 8.16, 8.20 to 8.23) and section 15. Overview: [README.md](README.md).

## Refactor candidates

Code that works but doesn't yet fit the project's goals (reusable, extensible, efficient, designer friendly). Each is marked `REFACTOR:` in the code. Sizes are rough: S an hour or two, M a day, L more.

| What | Where | Why | Size |
|---|---|---|---|
| Hit signals declared once | `steps/MeleeSweepStep.gd` (`has_signal`, `emit_signal` by name), `MeleeAttackAbility`'s three signals | The sweep sends `hit_landed`, `hit_window_started` and `hit_area_moved` by name on its ability, so a new attack ability only gets them by copying the three declarations. Declared once (on `AbilityBase`, or on the step) a new attack works without that | S |
| Death and Knockback found by tag | `AbilityManager._collect_abilities` (`_death`, `_knockback`) | Found by class, so a game changes dying or staggering only by extending `DeathAbility` or `KnockbackAbility`. A tag (`status.dead`, `combat.knockback`) would let any ability fill the role | S |
| An unused list | `AbilityManager._stepped` | Filled when abilities are collected, never read | S |
| A test-only helper | `MeleeAttackAbility._sweep_centres` | Only `visuals/tests/visuals_selftest` calls it; the test can ask the sweep step (`centres_for_tick`) itself, keeping test helpers out of production code | S |

The parry the owner flagged as hacky (pawn spec 14, "Shortcuts to redo") was redone as hit interceptors on 2026-11-17, and nothing parry-specific is left in the manager or the base: `ParryAbility` is a plain timed ability that makes a default `ParryInterceptor`, and `guard()` is only read by the debug drawing and tests.

## 2026-11-17

- **Hit interceptors** (pawn spec 8.23, the owner's call: "leave space for stats and proceed as proposed"). `HitInterceptor`, a node under an ability or one of its steps, can stop a hit while its parent runs: MISS (`InvulnerabilityInterceptor`, the hit never arrives) or TURN_AWAY (`ParryInterceptor`, hits from the front; the hit arrives, then `intercept()` decides). The first active one that stops a hit ends it, `AbilityManager.hit_intercepted` goes out, and its `ON_INTERCEPT` effects go back to the attacker in a hit marked `HitInfo.from_interception`, which can't be turned away. Dash and Parry make a default interceptor when they have none (`make_default_interceptors`). This replaced the special cases: `AbilityBase.invulnerable_while_running`, `invulnerable_seconds`, `on_parry_effects`, `on_parry_self_effects`, `has_invulnerable_step()`; `AbilityStep.invulnerable`; `AbilityManager.parry_hit()` and its parry and invulnerable lists; `ParryAbility.try_parry()`, `faces()`, `front_degrees` and the `parried` signal. `EffectApplier.ON_PARRY` became `ON_INTERCEPT` with the same saved number.
- **Swing hits in C++.** When nothing would be rewound (AI swings, offline play), `MeleeSweepStep` asks the pawn grid (`AIPawnGrid.find_touching`) who its spheres touch, instead of a physics query per spot. Same answer; physics without the C++ library, lag compensation when it rewinds.
- **One Health stat** (the owner's call). `DeathAbility.health_stat` went: Death watches `StatManager.HEALTH`, as hits and the EffectManager's death check do, so the two can't disagree.
- **The AI through its core.** A swing's warning goes to the target's `ai_context.note_incoming_attack`.
- **Comments cleaned up** for the documentation pass: dated notes moved here, doc comments in Godot's markup. Stale comments fixed: MeleeAttack's header (hits are its sweep step's, Dash's priority is 40, its turning is the TurnToFace step's), Knockback's and Parry's interrupt numbers against Dash (its threshold is 25, its priority 40), what starts Knockback (a KnockbackPart's `push`) and Death (`AbilityManager.health_ran_out`), which abilities override `duration_ticks` (Dash, Knockback, Death; not MeleeAttack), the interrupt numbers' list, `hit_arrived` (before an interceptor, not "a parry"), `step_finished`'s reasons ("released" too) and the hit order in `receive_hit`.

## 2026-11-16

- **Ability steps** (pawn spec 8.20, agreed with the owner over several rounds). An ability can be built from `AbilityStep` children that start each other (`starts_first`, `starts_when_finished`, `start_step()`), run side by side, give cancel windows (a step's `interrupt_threshold`) and end the ability when none that keeps it running is left (`keeps_ability_running`, `max_steps_ticks` as a safety). A step started during a tick gets its first tick on the next. Steps: `WindupStep`, `TurnToFaceStep`, `MeleeSweepStep`, `WaitStep`, `OpenComboStep`, `ApplyEffectStep`. `step_started` and `step_finished` signals; the replay records each step.
- **MeleeAttack built from steps.** Its hit checks moved into `MeleeSweepStep`; with no steps of its own it makes Windup, TurnToFace, Sweep, OpenCombo and Recovery from its settings, so every swing in every scene became a stepped one with the same numbers. Its `duration_ticks`, `tick` and rollback list went; `_hit_this_swing` became `AbilityBase.pawns_hit_this_run`.
- **Holding** (the owner's call: the base's, not one step's). A step with `ends_when_released` ends with "released" on the first tick its action isn't held (`while_held`, or the ability's trigger action), from rolled-back input. The turn follows the look only while the attack is held, and turns at least `min_turn_degrees` first however short the press. The windup's timer waits until the pawn is within 90 degrees of the look. `windup_turn_degrees_per_second` defaults to -1: the pawn's TurnRate stat.
- **Combos by position.** `combo_positions` on each ability and one counter on the manager (`combo_position`, `combo_window_ticks_left`, both rolled back); `OpenComboStep` opens the window after a hit.
- **Step state as one value.** Every step's `running` and `step_ticks` live in its ability's `step_state`, recorded as one value: two values per step cost 2.4 ms a tick at 150 pawns. A safeguard stops steps that start each other in a loop (`MAX_STEP_STARTS_PER_TICK`, 32).
- **Pawns that run every 2nd or 4th tick** (pawn spec 8.21): timers, step counts, Jump's time off the ground and Death's hold advance by `ticks_elapsed`; a sweep covers every tick its run covers (`centres_for_ticks`).
- **`needs_full_movement`** (pawn spec 8.22): Dash and Knockback move by physics, not the crowd mover.
- **Hits and death on the AbilityManager** (pawn M3, pawn spec 8.16). `receive_hit`, the hit queue, `is_invulnerable`, `health_ran_out`, `revive` and the `hit_arrived`, `hit_received` and `died` signals moved here from `Pawn`. Each part cleans up after a death by listening to `died`.
- **Input on the ControllerManager** (pawn M4): abilities read it through `move_input()`, `look_yaw()`, `held_actions()` and the rest, which answer "nothing pressed" without one.
- **From the wider code audit.** `start_ability` on a running ability ends its run properly first (it sent `ability_started` twice with no finish between, and never restarted its steps), and if it may not restart the run carries on. An ability started by an earlier ability's press in the same pass no longer gets an extra tick (`_started_later`). A running ability keeps the pawn awake unless it says it can wait (`can_sleep_while_running`), so a corpse sleeps. `get_knockback()` is found once; `is_action_running()` asks only running timers. `run_steps` and the sweep's physics query reuse their objects, and the sweep leaves at once in a replay.

## 2026-11-15

- **Parry** (pawn spec 8.15, the owner's request): `ParryAbility`, turning hits from the front away and pushing the attacker back with its ON_PARRY effects (flagged by the owner as hacky; redone on 2026-11-17). `MeleeAttackAbility.warns_targets` tells enemies a swing is coming, so their AI can parry.

## 2026-11-12

- **Swings rise and fall** (pawn spec 8.12): `height_at_sweep_start` and `_end` for slashes and chops, and `hit_offset_at` so the floating sword draws exactly the spots the hit checks; `windup_length()` and `hit_length()` for visuals.
- **No snap to the look** (the owner's request): an attack turns only during its windup, at its turn speed, so a turn speed limits every attack.

## 2026-11-10

- **Effects replace numbers** (pawn spec 8.11, the owner's design). `HitInfo` carries `effects` and `attacker_effects` instead of `damage`, `knockback_speed`, `knockback_ticks` and `knockback_hop`, and gained `damage_dealt` and `planned_damage()`. An ability's `EffectApplier` children are collected once (`on_start_effects`, `on_hit_effects`, `on_hit_self_effects`); on-start effects apply on every machine. Effects can add to priority and interrupt numbers while they last (`press_priority_now`, `interrupt_priority_now`, `interrupt_threshold_now`), which is how combos worked: `FollowUpAttackAbility` went, replaced by boosts, and a buffered press lets every ready ability on its action compete.
- **Tags** (pawn spec 8.10): abilities set their categories from `Tags` constants; `extra_categories` (groups such as `movement.basic`, `movement.advanced`); `action_for_tag` for the AI; `cancelled_by` for exceptions to the numbers; `get_interrupt_table()` and `interrupt_rule()` share one rule with starting.
- **Dash reworked** (the owner's design, pawn spec 8.9): two phases by acceleration (100 m/s² for 0.1 s, then 50 for 0.2 s, never backwards) instead of a flat 18 m/s for 0.15 s with the speed cut after; cooldown 2 s (was 1); interrupt priority 40 (was 20), the one thing that cancels a knockback; threshold 25 (40 for a few hours) so a knockback cancels it once its invulnerability is over; invulnerable while it ran; usable in the air; `pauses_locomotion` so Walk doesn't fight it.
- **Knockback:** a small hop back (the owner's request), and threshold 35, so only Dash cancels it.
- **Game feel for swings:** the hit sphere sweeps across an arc (`sweep_degrees`, `sweep_from_left`), checking every spot it passes through in one lag compensation rewind; it turns during the windup; `hit_area_moved` for debug drawing.

## 2026-11-09

- **Dash, MeleeAttack, Knockback and cancelling** (pawn step 9, spec 8.6): `interrupt_priority` and `interrupt_threshold`, cancelling what an ability conflicts with, `start_ability` for abilities with no trigger action, `ability_cancelled`; melee hits on the server through lag compensation.
- **Health, damage and death** (step 10, spec 8.7): `DeathAbility` (death as an ability, the owner's call), damage on hits.
- **Presses as requests** (spec 8.8): the highest priority wins (it was the lowest), with optional `priority_jitter` from the tick's own random numbers.
- **Tick foundations** (spec 15): timers tell the manager when they start or stop so only running ones count down, input as bits, `every_tick()` only where overridden, the action step only with something to do (15.2); `can_sleep` for resting pawns (15.3); hits delivered after every pawn has simulated (15.4); `Pawn.dead` kept current by Death for C++ readers (scaling spec step 4); Walk reads its stats only when they change.

## 2026-11-07 to 2026-11-08

- **Abilities** (pawn steps 5 and 6, spec 8.3 to 8.5): `AbilityBase`, `AbilityManager`, `WalkAbility`, `SprintAbility` and `JumpAbility`, replacing the old `GroundMovement`'s steering and jump. Pressed by named actions, locomotion and actions, lockouts by tag, timers that roll back.
