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
 an ability ─► EffectApplier (child): ON_START ─► its own pawn
                                      ON_HIT ───► HitInfo ─► the target
 a HitInterceptor ─► EffectApplier: ON_INTERCEPT ─► the attacker (or itself)
 an ApplyEffectStep, or code ──────────────────────► a pawn
                                                       │
                                                       ▼
                         the pawn's EffectManager: resistances, active list (rolls back)
                              ├─ do-once parts (authority only): StatChangePart, KnockbackPart, LifestealPart
                              └─ held parts (every machine):    StatModifierPart, AbilityPriorityPart, ResistancePart
```

- **`Effect`** is a Resource, saved in `resources/effects/`: instant (its parts run once) or over time (`duration_ticks`, with an optional `period_ticks` and a `stacking` rule, in ticks at 60 a second). Its `tags` say what kind it is; `is_harmful` decides whether resistances and invulnerability apply.
- **Parts** (`EffectPart`, in `parts/`) are what an effect does, run in list order. Do-once parts run on the authority only (the server, or offline): damage, heals, pushes, lifesteal. Held parts hold while an over-time effect lasts, on every machine, so a client predicting its own pawn agrees: stat changes, ability number boosts, resistances.
- **`EffectApplier`** is a child node of an ability (or of a HitInterceptor) that says which effects it applies, when (ON_START, ON_HIT, ON_INTERCEPT) and to whom (TARGET or SELF).
- **`EffectManager`** is a part on every pawn. It applies effects to its own pawn with its resistances, keeps over-time ones in `active_effects` (rolled back and sent in snapshots), counts them down each tick and clears them when the pawn dies.
- **Effect tags** say what kind of effect something is (`effect.damage.elemental.fire`): the `effect` category of the one tag registry (`tags/TagRegistry`), declared in `resources/tag_declarations.tres`. Code uses the constants in `Tags.EFFECT` (`Tags.EFFECT.DAMAGE_PHYSICAL`).
- `EffectApplication` (one application, handed to each do-once part) and `EffectHeldTotals` (what the held parts add up to) are plumbing a new part works with.

## How to use it

**Make damage or a heal.** New Resource > `Effect`, saved in `resources/effects/`. Add a `StatChangePart` with stat Health and amount -20 (damage) or +15 (a heal; untick `is_harmful` so resistances don't touch it). Give it a tag such as `effect.damage.physical`.

**Make an ability's hit do it.** Add an `EffectApplier` under the ability, trigger ON_HIT, applies_to TARGET, and put the effect in its list. Add a `KnockbackPart` to the effect for a push (and a hop), a `LifestealPart` after the damage to heal the attacker. Applies_to SELF on ON_HIT rewards the attacker only when the hit connects.

**Make a poison or a heal over time.** Set `duration_ticks` (180, 3 s) and `period_ticks` (60, 1 s): its do-once parts run when it lands and every period while it lasts. `stacking` ADD_STACK with `max_stacks` makes repeated hits stack.

**Make a slow, a buff or a ward.** An over-time effect with held parts: a `StatModifierPart` (MoveSpeed, multiply 0.7) for a slow, a `ResistancePart` (`effect.damage.elemental.fire`, 0.5) for a fire ward, an `AbilityPriorityPart` to boost a group of abilities' priority or interrupt numbers.

**Give a pawn resistances.** On its EffectManager, `resistances`: effect tag -> amount. 0.25 takes a quarter off, 1 or more ignores those effects, negative is a weakness. A resistance to `effect.damage.elemental` covers fire and frost.

**From code:**
```gdscript
pawn.effect_manager.apply_effect(effect, source)          # source: who applied it, or null
pawn.effect_manager.remove_with_tag(Tags.EFFECT.DEBUFF)    # a cleanse
var hurt := Effect.make_damage(20)                        # a quick instant damage effect, for traps and tests
```

**Write a new kind of part.** Extend `EffectPart`, give it `@export` settings, and either override `apply_once(application)` (a do-once part) or return true from `is_held()` and override `add_held(totals, stacks)` (a held part). Keep no state on the part: one part is shared by every pawn the effect lands on.

## How it works

**Applying.** `EffectManager.apply_effect` refuses a dead pawn, and a harmful effect while the pawn is invulnerable (a dash) or has 1 or more resistance. An instant effect runs its do-once parts now. An over-time one goes in the active list (or, if it's there, its `stacking` rule decides); the first time its do-once parts run too, and its held parts hold from then on, on every machine. Do-once parts run in order on the authority only; once Health reaches 0 the pawn dies (`AbilityManager.health_ran_out`) and the rest are skipped. Health taken from a source adds threat in this pawn's AI memory for it.

**Each tick** (`tick_effects`, called by the pawn before its abilities): every active effect counts down and ends at 0, and one with a period runs its do-once parts again when it comes round (3 s with a 1 s period runs at 0, 1 and 2 s). A pawn with effects on it doesn't rest.

**Rollback.** The active list is one `PackedInt64Array`, `active_effects`, five numbers per effect: its id (`Effect.get_id`, from its file path or `effect_name`), ticks left, ticks to its next period, stacks, and its source (an entity id online, else an instance id). The pawn's `TickStateComponent` rolls it back and sends it in snapshots. What the held parts add up to (stat values, ability numbers, resistances) is worked out from the list whenever it changes, including when a rollback loads it, so it needn't roll back itself.

**Resistances.** The inspector's `resistances` plus every held `ResistancePart`, as effect tag -> amount. An effect's resistance is every one whose tag is one of its tags or a level above one, added up: 0.2 against `effect.damage.elemental` and 0.3 against `effect.damage.elemental.fire` make 0.5 against fire. They apply only to harmful effects.

**Tags.** Effect tags are one category of the tag registry (`tags/README.md`): a dot means "inside", every level gets its own bit, and a tag's mask holds its own bit plus its parents', so a resistance to `effect.damage.elemental` catches fire and frost with one AND and never `damaged`. They're declared in `resources/tag_declarations.tres`, sorted and numbered at startup so every machine agrees. A constant in `Tags.EFFECT` must be declared there (`effect_selftest` checks it).

**Odd cases** (all checked in `effect_selftest`):
- An effect with no parts does nothing, and an over-time one still shows in the active list for its duration.
- Held parts on an instant effect do nothing; a warning says so once.
- A saved over-time effect is recognised on every machine by its file path; one made in code needs an `effect_name` to be recognised on a client, or it works offline only.
- The list is full (`max_active_effects`): a new over-time effect is refused, with a warning once.
- An id in the list this machine doesn't know: it counts down, its held parts do nothing here, with a warning once.
- The pawn dies: everything in the list is removed.
- An empty or blank tag has no bit and matches nothing. An undeclared tag is added on the spot with a one-time warning (machines may disagree online, which the warning is for); asking with `has_tag` never adds one. More than 64 levels: the extras get no bit and warn once. With no declarations file everything works and every tag counts as undeclared.

## Settings worth knowing

| Setting | Where | Default | What it does |
|---|---|---|---|
| `duration_ticks` | `Effect` | 0 (instant) | How long it stays on the pawn, in ticks at 60 a second |
| `period_ticks` | `Effect` | 0 | For an over-time effect, how often its do-once parts run again, in ticks at 60 a second |
| `stacking`, `max_stacks` | `Effect` | REFRESH, 1 | What a second application does: restart its time, add a stack, or nothing |
| `is_harmful` | `Effect` | on | Resistances and invulnerability apply to it |
| `tags` | `Effect` | empty | What kind of effect it is, for resistances and removing by tag |
| `effect_name` | `Effect` | empty | A name for readouts; needed for an over-time effect made in code to be recognised online |
| `trigger`, `applies_to` | `EffectApplier` | ON_HIT, TARGET | When it applies its effects, and to whom |
| `resistances` | `EffectManager` | empty | The pawn's own resistances, by effect tag |
| `max_active_effects` | `EffectManager` | 16 | The most over-time effects a pawn can have at once |

## Tests

`effects/tests/effect_selftest`: effect tags, instant effects (damage, resistances, immunity, lifesteal, invulnerability), over-time effects (slows, poisons that tick and kill, stacking, cleanses, dying), boosts to ability numbers, a rollback loading the active list, and the odd cases in `EffectManager` and `Effect`. Hits carrying effects are also covered by the abilities' tests (`combat_selftest`, `fight_selftest`, `hit_interceptor_selftest`). Run them with `bash tools/run_tests.sh <name>`.
