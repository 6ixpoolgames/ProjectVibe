<!-- Written by Claude (claude-opus-5-5), 2026-11-24: the status system's running changelog. Newest first. Add an entry with every
change; code comments say what the code does now, this says how it got here and why. -->

# Status changelog

This folder holds the status manager (pawn spec 16.8). Overview: [README.md](README.md). Its history before the merge is in [stats/CHANGELOG.md](../stats/CHANGELOG.md) and [effects/CHANGELOG.md](../effects/CHANGELOG.md).

## Refactor candidates

| What | Where | Why | Size |
|---|---|---|---|
| A test-only helper | `StatusManager.set_detectability` | Only tests call it; a helper in tests/ keeps it out of the shipping class | S |
| Effect sources by instance id offline | `StatusManager._source_key` | Nothing finds an entity by its number until the entity registry (step 9) | S |
| Stat, effect and part classes in three folders | `stats/`, `effects/`, `status/` *(no tag: a folder layout)* | One system now; the classes can move here once step 3b settles their names (saved resources name their scripts by path) | M |

## 2026-11-24

- **Modifiers and effectors, multiply then add** (the pawn redesign's build step 3b): the status manager runs an effect's `modifiers` (held, on every machine) and its `effectors` (fired on application and at each period, on the authority); `Stat.set_modifiers` takes an override, and works the value out as base × multiplies + adds. See effects/CHANGELOG.md.
- **`StatusManager`** (new, the pawn redesign's build step 3a, pawn spec 16.8): the stat manager and effect manager merged into one component, `pawn.status_manager`, from `parts/StatusManager.tscn` (the two old part scenes are gone; pawn defaults list one part). Health has one name, `StatusManager.HEALTH`.
- **Deadlines:** the active list keeps each effect's end tick and next period tick (`ENDS_AT`, `NEXT_PERIOD_AT`, -1 without a period) instead of ticks left; `tick_effects` does nothing until the soonest. Periods no longer depend on whether the target ran before or after the effect landed in a tick.
- **Thresholds and events:** `change_current(stat, amount, source, cause)` sends the events of the `StatThreshold`s a change crosses on the way down, through `Pawn.send_event`; Health's are `event.health.depleted` (0) and `event.health.low` (25%). Death starts from the depleted event, and the AI's threat from `event.damage.taken`, so the status manager no longer calls the ability manager or writes the AI's memory (both REFACTOR notes resolved). `fill_current` refills without events; the revive and the arena sample use it instead of writing `current`.
- Tested in `status/tests/status_selftest` (in the commit set).
