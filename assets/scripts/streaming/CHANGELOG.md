<!-- Written by Claude (claude-opus-5-5), 2026-11-17: the streaming system's running changelog (the owner's call: history leaves the
code comments and lives here, next to the code). Newest first. Add an entry with every change; code comments say what the code does
now, this says how it got here and why. -->

# Streaming changelog

Streaming is this folder: `ChunkStreamer` and `StreamingSource`, plus the source contract that lets a `Pawn` be a source (`pawn/Pawn.gd`). Design: [docs/streaming/STREAMING_SPEC.md](../../../docs/streaming/STREAMING_SPEC.md). Overview: [README.md](README.md).

## Refactor candidates

Code that works but doesn't yet fit the project's goals (reusable, extensible, efficient, designer friendly). Each is marked `REFACTOR:` in the code. Sizes are rough: S an hour or two, M a day, L more.

None in this folder yet. Serving one terrain only is a "not yet" (streaming spec, section 7), not a refactor: more terrains, props by chunk and blended generators come with the world spec's end goal.

| What | Where | Why | Size |
|---|---|---|---|

## 2026-11-17

- **Comments cleaned up** for the documentation pass: dated notes moved here, doc comments in Godot's markup. The source contract now names all four readers (the streamer, the nav feeder, the AI switch-off and the replay), and the "how to use" steps say the `WorldCoordinator` connects the streamer and turns off `build_on_start` itself.

## 2026-11-16

- **Pawns are sources** (pawn M2, the owner's call: a flag on the pawn, the streamer holding the code). A `Pawn` no longer makes its own `StreamingSource` while possessed or while `ai_loads_chunks` was on; it's a source itself, through the source contract written in `StreamingSource.gd`, and the streamer reads any `Node3D` in the group. A pawn is in the group only while it might keep the world loaded, so the group holds the few sources, not every pawn (the wider code audit).
- **One ground check a tick.** With a TickDriver, only the check before each tick runs; the per-physics-frame one is for a scene without a driver. Both used to run every physics frame (the wider code audit).
- **Timed for diagnostics:** the ground check and the chunk work report to `PerfScopes` (diagnostics v0).

## 2026-11-07

- **Multiplayer streaming.** `StreamingSource.counts_on_this_machine()`: on the server or offline every source counts; on a client only its own pawn's, since a pawn exists on every machine. The chunk limit is per source (`max_chunks_per_source`), not one total: at the defaults a source wants about 37 chunks, so a total of 256 ran out at about 7 players far apart.
- **The ground guarantee.** The chunks under a source, or about to be, are built at once before each tick, after a snapshot may have moved a pawn (`process_physics_priority` -200, before TickDriver's -100). It replaced the rule that a pawn over a missing chunk held still: the ground is generated first (the owner's rule). After a rollback the check runs again.
- **Nav moved out.** Keeping nav built around sources moved from the streamer to `world/TerrainNavFeeder`, when terrain and nav split apart. Systems renamed so each name says what it does.

## 2026-11-06

- **`ChunkStreamer` and `StreamingSource`**: chunks load around active sources, nearest first, a few milliseconds a frame (`max_ms_per_frame`), and unload past `load_distance + unload_margin`. `nav_distance` is separate from `load_distance` because nav has about 100 tiles per chunk at 128 m. Performance target: the bottom third or so of Steam machines (streaming spec, section 2).
