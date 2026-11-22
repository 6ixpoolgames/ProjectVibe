<!-- Written by Claude (claude-opus-5-5), 2026-11-17: the world system's running changelog (the owner's call: history leaves the
code comments and lives here, next to the code). Newest first. Add an entry with every change; code comments say what the code does
now, this says how it got here and why. -->

# World changelog

World is this folder: `WorldCoordinator`, `TerrainNavFeeder`, `BodyNavFeeder` and `KillFloor`. `BodyNavFeeder`'s history is in [navigation's changelog](../navigation/CHANGELOG.md), with the rest of nav. Design: [docs/world/WORLD_SPEC.md](../../../docs/world/WORLD_SPEC.md). Overview: [README.md](README.md).

## Refactor candidates

Code that works but doesn't yet fit the project's goals (reusable, extensible, efficient, designer friendly). Each is marked `REFACTOR:` in the code. Sizes are rough: S an hour or two, M a day, L more.

| What | Where | Why | Size |
|---|---|---|---|
| Tick nav from one universal place | `tick_nav` in `TerrainNavFeeder` | Ticking the whole nav library isn't the terrain feeder's job. Every level has to remember to turn it on, and a level with nav but no terrain (only `BodyNavFeeder`s) has nothing to tick it. An autoload or GameMode module that ticks nav whenever the library is loaded would need no setup | S |
| Fall reports out of `KillFloor` | `KillFloor` (`report_falls`, `fall_report`, `_last_on_ground`) | A debugging aid inside a gameplay class, on by default, tracking every pawn's last standing place on every check. A diagnostics module could track pawns and write the report when `pawn_fell` fires | S |

The "one shared way to reach `NavServer`" row in navigation's changelog applies here too: `TerrainNavFeeder` looks the library up by name in three places.

## 2026-11-22

- **`TerrainNavFeeder` goes with the ticks** (state store spec 13.12): with the tick driver running, it ticks NavServer once after each game tick (not once per physics frame) and checks the sources' interests on ticks, and notes each tile NavServer landed in the `LandingLog`. Without a running tick driver it works as before.

## 2026-11-18

- **Comments rewritten to the reference style** (the documentation pass): moved to the README's new "How it works" section: `KillFloor`'s fall reports and odd cases, `TerrainNavFeeder`'s and `BodyNavFeeder`'s odd cases. "The owner's rule" wording removed from `ChunkStreamer` (streaming) and "the owner's end goal" from `WorldCoordinator`. No stale comments found.

## 2026-11-17

- **Edits rebuild only the nav they touch.** `TerrainNavFeeder` passes the terrain's `edit_area` to `NavServer.submit_mesh` as `dirty_bounds`, so an edit rebuilds the nav tiles under it, not every tile under the chunk (the C++ bundle, stage 2).
- **`BodyNavFeeder`**: walls in nav. See navigation's changelog.
- **Comments cleaned up** for the documentation pass: dated notes moved here, doc comments in Godot's markup. Stale comment fixed: a pawn `KillFloor` can't kill is one with no Health or no EffectManager (it said no Death ability, which the code doesn't check).

## 2026-11-16

- **Pawns as streaming sources** (pawn M2): `TerrainNavFeeder` reads any source in the group, a `StreamingSource` or a `Pawn`, through the source contract in `streaming/StreamingSource.gd`. `KillFloor` looks through `Pawn.GROUP`, the list of all pawns (the wider code audit).
- **Timed for diagnostics:** the kill floor's check, the nav tick and the nav refresh report to `PerfScopes` (diagnostics v0).

## 2026-11-15

- **Kill floors in replays:** every `KillFloor` joins the `kill_floors` group and sends `pawn_fell` with its report, which the replay recorder records (replay v0).

## 2026-11-12

- **`KillFloor`** (pawn spec 8.13), the owner's request after falling through the world twice while away from the keyboard: pawns below its height get `kill_effect` and die the usual way, on the authority only. `report_falls` says in the Debugger how each one got there: where it last stood, how long before, how fast, and whether the ground under it was built (through solid ground, a physics bug) or not (off the edge of the loaded world).

## 2026-11-07

- **A source's distances can change while running.** `TerrainNavFeeder` remakes a source's nav interest when its `nav_distance` or `load_distance` changes; moving the old interest kept its old size, so a change did nothing (from the audit of 6df1464).
- **Terrain and nav split apart.** `WorldCoordinator` puts a terrain, a streamer and a nav feeder together, and builds nothing itself. `TerrainNavFeeder` (first called `WorldNavLink`) feeds nav from a terrain's `chunk_built` and `chunk_removed`, announces its markers, and keeps nav built around streaming sources (moved here from the streamer). Its parts were renamed so each name says what it does: `terrain`, `streamer` and `nav_link` became `terrain_generator`, `chunk_streamer` and `nav_feeder`.
- Nav takes the terrain as a mesh, not a heightmap: heightmap input needs a regular grid, which jitter breaks, and fills each column solid. Measured on 25 chunks of 1 m squares (2026-11-05): the first build about the same (95 ms against 90), a rebuild after an edit about twice as long (17 ms against 8).
