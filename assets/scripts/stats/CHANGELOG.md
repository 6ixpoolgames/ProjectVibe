<!-- Written by Claude (claude-opus-5-5), 2026-11-17: the stats system's running changelog (the owner's call: history leaves the code
comments and lives here, next to the code). Newest first. Add an entry with every change; code comments say what the code does now,
this says how it got here and why. -->

# Stats changelog

Stats are this folder (`StatManager`, `Stat`) and the default part `assets/scenes/pawn/parts/StatManager.tscn`. Effects change stats through `effects/EffectManager`; hits and death read Health in `abilities/AbilityManager`. Design: [docs/pawn/PAWN_SPEC.md](../../../docs/pawn/PAWN_SPEC.md) section 9. Overview: [README.md](README.md).

**Known future step, not a refactor:** a deeper StatManager design waits for the game mechanics, the owner's call. Tier 0 keeps stats at a reasonable baseline.

## Refactor candidates

Code that works but doesn't yet fit the project's goals (reusable, extensible, efficient, designer friendly). Each is marked `REFACTOR:` in the code. Sizes are rough: S an hour or two, M a day, L more.

| What | Where | Why | Size |
|---|---|---|---|
| One place for the "current stays between 0 and value" rule | `Stat.current`; written directly by `abilities/AbilityManager.revive`, `effects/EffectManager`, `samples/ArenaSample` | Refilling and capping a current value is done by hand in several places. A refill and a cap on `Stat` or `StatManager`, beside `change_current`, would keep the rule in one place | S |

## 2026-11-18

- **Comments rewritten to the reference style** (the documentation pass): the `StatManager` class comment shortened (odd cases and the Health note moved to the README's "How it works"). `GDScript note:` teaching comments removed, keeping any non-obvious fact shortened.

## 2026-11-17

- **Stat columns** (the C++ bundle, pawn M6): a Stat with a `table_column` copies its value into that pushed column of the pawn table when it changes and when it's ready, so C++ (the sensing job) reads it from the table. `StatManager.DETECTABILITY` names the Detectability stat, which `Pawn.detectability` reads and writes, copied into the `detectability` column.
- **One name for Health** (the wider code audit, the owner's call): `StatManager.HEALTH`, read by everything that means the pawn's health. Death had a setting for which stat it watched while other code always read "Health", so changing it would have split the death rule in two; the setting is gone. `StatManager.get_health()` replaced `Pawn.get_health()`.
- **Modifiers kept through a new base value** (the wider audit, done on 2026-11-16): a Stat keeps what effects add and multiply (`set_modifiers`, `_added`, `_multiplied`). The EffectManager used to write `value` itself, so setting `base_value` dropped the effect until the pawn's effects next changed.
- **Comments cleaned up** for the documentation pass: dated notes moved here, doc comments in Godot's markup. Fixed: `get_value`'s doc comment sat above `_enter_tree`; the Stat header said modifiers were still to come; `get_health` said it moved from "Pawn.stat_manager.get_health()" (it was `Pawn.get_health()`). The StatManager doc now says that a stat that changes during play, added after the manager is ready, starts at 0 and doesn't roll back.

## 2026-11-16

- The stat test extends `tests/SelfTest.gd`.

## 2026-11-09

- **Health** (pawn step 10): `changes_during_play` gives a stat a `current` amount, from 0 to its value, that starts full and rolls back (the StatManager lists it with the pawn's TickStateComponent). `get_current` and `change_current` (server only) read and change it.
- **`version`** (tick foundations, pawn spec 15.2): goes up whenever a stat's value changes or a stat comes or goes, so abilities that keep stat values read them again only then. The StatManager keeps its `pawn`.

## 2026-11-08

- **`StatManager` and `Stat`** (pawn spec section 9, step 5): one node per stat, read by name with a fallback, so a missing stat is never a crash. Added to every pawn by PawnInitializer.
