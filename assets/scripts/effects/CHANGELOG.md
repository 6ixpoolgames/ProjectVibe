<!-- Written by Claude (claude-opus-5-5), 2026-11-17: the effects system's running changelog (the owner's call: history leaves the
code comments and lives here, next to the code). Newest first. Add an entry with every change; code comments say what the code does
now, this says how it got here and why. -->

# Effects changelog

Effects are this folder: `Effect` and its parts (`parts/`), `EffectApplier`, `EffectManager`, `EffectApplication` and `EffectHeldTotals` (effect tags are in the one tag registry, `tags/`). They're what abilities and hits do to pawns; the abilities that apply them have their own changelog (`abilities/`). Design: [docs/pawn/PAWN_SPEC.md](../../../docs/pawn/PAWN_SPEC.md), section 8.11. Overview: [README.md](README.md).

## Refactor candidates

Code that works but doesn't yet fit the project's goals (reusable, extensible, efficient, designer friendly). Each is marked `REFACTOR:` in the code. Sizes are rough: S an hour or two, M a day, L more.

| What | Where | Why | Size |
|---|---|---|---|
| Threat through a signal | `EffectManager._run_once` | Effects write threat straight into the AI's memory, so this system knows the AI. A signal for Health taken, which the AI listens to (as it does to `hit_arrived`), keeps effects usable without the AI and open to other listeners (UI, scoring) | S |

## 2026-11-24

- **Effects that grant tags; the last of EffectApplier** (pawn spec 16.7, 16.10 step 4b). `Effect.granted_tags` are owned while an effect lasts (status.parrying, status.invulnerable), and `lasts_until_removed` keeps one until something takes it off (`StatusManager.UNTIL_REMOVED` in its end deadline). `ParryModifier` holds a parry's front and reply (`ModifierTotals.parries`, `StatusManager.get_parries`); `Effect.make_invulnerable` and `make_parrying` make the Dash's and Parry's defaults. The status manager's invulnerability checks read `status.invulnerable`. `KnockbackEffector` sends `event.reaction.knockback` with the push instead of calling Knockback. `EffectApplier` is gone, with the interceptors it served. New file: `resources/effects/parry_stance.tres`.

- **Effect lists into definitions** (pawn spec 16.7, 16.10 step 4a). Which effects apply when is data in definitions now: `AbilityDefinition.start_effects` (on its own pawn when it starts) and the hit definition's `target_effects` and `attacker_effects`. `EffectApplier` is no longer read under an ability (one left there gets a warning); it stays only under a `HitInterceptor`, for what a parry does back, and goes with the interceptors. The samples' hits are files in `resources/hits/`.

- **Modifiers and effectors** (the pawn redesign's build step 3b, pawn spec 16.8): an effect's one `parts` list is two, by timing. `modifiers` (`EffectModifier`, in `modifiers/`) hold while it lasts: `StatModifierPart` → `StatModifier` (now with an override: `overrides`, `override_value`, the last applied wins), `ResistancePart` → `ResistanceModifier`, `AbilityPriorityPart` → `AbilityModifier`. `effectors` (`EffectEffector`, in `effectors/`) fire on application and at each period: `StatChangePart` → `StatChangeEffector`, `KnockbackPart` → `KnockbackEffector`, `LifestealPart` → `LifestealEffector`; `apply_once` is `fire`. `EffectPart` and `is_held()` are gone; `EffectHeldTotals` is `ModifierTotals`; `has_held_parts()` is `has_modifiers()`. The 13 saved effects in `resources/effects/` were converted.
- **Multiply, then add** (the owner's call): a stat's value is base × every multiply + every add (was (base + adds) × multiplies), for everything; a designer-chosen order may be a feature later. The effect test's stacking check changed to match (5 × 0.5 × 0.5 − 1 = 0.25).
- Left for step 4: effect lists into definitions (`AbilityDefinition.start_effects`), with `EffectApplier` going. Resistances' base values from a status manager definition wait for definitions of components (step 10).
- **Merged into the status manager** (the pawn redesign's build step 3a, pawn spec 16.8): `EffectManager` is gone; its job is `status/StatusManager.gd`, with the active list on deadlines. Damage taken goes out as `event.damage.taken`. History from here: [status/CHANGELOG.md](../status/CHANGELOG.md).
- **Ticks at 60 a second** (the pawn redesign's build step 1, foundations (pawn spec 16.10)): `Effect.duration_seconds` and `period_seconds` are now `duration_ticks` and `period_ticks`; the two combo boosts were converted (0.6 s → 36). Offline effect sources are still kept by instance id until the entity registry can find an entity by number (REFACTOR).

## 2026-11-23

- **Documentation pass:** `EffectManager` reaches the ability manager as `pawn.ability_manager`, and keys a hit's source by `HitInfo.key_of` like the ability manager; `EffectApplier`'s doc and this header brought up to date.

## 2026-11-22

- **Owned tags** (tag spec step 2): the pawn owns every active effect's tags (`OwnedTags`), once per effect whatever its stacks. Set again on every refresh, and at once when a rollback or snapshot loads `active_effects`, since a client never counts down the effects of pawns it only draws.
- **Effect tags joined the one tag registry** (tag spec step 1): `EffectTags` is gone; effect tags are the `effect` category of `TagRegistry` (`effect.damage.elemental.fire`), with constants in `Tags.EFFECT`, declared in `resources/tag_declarations.tres` (`effect_tag_declarations.tres` merged into it). Saved effects were rewritten to the new names.

## 2026-11-19

- **Tells its pawn it's there** (state store step 3): its `_enter_tree` sets the pawn's reference to it, if the pawn has none yet, instead of the pawn looking through its children in `_ready`. The reference is there before any part's `_ready`.

- **An effect landing marks its pawn changed** (`Pawn.mark_state_changed`), so the state store reads a pawn that's between its own runs instead of copying its last row forward.

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
