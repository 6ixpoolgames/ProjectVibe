<!-- Written by Claude (claude-opus-5-5), 2026-11-17: the replay system's overview, beside its code. -->

# Replay

Records every pawn every tick to a file while the game runs, and plays it back as ghosts, so you can see exactly what happened (a pawn walking off loaded ground and falling, say).

**Status:** built, tier 0 (replay v0, for debugging). Not yet: driving the real figures from a recording, re-simulating from inputs, rebuilding the terrain in the viewer, and the AI debug timeline reading from it.

| File | What it's for |
|---|---|
| [README.md](README.md) | This overview: what's here and how to use it |
| [REFERENCE.md](REFERENCE.md) | Every class, setting and function, generated from the code's doc comments (`python tools/docs/make_reference.py replay`) |
| [CHANGELOG.md](CHANGELOG.md) | What changed and why, newest first, and the refactor candidates |
| [REPLAY_SPEC.md](../../../docs/replay/REPLAY_SPEC.md) | The full design: file layout, channels, safeguards, sizes |

## The pieces

```
 the game                         recording                                  the file
 ────────                         ─────────                                  ────────
 pawns, terrain, sources ──► channels (motion, input, spawns, ──► ReplayRecorder ──► ReplayWriter ──► .pbreplay
 abilities, AI, kill floors       world, gameplay, diagnostics)   (once a tick)     (own thread, zstd)
                                                                                         │
 ReplayViewer (ghosts, outlines, events) ◄── ReplayReader (state at any tick) ◄──────────┘
```

- **`ReplayRecorder`** is a GameMode module (`GameMode.replay_recorder`). Once a tick it gives new pawns a replay id and asks each channel for that tick's bytes. Every `block_seconds` (1 s) it closes a block, which opens with a keyframe, and hands it to the writer.
- **`ReplayWriter`** compresses each block with zstd and writes it on a thread of its own, so ticks never wait for the disk.
- **Channels** are the kinds of data, each with an id, a name and a version. `ReplayChannel` is the base; `ReplayEntityChannel` (a record per pawn: `ReplayMotionChannel`, `ReplayInputChannel`) and `ReplayEventChannel` (events: `ReplaySpawnChannel`, `ReplayWorldChannel`, `ReplayGameplayChannel`, `ReplayDiagnosticsChannel`) build on it. The same class writes and reads its bytes.
- **`ReplayReader`** opens a file and gives the state at any tick: each live pawn's motion and input, chunks and sources, and events.
- **`ReplayViewer`** (`assets/scenes/replay/replay_viewer.tscn`) plays and scrubs a recording.

It works with `TickDriver` (its `after_tick` signal, which never fires during a rollback replay), the `diagnostics/` folder (`DiagnosticsManager` adds channel 6 and starts recordings when play starts), and `PerfScopes` (recording is timed as `replay.record`).

## How to use it

**Record a game.** The recorder is listed in the project setting `project_base/game_mode/modules`. Call `GameMode.replay_recorder.start_recording("host")` (or `"client"`) when play starts; the samples do, and `DiagnosticsManager` starts one if nothing else has. It stops when the game closes, or with `stop_recording()`.

**Watch a recording.** Open `replay_viewer.tscn` and run it: it opens the newest recording in `user://replays/host`. `-- --client` picks the client folder, `-- --file=<path>` one file. Space plays, ← → step, `[ ]` pick a pawn, F follows it, L shows labels.

**Turn recording off for a match.** Untick `enabled` on the recorder, or in the start menu's match options.

**Record your own data.** Extend `ReplayEventChannel` (for events) or `ReplayEntityChannel` (for a record per pawn), give it an id of 100 or more, and add it before recording starts:
```gdscript
GameMode.replay_recorder.add_channel(MyChannel.new())
```
Add it to the reader too (`ReplayReader.add_channel`) to read it back; a reader without it skips its bytes.

**Read a recording in code.** `var reader := ReplayReader.new()`, `reader.open(path)`, then `reader.get_frame(tick)` and `reader.get_events(from, to)`.

## Settings worth knowing

| Setting | Where | Default | What it does |
|---|---|---|---|
| `enabled` | `ReplayRecorder` | on | Off: `start_recording()` does nothing |
| `folder` | `ReplayRecorder` | `user://replays` | Where recordings go, a folder per role |
| `keep_recordings` | `ReplayRecorder` | 10 | Recordings kept per role's folder; 0 keeps all (and skips the folder size limit) |
| `block_seconds` | `ReplayRecorder` | 1 s | Block length: shorter seeks faster, longer makes smaller files |
| `headless_runs_apart` | `ReplayRecorder` | on | Tests and dedicated servers record into `headless/`, so they never push out played games |
| `max_recording_seconds` | `ReplayRecorder` | 3 hours | A recording stops at this length |
| `max_file_megabytes` | `ReplayRecorder` | 2048 | A recording stops at this file size |
| `min_free_megabytes` | `ReplayRecorder` | 1024 | No recording with less disk space than this |
| `max_folder_megabytes` | `ReplayRecorder` | 4096 | Old recordings are deleted to keep a role's folder under this |
| `use_cpp_packing` | `ReplayMotionChannel` | on | Packs motion in C++ when the library is loaded |

## Tests

`replay/tests/replay_selftest`: recording through the writer thread and reading back motion, input, spawns, chunks and sources, gameplay events, keyframes, a file cut short, an unknown channel, pruning old recordings, and the C++ and GDScript motion packing giving the same bytes. `diagnostics/tests/diagnostics_selftest` covers the diagnostics channel. Run them with `bash tools/run_tests.sh replay`.
