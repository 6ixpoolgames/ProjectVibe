<!-- Written by Claude (claude-opus-5-5), 2026-11-17: the spawning system's running changelog. History leaves the code comments and lives
here, next to the code. Newest first. -->

# Spawning changelog

Spawning is this folder (`PawnSpawner`, `SpawnPoint`) and the `SpawnManager` GameMode module in `game_mode/`. Design: [docs/pawn/PAWN_SPEC.md](../../../docs/pawn/PAWN_SPEC.md) section 8.9. Overview: [README.md](README.md).

## Refactor candidates

Code that works but doesn't yet fit the project's goals. Each is marked `REFACTOR:` in the code. Sizes: S an hour or two, M a day, L more.

| What | Where | Why | Size |
|---|---|---|---|
| One shared "is the ground loaded here" check | `PawnSpawner._ground_loaded()` | A copy of AIActivationManager's rule; the two could drift apart | S |

## 2026-11-17

- **Comments cleaned up** for the documentation pass: dated notes moved here, doc comments in Godot's markup.

## 2026-11-16

- **No default pawn type** (the wider audit): `pawn_type` is empty by default (it was "goblin", a type only the samples register); empty, it spawns nothing and warns once.
- **Deaths through the AbilityManager** (pawn M3): a spawner listens to `pawn.ability_manager.died`.

## 2026-11-10

- **`PawnSpawner` and `SpawnPoint`** (pawn spec 8.9): a spawner keeps a number of pawns of one type alive, replacing the dead after a delay, around itself or at spawn points in a group; a spawn point is a spot with a team, a group and a scatter radius.
