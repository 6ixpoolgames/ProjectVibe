<!-- Written by Claude (claude-opus-5-5), 2026-11-17: the effects system's overview, beside its code. -->

# Effects

What abilities and hits do to pawns: damage, heals, pushes, slows, poisons, resistances and combo boosts, each a saved effect file that any ability can use, applied by the pawn that receives it.

**Status:** built, tier 0. Not yet: effects that last until removed, on-kill and on-end triggers, statuses that change what blocks what, effects that change hit shapes, and a tuning panel.

| File | What it's for |
|---|---|
| [README.md](README.md) | This overview: what's here and how to use it |
| [REFERENCE.md](REFERENCE.md) | Every class, setting and function, generated from the code's doc comments (`python tools/docs/make_reference.py effects`) |
| [CHANGELOG.md](CHANGELOG.md) | What changed and why, newest first, and the refactor candidates |
| [PAWN_SPEC.md](../../../docs/pawn/PAWN_SPEC.md) | The design: section 8.11 (effects), 8.23 (hit interceptors' effects) |

## The pieces

```
 an ability's definition: start_effects ─────────► its own pawn
                          its hit's target_effects ─► HitInfo ─► the target (attacker_effects: the attacker)
 a HitInterceptor ─► EffectApplier: ON_INTERCEPT ─► the attacker (or itself)
 an ApplyEffectStep, or code ──────────────────────► a pawn
                                                       │
                                                       ▼
                         the pawn's StatusManager: resistances, active list (rolls back)
                              ├─ effectors (authority only):  StatChangeEffector, KnockbackEffector, LifestealEffector
                              └─ modifiers (every machine):    StatModifier, AbilityModifier, ResistanceModifier
```

- **`Effect`** is a Resource, saved in `resources/effects/`: instant (its effectors fire once) or over time (`duration_ticks`, with an optional `period_ticks` and a `stacking` rule, in ticks at 60 a second). Its `tags` say what kind it is; `is_harmful` decides whether resistances and invulnerability apply.
- **Modifiers and effectors** (pawn spec 16.8) are what an effect does, in two lists by timing. **Modifiers** (`EffectModifier`, in `modifiers/`) hold while the effect lasts, on every machine: `StatModifier` (a stat's multiply and add, or an override), `AbilityModifier` (an ability group's priority numbers), `ResistanceModifier`. **Effectors** (`EffectEffector`, in `effectors/`) fire when it's applied and at each period, on the authority only, in list order: `StatChangeEffector` (damage, heals), `KnockbackEffector`, `LifestealEffector`. On application the modifiers take hold first, then the effectors fire. A stat with modifiers is base × every multiply + every add (multiply, then add, for everything), or the last override's value.
- **Which effects apply when** lives in definitions (pawn spec 16.7): an ability definition's `start_effects` go on its own pawn when it starts; its hit definition's (`hit`) `target_effects` go on a pawn it hits and `attacker_effects` on the attacker. `EffectApplier` is left only under a HitInterceptor (ON_INTERCEPT: what a parry does back), until parrying becomes an effect.
- **`StatusManager`** is a part on every pawn. It applies effects to its own pawn with its resistances, keeps over-time ones in `active_effects` (rolled back and sent in snapshots), keeps their deadlines and runs them down each tick and clears them when the pawn dies.
- **Effect tags** say what kind of effect something is (`effect.damage.elemental.fire`): the `effect` category of the one tag registry (`tags/TagRegistry`), declared in `resources/tag_declarations.tres`. Code uses the constants in `Tags.EFFECT` (`Tags.EFFECT.DAMAGE_PHYSICAL`).
- `EffectApplication` (one application, handed to each effector) and `ModifierTotals` (what the modifiers add up to) are plumbing a new modifier or effector works with.

## How to use it

**Make damage or a heal.** New Resource > `Effect`, saved in `resources/effects/`. Add a `StatChangeEffector` with stat Health and amount -20 (damage) or +15 (a heal; untick `is_harmful` so resistances don't touch it). Give it a tag such as `effect.damage.physical`.

**Make an ability's hit do it.** Put the effect in the `target_effects` of the ability definition's hit definition (`hit`; the samples keep theirs in `resources/hits/`, such as `hits/swing.tres`). Add a `KnockbackEffector` to the effect for a push (and a hop), a `LifestealEffector` after the damage to heal the attacker. `attacker_effects` reward the attacker only when the hit connects; `start_effects` on the ability definition go on its own pawn when it starts.

**Make a poison or a heal over time.** Set `duration_ticks` (180, 3 s) and `period_ticks` (60, 1 s): its effectors run when it lands and every period while it lasts. `stacking` ADD_STACK with `max_stacks` makes repeated hits stack.

**Make a slow, a buff or a ward.** An over-time effect with modifiers: a `StatModifier` (MoveSpeed, multiply 0.7) for a slow, a `ResistanceModifier` (`effect.damage.elemental.fire`, 0.5) for a fire ward, an `AbilityModifier` to boost a group of abilities' priority or interrupt numbers.

**Give a pawn resistances.** On its StatusManager, `resistances`: effect tag -> amount. 0.25 takes a quarter off, 1 or more ignores those effects, negative is a weakness. A resistance to `effect.damage.elemental` covers fire and frost.

**From code:**
```gdscript
pawn.status_manager.apply_effect(effect, source)          # source: who applied it, or null
pawn.status_manager.remove_with_tag(Tags.EFFECT.DEBUFF)    # a cleanse
var hurt := Effect.make_damage(20)                        # a quick instant damage effect, for traps and tests
```

**Write a new modifier or effector.** Extend `EffectModifier` and override `add_held(totals, stacks)` (adding to `ModifierTotals`), or extend `EffectEffector` and override `fire(application)`. Give it `@export` settings; it keeps no state while playing, since one is shared by every pawn its effect lands on.

## How it works

**Applying.** `StatusManager.apply_effect` refuses a dead pawn, and a harmful effect while the pawn is invulnerable (a dash) or has 1 or more resistance. An instant effect runs its effectors now. An over-time one goes in the active list (or, if it's there, its `stacking` rule decides); the first time its effectors run too, and its modifiers hold from then on, on every machine. Effectors fire in order on the authority only; once Health reaches 0 the pawn dies (`AbilityManager.health_ran_out`) and the rest are skipped. Health taken from a source adds threat in this pawn's AI memory for it.

**Each tick** (`tick_effects`, called by the pawn before its abilities): nothing counts down. Each active effect keeps the tick it ends and the tick of its next period (deadlines); the status manager does nothing until the soonest comes, then ends what's over and runs the periods that came due (3 s with a 1 s period runs at 0, 1 and 2 s; a pawn running every Nth tick gets every period it missed). A pawn with effects on it doesn't rest.

**Rollback.** The active list is one `PackedInt64Array`, `active_effects`, five numbers per effect: its id (`Effect.get_id`, from its file path or `effect_name`), the tick it ends, the tick of its next period, stacks, and its source (an entity id online, else an instance id). The pawn's `TickStateComponent` rolls it back and sends it in snapshots. What the modifiers add up to (stat values, ability numbers, resistances) is worked out from the list whenever it changes, including when a rollback loads it, so it needn't roll back itself.

**Resistances.** The inspector's `resistances` plus every held `ResistanceModifier`, as effect tag -> amount. An effect's resistance is every one whose tag is one of its tags or a level above one, added up: 0.2 against `effect.damage.elemental` and 0.3 against `effect.damage.elemental.fire` make 0.5 against fire. They apply only to harmful effects.

**Tags.** Effect tags are one category of the tag registry (`tags/README.md`): a dot means "inside", every level gets its own bit, and a tag's mask holds its own bit plus its parents', so a resistance to `effect.damage.elemental` catches fire and frost with one AND and never `damaged`. They're declared in `resources/tag_declarations.tres`, sorted and numbered at startup so every machine agrees. A constant in `Tags.EFFECT` must be declared there (`effect_selftest` checks it).

**Odd cases** (all checked in `effect_selftest`):
- An effect with no modifiers or effectors does nothing, and an over-time one still shows in the active list for its duration.
- Modifiers on an instant effect do nothing; a warning says so once.
- A saved over-time effect is recognised on every machine by its file path; one made in code needs an `effect_name` to be recognised on a client, or it works offline only.
- The list is full (`max_active_effects`): a new over-time effect is refused, with a warning once.
- An id in the list this machine doesn't know: it still ends on time, its modifiers do nothing here, with a warning once.
- The pawn dies: everything in the list is removed.
- An empty or blank tag has no bit and matches nothing. An undeclared tag is added on the spot with a one-time warning (machines may disagree online, which the warning is for); asking with `has_tag` never adds one. More than 64 levels: the extras get no bit and warn once. With no declarations file everything works and every tag counts as undeclared.

## Settings worth knowing

| Setting | Where | Default | What it does |
|---|---|---|---|
| `duration_ticks` | `Effect` | 0 (instant) | How long it stays on the pawn, in ticks at 60 a second |
| `period_ticks` | `Effect` | 0 | For an over-time effect, how often its effectors run again, in ticks at 60 a second |
| `stacking`, `max_stacks` | `Effect` | REFRESH, 1 | What a second application does: restart its time, add a stack, or nothing |
| `is_harmful` | `Effect` | on | Resistances and invulnerability apply to it |
| `tags` | `Effect` | empty | What kind of effect it is, for resistances and removing by tag |
| `effect_name` | `Effect` | empty | A name for readouts; needed for an over-time effect made in code to be recognised online |
| `start_effects` | `AbilityDefinition` | empty | Effects on its own pawn when it starts |
| `target_effects`, `attacker_effects` | `HitDefinition` | empty | What a hit does to the pawn hit, and to the attacker |
| `resistances` | `StatusManager` | empty | The pawn's own resistances, by effect tag |
| `max_active_effects` | `StatusManager` | 16 | The most over-time effects a pawn can have at once |

## Tests

`effects/tests/effect_selftest`: effect tags, instant effects (damage, resistances, immunity, lifesteal, invulnerability), over-time effects (slows, poisons that tick and kill, stacking, cleanses, dying), boosts to ability numbers, a rollback loading the active list, and the odd cases in `StatusManager` and `Effect`. Hits carrying effects are also covered by the abilities' tests (`combat_selftest`, `fight_selftest`, `hit_interceptor_selftest`). Run them with `bash tools/run_tests.sh <name>`.
