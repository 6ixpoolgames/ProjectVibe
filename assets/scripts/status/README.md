<!-- Written by Claude (claude-opus-5-5), 2026-11-24: the status system's overview. -->

# Status

A pawn's status in one component (pawn spec 16.8): its stats and the effects on it. `StatusManager` merges the old `StatManager` and `EffectManager`; the `Stat` and `Effect` classes still live in `stats/` and `effects/`, whose READMEs describe them.

**Status:** built, tier 0 (pawn redesign step 3): the merge, effects on deadlines, stat thresholds and their events, modifiers and effectors, one modifier rule (multiply, then add). Next: effect lists into definitions, with the hit ability (step 4).

```
 Pawn
 └── StatusManager             pawn.status_manager (parts/StatusManager.tscn)
     ├── MoveSpeed (Stat)      base_value, with effects on top = value
     ├── Health (Stat)         changes_during_play: a current value that rolls back; thresholds at 0 and 25%
     └── Detectability (Stat)  table_column: copied into the pawn table for C++
     active_effects            each over-time effect: id, the tick it ends, the tick of its next period, stacks, source
```

## How to use it

**Read a stat.** `pawn.status_manager.get_value(&"MoveSpeed", 5.0)`: a missing stat gives the fallback.

**Hurt or heal.** On the server, `pawn.status_manager.change_current(StatusManager.HEALTH, -20, source, cause)`; usually an effect does it (`StatChangePart`). `fill_current(StatusManager.HEALTH)` refills (a revive) without events.

**React to a threshold.** A stat with `changes_during_play` lists `thresholds` (`StatThreshold`: an event tag, a level, and whether the level is a share of the max). When `change_current` takes the current value to a threshold or below, its event goes out through the pawn: `pawn.send_event(tag, GameplayEventData)`. Connect to `pawn.gameplay_event_received`. Health's defaults: `event.health.depleted` at 0 (the ability manager starts Death) and `event.health.low` at 25%.

**Apply an effect.** `pawn.status_manager.apply_effect(effect, source)`; see `effects/README.md` for effects themselves.

## How it works

- **Events, not calls.** Health reaching 0 sends `event.health.depleted`; the ability manager listens and starts Death. Health an effect takes sends `event.damage.taken` with its source and amount; the AI's memory listens and adds threat. Neither the status manager nor the effects know about abilities' Death or the AI. A value a snapshot or rollback restores sends nothing, since only `change_current` checks thresholds.
- **Deadlines.** An over-time effect keeps the tick it ends and the tick of its next period. `tick_effects` returns at once until the soonest deadline in the list, then ends what's over and runs the periods that came due (a pawn running every Nth tick gets each period it missed). The tick it ends on runs no period.
- **Rollback.** The active list (`active_effects`, five numbers per effect) and each changing stat's `current` roll back; everything else is worked out from them.
- **One modifier rule:** a stat's value is base × every multiply + every add (multiply, then add, for everything: it curbs stat inflation), or the value of the last override applied. A designer-chosen order may be a feature later.
- **Modifiers first:** an effect's modifiers take hold before its effectors fire, so a hit that slows and damages works out its damage with the slow already on.
