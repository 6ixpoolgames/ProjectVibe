<!-- Written by Claude (claude-opus-5-5), 2026-11-17: an index of the project's autoloads, beside their code. -->

# Autoloads

The project's four autoloads: the few services every game needs, reachable from any script by name. The owner wants as few as possible: only truly universal functionality lives here, and game rules and per-game defaults go in GameMode modules.

**Status:** built, tier 0. Not yet: the load ladder and the timing record still sit in the tick driver (see the refactor candidates in [CHANGELOG.md](CHANGELOG.md)).

| Autoload | What it is | Documented in |
|---|---|---|
| `TickDriver` | Runs all gameplay in numbered, fixed-length ticks, in a fixed phase order, and replays ticks for rollback | Here: [CHANGELOG.md](CHANGELOG.md); design in [NETCODE_SPEC.md](../../../docs/netcode/NETCODE_SPEC.md) section 3 and [SCALING_SPEC.md](../../../docs/scaling/SCALING_SPEC.md) section 7 |
| `NetworkSession` | Multiplayer: connecting, spawning, inputs, snapshots | [netcode/README.md](../netcode/README.md), [netcode/CHANGELOG.md](../netcode/CHANGELOG.md) |
| `GameMode` | Holds the game's rules as optional modules | [game_mode/README.md](../game_mode/README.md), [game_mode/CHANGELOG.md](../game_mode/CHANGELOG.md) |
| `NavMarkerManager` | Holds every nav marker and answers searches for them | [navigation/README.md](../navigation/README.md), [navigation/CHANGELOG.md](../navigation/CHANGELOG.md) |

Every class and function is in the generated reference (`python tools/docs/make_reference.py singletons`, which writes [REFERENCE.md](REFERENCE.md)).

## The tick driver

Everything that simulates registers with `TickDriver` and gets called once a tick, in phases: input, capture input, simulate, record. A frame runs as many ticks as the time covers (usually one, at most `max_ticks_per_frame`), so the game slows down rather than freezing when overloaded. `rollback(from_tick)` puts predicted parts back and replays later ticks, which the netcode uses on clients. The class description in `TickDriver.gd` has the full rules.

**Take part in ticks.** Call `TickDriver.register(self)` and write any of `_tick_input`, `_tick_capture_input`, `_tick_simulate`, `_tick_record`. `dt` is always the tick's length. Pawns, `TickStateComponent` and `NetworkEntity` register themselves.

**Time things in ticks.** `TickDriver.seconds_to_ticks(seconds)` for a time a designer typed; settings counted in ticks are written for 60 a second and converted with `ticks_at_rate()`, so they last as long at any tick rate.

**Random numbers.** `TickDriver.tick_rng(key, salt)` instead of `randf()`, so a replayed tick rolls the same.

| Setting | Default | What it does |
|---|---|---|
| `tick_rate` (or project setting `project_base/network/tick_rate`, or `-- --tick-rate=30`) | the physics rate | Ticks per second, chosen before a match |
| `max_ticks_per_frame` | 3 | Most ticks one frame may run; the rest of the time is dropped |
| `load_ladder_enabled` | on | When overloaded, AI pawns run every 2nd or 4th tick |
| `load_step_override` | automatic | Forces the load step (tests pin it to 1) |

## Tests

`singletons/tests/`: `tick_driver_selftest` (phases, order, registering mid-tick, the frame limit, rollback) and `tick_rate_selftest` (a match at another tick rate). The load ladder is checked in `pawn/tests/tick_step_selftest` and `game_mode/tests/game_mode_selftest`. Run them with `bash tools/run_tests.sh <name>`. The other autoloads' tests are with their systems.
