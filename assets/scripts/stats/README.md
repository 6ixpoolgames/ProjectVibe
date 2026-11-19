<!-- Written by Claude (claude-opus-5-5), 2026-11-17: the stats system's overview, beside its code. -->

# Stats

The numbers about a pawn, such as how fast it walks or how much Health it has, kept as nodes a designer can see and set, which abilities, effects and the AI read by name.

**Status:** built, tier 0. Not yet: a deeper stats design, which waits for the game's mechanics.

| File | What it's for |
|---|---|
| [README.md](README.md) | This overview: what's here and how to use it |
| [REFERENCE.md](REFERENCE.md) | Every class, setting and function, generated from the code's doc comments (`python tools/docs/make_reference.py stats`) |
| [CHANGELOG.md](CHANGELOG.md) | What changed and why, newest first, and the refactor candidates |
| [PAWN_SPEC.md](../../../docs/pawn/PAWN_SPEC.md) | The pawn design: section 9 (stats) |

## The pieces

```
 Pawn
 └── StatManager            pawn.stat_manager: finds stats by name, counts changes (version)
     ├── MoveSpeed (Stat)   base_value, with effects on top = value
     ├── Health (Stat)      changes_during_play: a current value that rolls back
     └── Detectability (Stat)  table_column: copied into the pawn table for C++
```

- **`StatManager`** is a default pawn part (`assets/scenes/pawn/parts/StatManager.tscn`, added by `game_mode/PawnInitializer`). It holds one `Stat` child per stat, finds them by name, and raises its `version` whenever a value changes, so abilities that keep stat values know to read them again.
- **`Stat`** is one number. Its `value` is its `base_value` plus what held effects add, times what they multiply (`effects/EffectManager` calls `set_modifiers`). A stat with `changes_during_play`, such as Health, also has a `current` amount from 0 to its value, which rolls back through the pawn's `TickStateComponent` and reaches clients in snapshots.
- Health has one name, `StatManager.HEALTH`, read by Death, hits (`abilities/AbilityManager`), the kill floor and the readouts. Detectability is a stat (`StatManager.DETECTABILITY`, read with `StatManager.detectability_of(pawn)`), copied into the pawn table's `detectability` column for the AI's sensing job.

## How to use it

**Change a pawn's stats.** In the pawn scene, add `parts/StatManager.tscn` (or open the default one) and set each stat's `base_value`. The defaults are MoveSpeed, SprintSpeed, Acceleration, Deceleration, AirControl, TurnRate, JumpVelocity, DashAcceleration, Health and Detectability.

**Add a stat.** Add a `Stat` node under the StatManager; its node name is the stat's name. Code reads it with a fallback, so a pawn without it still works:
```gdscript
var speed := pawn.stat_manager.get_value(&"MoveSpeed", 5.0)
```

**Hurt or heal.** On the server, `pawn.stat_manager.change_current(StatManager.HEALTH, -20)`, kept between 0 and the stat's value. Usually an effect does this (`effects/parts/StatChangePart`), not code.

**Let C++ read a stat.** Set its `table_column` to a pushed column of the pawn table (`PawnTable.add_pushed_column`). The column gets the value whenever it changes.

## Settings worth knowing

| Setting | Where | Default | What it does |
|---|---|---|---|
| `base_value` | each `Stat` | 0 (see the default part) | The stat's value before effects |
| `changes_during_play` | each `Stat` | off (on for Health) | Gives the stat a current amount that goes up and down and rolls back |
| `table_column` | each `Stat` | empty (`detectability` for Detectability) | Copies the value into this pawn table column for C++ |

## How it works

- A stat that isn't there is never an error: `get_value` gives the fallback and `get_stat` gives null. A child that isn't a `Stat` is ignored; Godot renames a second child of the same name, so two stats can't share one.
- **Health** has one name, `StatManager.HEALTH`, which everything that means "the pawn's health" reads (Death, hits, the kill floor, the readouts). A fuller stats pass comes with the game mechanics.

## Tests

`stats/tests/stat_selftest`: values and fallbacks, stats added and removed while running, and the default stats part. Health, damage and death are also covered by `abilities/tests/combat_selftest`. Run them with `bash tools/run_tests.sh <name>`.
