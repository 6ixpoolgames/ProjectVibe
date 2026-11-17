<!-- Written by Claude (claude-opus-5-5), 2026-11-17: the effects system's running changelog (the owner's call: history leaves the
code comments and lives here, next to the code). Newest first. Add an entry with every change; code comments say what the code does
now, this says how it got here and why. -->

# Effects changelog

Effects are this folder: `Effect` and its parts (`parts/`), `EffectApplier`, `EffectManager`, `EffectApplication`, `EffectHeldTotals` and `EffectTags`. They're what abilities and hits do to pawns; the abilities that apply them have their own changelog (`abilities/`). Design: [docs/pawn/PAWN_SPEC.md](../../../docs/pawn/PAWN_SPEC.md), section 8.11. Overview: [README.md](README.md).

## Refactor candidates

Code that works but doesn't yet fit the project's goals (reusable, extensible, efficient, designer friendly). Each is marked `REFACTOR:` in the code. Sizes are rough: S an hour or two, M a day, L more.

| What | Where | Why | Size |
|---|---|---|---|
| Threat through a signal | `EffectManager._run_once` | Effects write threat straight into the AI's memory, so this system knows the AI. A signal for Health taken, which the AI listens to (as it does to `hit_arrived`), keeps effects usable without the AI and open to other listeners (UI, scoring) | S |
| One tag-set class for abilities, nav and effects | `EffectTags`, `tags/TagRegistry`, `navigation/NavTags` | The third copy of the same tag rules, kept apart so working code didn't change. One class used three times cuts the code and the tests to one, and a game's own tag set would come free. The same row is in navigation's changelog | M |

## 2026-11-18

- **Comments rewritten to the reference style** (the documentation pass): shorter class and member comments, teaching notes removed; the long class explanations (applying order, the tick, the active list's layout, resistance counting, tag rules, the odd-case lists) moved to the README's new "How it works" section. `EffectApplier`'s triggers and `AbilityPriorityPart`'s numbers are now documented on their enums. No stale comments were found.

## 2026-11-17

- **The AbilityManager hears when effects change** (scaling spec 6.2, step 5b): working out the held totals again calls `AbilityManager.readiness_changed()`, since a priority boost can change what may start, which the AI keeps rather than asking at every decision.
- **`ON_INTERCEPT`** (pawn spec 8.23): `EffectApplier`'s parry trigger became the hit interceptors' trigger, keeping its saved number (2) so saved scenes work. Under a `HitInterceptor`, TARGET effects go to the attacker in a hit of their own, SELF effects on the pawn that stopped the hit.
- `EffectManager.take_hit` reads Health through its own `_health()`, which answers 0 for a pawn without stats; threat goes through the AI's core (`pawn.ai_context.memory`).
- **Comments cleaned up** for the documentation pass: dated notes moved here, doc comments in Godot's markup. Stale comments fixed: dying and death (`AbilityManager.health_ran_out` and `died`, no longer `Pawn`'s), `EffectApplier`'s triggers (three, and on-hit comes from a `MeleeSweepStep`), and `KnockbackPart`'s note on Dash (a knockback cancels a Dash once its invulnerability is over: its threshold is 25).

## 2026-11-16

- **Held parts add themselves up** (the wider code audit, by claude-fable-5-2): `EffectPart.add_held` and `EffectHeldTotals`. The EffectManager knew the three kinds of held part by class and did their sums itself, so a new kind did nothing until the manager was edited too. A Stat keeps its modifiers through a new `base_value` (`Stat.set_modifiers`).
- **Hits and death moved to the AbilityManager** (pawn M3): `is_invulnerable` and `health_ran_out` are the AbilityManager's, the hit's effects come from `AbilityManager._take_hit`, and the EffectManager clears its list by listening to `died` (`Pawn._die` used to call `remove_all`).
- **Pawns that run every 2nd or 4th tick** (pawn spec 8.21): the active list counts down by `ticks_elapsed`, and a period that came round more than once in that time is due that many times.
- `KnockbackPart` asks the AbilityManager for its pawn's Knockback (`get_knockback()`, found once) instead of searching the ability list on every push.

## 2026-11-12

- Two editor warnings fixed in `EffectManager`: a size check without an integer division, and `String()` on both sides of a conditional.

## 2026-11-10

- **Effects** (pawn spec 8.11, the owner's design, shaped like Unreal's gameplay effects): `Effect` (a Resource, instant or over time, with a period, stacking and tags), parts (`StatChangePart`, `KnockbackPart`, `LifestealPart`; held: `StatModifierPart`, `AbilityPriorityPart`, `ResistancePart`), `EffectApplier` (on start or on hit, plus an `ON_PARRY` trigger added on 2026-11-15), `EffectManager` (a pawn part: applies effects with the pawn's resistances, keeps over-time ones in a rolled-back list) and `EffectTags` (a tag set of its own). `KnockbackPart` replaced MeleeAttackAbility's knockback settings, and hits carry effects instead of damage and knockback numbers.
