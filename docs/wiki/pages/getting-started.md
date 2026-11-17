<!-- Written by Claude (claude-opus-5-5), 2026-11-17: the wiki's getting-started page: how a game is put together from the base. -->

# Getting started

How a game is put together from the base, in the order you'll meet the pieces. Each section links to the system that holds the detail.

!!! tip "The quickest way in"
    Open `assets/scenes/samples/arena_sample.tscn` or `mass_battle_sample.tscn` and run it. Every system on this page is in use there.
    Press **F1** in a debug build to see the diagnostics keys.

## 1. The game mode

`GameMode` is an autoload that holds the game's rules as **modules**: plain nodes, each doing one job. The project setting `project_base/game_mode/modules` lists them, so a game picks its own set without changing the base.

| Module | What it does |
|---|---|
| [PawnInitializer](systems/game_mode/index.md) | Gives every pawn its default parts |
| [PossessionCoordinator](systems/game_mode/index.md) | Lets a player jump into a pawn and hands it back to its AI when they let go |
| [AIActivationManager](systems/game_mode/index.md) | Freezes far-away AI and picks how often each pawn runs |
| [SpawnManager](systems/game_mode/index.md) | Finds free spots and spawns pawns |
| [TeamRegistry](systems/game_mode/index.md) | Teams and who's hostile to whom |
| [CrowdMover](systems/movement/index.md) | Moves AI walkers as one batch, on worker threads |
| [ReplayRecorder](systems/replay/index.md) | Records every match |
| [DiagnosticsManager](systems/diagnostics/index.md) | Timings, logs, captures and the F-key panels |

Game rules and per-game defaults go in modules, not in the base: that's what keeps the base reusable across games.

## 2. Pawns and their parts

A **pawn** is anything a player or an AI can drive. Its abilities, stats, effects, navigation and AI are **parts**: child nodes attached directly to the pawn. `PawnInitializer` adds any part a pawn's scene doesn't already have, from one defaults file per game (`resources/pawn_defaults.tres`).

To change a part for one kind of pawn, put your own part with the same name in that pawn's scene. To change it for every pawn, change the defaults file.

See [pawn](systems/pawn/index.md), [abilities](systems/abilities/index.md), [stats](systems/stats/index.md), [effects](systems/effects/index.md).

## 3. Controllers: who drives

A pawn reads its moves from a **controller**. A `PlayerController` turns keys and the mouse into an input command; an `AIController` writes the same command from the AI's decisions. Because both write the same thing, a player can take over any pawn and give it back (**possession**), and the network only ever sends inputs.

See [controllers](systems/controllers/index.md), [player](systems/player/index.md), [camera](systems/camera/index.md).

## 4. The tick

All gameplay runs in fixed **ticks** (60 a second by default), driven by `TickDriver`, never in `_process`. Each tick runs the same phases on every pawn, in order:

```
before_tick → input → capture input → simulate → after_simulate → record → after_tick
```

Fixed ticks are what make networking, rollback and replays possible: every machine runs the same ticks with the same inputs. Pawns far from any player run every 2nd or 4th tick, which is how a battle of hundreds stays affordable.

See [singletons](systems/singletons/index.md) (TickDriver) and the [scaling spec](specs/scaling-spec.md).

## 5. Abilities and AI

Everything a pawn does is an **ability**: walking, jumping, a sword swing. Abilities are built from **steps** (child nodes run in order: wind-up, sweep, recover), so a designer makes a new attack by arranging steps in the inspector. Hits become **effects** (damage, knockback) that resistances and stats can change.

The **AI** senses (sight, with awareness that fills and fades), remembers, picks a target, and chooses a behaviour each tick, then drives its pawn through the same controller interface a player uses.

See [abilities](systems/abilities/index.md), [effects](systems/effects/index.md), [ai](systems/ai/index.md).

## 6. The world

A **WorldCoordinator** joins a terrain generator, a chunk streamer and the nav feeder, so terrain chunks load around **streaming sources** (players, cameras, AI groups) and nav is built where pawns need it. Walls and props reach nav through a `BodyNavFeeder`.

See [world](systems/world/index.md), [terrain](systems/terrain/index.md), [streaming](systems/streaming/index.md), [navigation](systems/navigation/index.md).

## 7. Playing together, and looking back

`NetworkSession` hosts and joins games: the server runs the real game, clients predict their own pawn and roll back when the server disagrees. Every match is recorded as a **replay**, and diagnostics keep timings and logs, so a bug report carries what happened and what it cost.

See [netcode](systems/netcode/index.md), [replay](systems/replay/index.md), [diagnostics](systems/diagnostics/index.md).

## 8. A first level

1. Copy `faction_arena_sample.tscn`: it has the world, spawners and the game's start-up wired.
2. Change the terrain's noise and size on its `TerrainGenerator`.
3. Add walls: a `StaticBody3D` with a box shape and a `BodyNavFeeder` child.
4. Point the spawners at your pawn scenes, and set their teams.
5. Run it, press **F9** to see the nav mesh, and **Tab** to jump into a pawn.

## Where things are

| Path | What's there |
|---|---|
| `assets/scripts/<system>/` | A system's code, with its README, REFERENCE and CHANGELOG |
| `assets/scripts/<system>/tests/` | Its tests: `bash tools/run_tests.sh <name>`, or `full` for all |
| `assets/scripts/samples/`, `assets/scenes/samples/` | Sample scenes: test beds, not rules of the base |
| `native/` | The C++ library: nav mesh, and the hot paths (sensing, crowd movement, packing) |
| `docs/` | Design specs, the roadmap, the class index, this wiki's spec |
| `tools/` | The test runner and the docs tools |
