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

## Tests

No tests of its own; `game_mode/tests/spawn_manager_selftest` covers spawn points and spawners, and the arena samples' tests use spawners.
