<!-- Written by Claude (claude-opus-5-5), 2026-11-06: what chunk streaming does, the performance target it's measured against, and what's left. -->

# Chunk Streaming

**Status:** built for one terrain, offline and in multiplayer, with edits that outlast their chunks and reach every machine. Edits aren't saved to a file yet.

## 1. How it works

| Part | Job |
|---|---|
| `StreamingSource` | A node that says "keep the world loaded around me". Add it as a child of a pawn or a camera. "Streaming source" is the usual engine term. |
| `ChunkStreamer` | Finds the active sources, loads chunks near them and unloads the rest, within a time budget per frame. |
| `Terrain` | Builds one chunk in small steps (`build_chunk_step`), or removes one (`unload_chunk`). With `build_on_start` off, it starts empty. |

**The trigger rule, from the owner:** a player controller keeps the world loaded by default, and an AI controller needs a bool. The source is its own node instead of a setting on the controller, so things with no pawn controller can use it, such as an RTS camera or a spectator. `StreamingSamplePawn` shows the rule. The real controllers don't have it yet, because the owner is still thinking about the pawn.

**Distances are in metres,** measured to a chunk's nearest edge, so changing chunk size doesn't change how far the world reaches. A chunk loads within `load_distance` and unloads past `load_distance + unload_margin`, so hovering around the line doesn't rebuild it.

**Nav has its own, shorter distance,** `nav_distance`. Nav tiles are 12.8 m, so 320 m would mean about 2,000 tiles per source.

**The ground guarantee:** the chunks under a source, and any it could step into before the next check, are built immediately, right before each tick and before any rollback replay, ignoring the budget. A pawn with a source never has a tick without ground, even on its first or after a teleport. Measured: a new chunk is solid in the same physics frame it's built. Speed isn't a limit in practice: about 75 chunks a second on the test PC, or 25 on the slowed CPU, which is about 1,600 m/s or 530 m/s at 320 m load distance.

**AI with no source** gets switched off by `AIActivityModule` before reaching ground that isn't there (`game_mode/`). Nothing in the motor deals with missing ground. A later layer can simulate those pawns out of sight, using its `ai_deactivated` and `ai_activated` signals.

## 2. Performance target

**The bottom third or so of Steam machines, as asked for by the owner on 2026-11-06.** The Steam survey doesn't report "bottom third" directly, so this is an estimate: about 4 to 6 older cores, 8 to 16 GB, and an entry-level graphics card. The most common machine in the October 2026 survey has 16 GB and an RTX 3060, and the most common CPUs in the last figures found (July 2026) have 6 to 8 cores. The owner's PC, a 5900X with 32 GB and an RTX 4070 Ti, is well above all of that.

**How the stress test stands in for that machine,** both assumptions and not measurements:
- `simulate_slower_cpu`, on the test-only `SlowChunkStreamer`, makes the streamer's work take 3 times as long. It really uses the time, so budgets and frame rates react as they would.
- Nav builds on 3 background threads.

**The limits:** the ground under a source is always built, and the streamer's worst frame stays within 8 ms, about half a 60 fps frame.

**What this can't show:** the graphics card, physics or nav on a slower CPU, and everything else a real game is doing. Only a real low-end machine can answer those, and none has been tried.

## 3. Measured

Windows, Godot 4.7.2, a 5900X, 2026-11-06. Every row has collision and nav on, a 60 fps cap, `load_distance` 320 m, `nav_distance` 96 m, and a 2 ms budget, for 8 seconds of moving. No row had a frame over 20 ms or a moment without ground under a source. Target rows are walk and vehicle at x3.

| CPU | Chunk | Scenario | Start-up | Worst frame | Worst step | Average frame | Chunks loaded |
|---|---|---|---|---|---|---|---|
| x1 | 256 m | walk 8 m/s | 0.6 s | 2.39 ms | 2.38 ms | 0.02 ms | 1 |
| x1 | 256 m | vehicle 40 m/s | 0.6 s | 2.96 ms | 2.39 ms | 0.08 ms | 5 |
| x1 | 128 m | vehicle 40 m/s | 0.4 s | 2.34 ms | 0.66 ms | 0.07 ms | 16 |
| x1 | 64 m | vehicle 40 m/s | 0.4 s | 2.13 ms | 0.38 ms | 0.09 ms | 58 |
| x3 | 256 m | walk 8 m/s | 1.3 s | 6.91 ms | 6.91 ms | 0.06 ms | 1 |
| x3 | 256 m | vehicle 40 m/s | 1.3 s | 7.03 ms | 7.02 ms | 0.24 ms | 5 |
| x3 | 256 m | 8 players | 9.9 s | 7.09 ms | 7.08 ms | 0.22 ms | 4 |
| x3 | 256 m | fly 200 m/s | 1.3 s | 8.84 ms | 7.39 ms | 1.14 ms | 24 |
| x3 | 128 m | walk 8 m/s | 1.1 s | 3.44 ms | 1.79 ms | 0.04 ms | 1 |
| x3 | 128 m | vehicle 40 m/s | 1.1 s | 3.88 ms | 2.07 ms | 0.21 ms | 15 |
| x3 | 128 m | 8 players | 9.1 s | 4.21 ms | 2.08 ms | 0.42 ms | 18 |
| x3 | 128 m | fly 200 m/s | 1.1 s | 3.56 ms | 1.84 ms | 0.94 ms | 80 |
| x3 | 64 m | vehicle 40 m/s | 1.3 s | 2.76 ms | 1.07 ms | 0.27 ms | 57 |
| x3 | 64 m | 8 players | 3.6 s | 11.77 ms | 0.83 ms | 1.00 ms | 52 |
| x3 | 64 m | fly 200 m/s | 1.3 s | 2.58 ms | 0.77 ms | 1.12 ms | 287 |

**Reading it:**
- **Chunk size mostly sets the worst single step.** Collision can't be split, so its cost lands in one frame. At x3 that's about 7 ms at 256 m and 2 ms at 128 m. Average cost per area is about the same at any size.
- **128 m is the most comfortable at the target,** so the owner made it `Terrain`'s default, with `chunk_resolution` 21, on 2026-11-06.
- **64 m with 8 players went over the limit,** at 11.77 ms. That's most likely the refresh, which isn't split and has the most chunks to score there. It's not a target row. Traced by reasoning only.
- **Start-up with no loading screen takes seconds with 8 players,** because 2 ms a frame is a low budget. A loading screen could raise `max_ms_per_frame` while it's up.

**Memory:** about 470 KB per 256 m chunk, 122 KB per 128 m chunk and 43 KB per 64 m chunk, from Godot's static memory counter in a headless run. So it doesn't include graphics memory, and may not include all of physics.

**What one 256 m chunk costs now,** on this machine:

| Stage | Before | After |
|---|---|---|
| Points | 2.31 ms | 2.36 ms, split |
| Mesh | 6.33 ms with `SurfaceTool` | 1.91 ms with arrays: 1.24 ms split, then a 0.67 ms final step |
| Collision | 2.07 ms | 2.22 ms, can't be split |
| **Total** | **10.7 ms** | **6.5 ms** |

`generate()` and `edit()` use the same code, so a chunk generates in 6.3 ms and an edit rebuilds one in 4.0 ms, down from 10.7 ms and 8.4 ms. On Linux (WSL2) they're 5.4 ms and 3.7 ms, and all the streaming, stitching and terrain tests pass with the same terrain fingerprints as Windows. The stress test and the real-renderer run were on Windows only. The mesh's vertices, normals, UVs and indices are identical to `SurfaceTool`'s, checked by fingerprint on flat and smooth shading.

**With the real renderer,** the first chunk has one step of 22 to 29 ms. After that, the worst step in a 34-second walk stayed under 0.8 ms, matching the headless numbers. The likely cause is the renderer preparing the terrain's shader on first use, which isn't confirmed. It would be longer on a slower machine, and belongs behind a loading screen.

About 13 frames in 180 took over 20 ms in that run, and exactly the same in the plain `terrain_sample.tscn`, so streaming isn't the cause. Not traced. It could come from the monitor's refresh or the way it was measured.

## 4. Nav across chunk borders

`streaming/tests/nav_stitching_selftest`, in six setups: 64, 128 and 256 m chunks on the nav tile grid, 64 and 128 m off it, and 100 m, which doesn't divide evenly into tiles.

- **Hops:** 98 short paths across chunk borders in each setup, 588 in all. None failed. The same hops inside chunks failed 0 or 1 in 98, where the ground was too steep.
- **Long paths** across several chunks, including through the point where four chunks meet, for the smallest and largest pawn sizes: all reach nav's nearest point to the target, nearly straight, and with nav under them the whole way.
- **Load order:** four chunks loaded one at a time in four different orders, letting nav finish in between, gave **exactly the same nav triangles** as loading all four together.
- **Unloading:** with one side missing, no path crosses. When it loads, one does. When it unloads, the crossing stops and the side that stayed keeps working. When it reloads, the path is the same length.
- **An edit on a border** moves both chunks' shared points, and nav goes around it.
- **A pawn following nav** walked 330 m across 7 chunks while the streamer loaded them, never waiting for nav, and tiles behind it unloaded.

**Two things this showed:**
- **A path's height between corners isn't the ground.** Detour only gives corners where a path turns, so the straight line between two can pass through a hill by several metres, though it's right seen from above. A path follower has to walk on the ground and take only the direction from the path. This matters for the navigation manager in the pawn spec.
- **Nav leaves small holes on the default terrain,** where a jittered triangle is steeper than 45°. A target on one gets the nearest walkable point instead, up to about 3 m away for a large pawn. It's correct, and worth knowing when placing things on terrain.

## 5. Multiplayer

*Added 2026-11-07.* Each machine runs its own `ChunkStreamer`. No terrain is sent over the network, because the same settings build the same ground everywhere, and the handshake's content check already covers those settings.

| Machine | Loads chunks around |
|---|---|
| Server | Every player's pawn, plus any AI pawn whose bool is on |
| Client | Its own pawns only |
| Offline | Every active source |

- **How a source knows:** `StreamingSource.counts_on_this_machine()` reads the `NetworkEntity` of whatever it's attached to. On the server's role (authority) it counts, on a client's own pawn it counts, and on anyone else's pawn it doesn't. No setup is needed, and something that isn't networked, such as a camera, always counts.
- **The limit grows with players:** `max_chunks_per_source` replaces one total. At the defaults a source wants about 37 chunks, so a total of 256 would have run out at about 7 players spread far apart.
- **No meshes on a machine nobody looks at:** `build_meshes` off skips them, and a build exported with Godot's `dedicated_server` feature never builds them. Measured at 256 m, a mesh was about 1.9 ms of 6.5 ms.
- **Spawning:** a server has no ground yet at a far-away spawn point, so it builds that chunk first to find the height.
- **Machines build chunks at different moments,** so each one relies on its own ground guarantee, and a correction that moves a pawn gets its ground before the replay runs.
- **Another player's pawn** can be somewhere a client has no ground. It's drawn from snapshots, so it doesn't need any.
- **When everyone has left,** the server keeps the last chunks loaded, because `hold_when_no_sources` is on by default. A server that should empty itself turns it off.

**Tests:** `streaming/tests/net_streaming_selftest`, real connections between separate processes, on Windows and Linux. Clients 1 km apart each hold only their own area while the server holds both, all ground matches by fingerprint, a late joiner and a leaving player work, no pawn with a source ever ticks without ground, including after a 3 km teleport under 100 ms of lag, AI goes off at the edge, edits reach every client and late joiner with exactly matching ground, and raising the ground around 12 pawns drops none of them.

**Stress, measured 2026-11-07 on Windows,** in `net_stress`: 5 clients at 20 to 200 ms with 4 pawns each, and 20 AI pawns, 30 seconds a run, one run of each. Streaming used 320 m and 96 m for nav, with the AI's bool on.

| | Fixed block | Streamed |
|---|---|---|
| Own pawn error, average across clients | 0.1 to 1.7 cm | 0.0 to 1.8 cm |
| Worst single error, across clients | 51 to 171 cm | 0 to 239 cm |
| Corrections per pawn per second | 0.44 to 1.22 | 0.43 to 0.96 |
| Server frame, average / worst | 4.5 / 9 ms | 4.5 / 8 ms |
| Frames over budget | 0 | 0 |
| Pawns that fell | 0 | 0 |

These match within the noise between runs. The largest errors come from pawn contact, the same as to-do 2 in the netcode spec. The worst of 239 cm is one event in one run, so one run can't say whether it's chance. All pawns here start near the middle, so they share most of their chunks. The far-apart case was only run with 2 clients and 4 pawns.

**Not tested in multiplayer:** a real network, real low-end machines, and many players far apart under load.

## 6. C++

**Not needed for streaming at the target yet.** The streamer averages well under 1 ms a frame at x3 in the target rows, and the largest step is collision, which is mostly Godot's own work, so moving this code to C++ wouldn't shrink it.

**What C++ would help:**
- **Points and mesh rows are 3.6 ms of the 6.5 ms,** in tight GDScript loops, and they could run on background threads. No C++ version has been measured.
- **It becomes necessary for much finer terrain.** At 1 m squares a chunk has about 35 times the work, around 230 ms by estimate, even when split.
- **Constant digging** would benefit, since each edit rebuilds points and meshes.

**The catch:** `_shape_height` is a GDScript override called for every point, and calling it from C++ would lose most of the gain. So C++ would need a GDScript fallback, the way `NetCodec` has `NetPackets`, for terrains that override it. Whether `FastNoiseLite` is safe across threads is also unchecked (nav spec, section 21.11, point 5).

**Moving collision off the main thread** is a separate question, and the one that would actually lower the worst step. Not looked into.

## 7. Not done

| Item | Notes |
|---|---|
| **Saving edits to a file** | `TerrainEditLog.to_bytes` and `from_bytes` are there, and nothing writes them yet |
| **Merging long edit lists** | A chunk with 1,000 edits takes about 30 ms to build, spread across steps. Merging them into stored heights isn't built |
| **Relevancy** | Clients still receive every pawn, wherever it is (netcode spec, section 16) |
| **The real pawn** | Waits on the owner's pawn design |
| **More than one terrain, or props by chunk** | It serves one terrain |
| **Chunks ahead of a fast source** | Priority is nearest first, with no look-ahead. It hasn't been needed in these tests |
| **The refresh isn't budgeted** | It runs whole. The likely cause of the one row over the limit |
| **A real low-end machine** | Nothing has been run on one |
