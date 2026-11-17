<!-- Written by Claude (claude-opus-5-5), 2026-11-17: the spawning system's overview, beside its code. -->

# Spawning

Where pawns appear and how they're kept topped up: spawn points placed in a level, and spawners that replace pawns as they die.

**Status:** built, tier 0. Not yet: spawn waves and rules beyond "keep N alive" (those belong in a game's GameMode modules).

| File | What it's for |
|---|---|
| [README.md](README.md) | This overview |
| [REFERENCE.md](REFERENCE.md) | Every class and setting, generated from the code's doc comments (`python tools/docs/make_reference.py spawning`) |
| [CHANGELOG.md](CHANGELOG.md) | What changed and why, and the refactor candidates |

## The pieces

- **`SpawnPoint`**: a spot in a level with a `team`, a `group` and a `scatter_radius`, like Unreal's PlayerStart. It spawns nothing itself.
- **`PawnSpawner`**: keeps `keep_alive` pawns of one `pawn_type` alive, on the server or offline, replacing each that dies after `respawn_seconds`.
- **`SpawnManager`** (`game_mode/`): the GameMode module both go through; it picks points and brings players back after dying.

## How to use it

**Keep a group of enemies alive.** Put a `PawnSpawner` in the level, set `pawn_type` (a type registered with `NetworkSession.register_type`) and `keep_alive`. Pawns appear around it, or at spawn points if you set `spawn_group`.

**Place where players start.** Put `SpawnPoint`s on the floor, turned the way pawns should face, with a `team` (-1 for anyone).

## How it works

- **PawnSpawner** fills up to `keep_alive` as soon as it's switched on, and after that whenever it has fewer living pawns and no replacement is waiting. A pawn of its own that dies has its body removed after `body_seconds` and a replacement due `respawn_seconds` after the death; the replacement is a fresh pawn, so its AI starts with no memory of the fight. A pawn removed another way counts as a death with no body to remove. `total_limit` above 0 stops it after that many in all. With `only_where_loaded` on it waits while the ground around it isn't loaded (the `AIActivationManager` rule; no terrain counts as loaded). All delays count ticks.
- **Where pawns appear.** With `spawn_group` empty, within `scatter_radius` of the spawner facing its way; with a group, at `SpawnPoint`s in it that accept the pawn's team. A request with no group may use any point its team may use. How a point is chosen: the game_mode README.

## Tests

No tests of its own; `game_mode/tests/spawn_manager_selftest` covers spawn points and spawners, and the arena samples' tests use spawners.
