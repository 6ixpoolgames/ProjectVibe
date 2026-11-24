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

**Compare two recordings.** `python tools/determinism/compare_replays.py A.pbreplay B.pbreplay` (or `--latest`, the two newest headless ones) names the first tick where they differ, which pawn and which field, with both values, then how many ticks and pawns differ in all. `--sessions 3 --size 100 --ticks 3600` plays the mass battle in 3 separate headless sessions first, so it checks determinism across sessions from the replays alone (state store spec 13.11). It compares what the recording keeps: positions to the millimetre, yaw and velocity as half floats, flags, input and events.

**Read a recording in code.** `var reader := ReplayReader.new()`, `reader.open(path)`, then `reader.get_frame(tick)` and `reader.get_events(from, to)`.

## How it works

**The file** (`.pbreplay`, little-endian): the magic `PBRP`, the format version (u16, raised when the file layout changes), the header's byte count (u32), then the header as one Dictionary (`var_to_bytes`: `tick_rate`, `first_tick`, `role`, `started`, `game`, `block_seconds`, and `channels`, a list of id, name and version). After it come blocks, one per `block_seconds` of ticks. Each block is stored as raw size (u32), compressed size (u32) and zstd bytes. Raw, a block is: first tick (u32), tick count (u16), channel count (u16), then per channel its id (u16), byte count (u32) and its ticks, each as tick (u32), byte count (u32) and the channel's bytes. A block's first tick is a keyframe, so a reader decodes one block to show any tick. Channels have their own versions (the motion channel is at 2 and still reads 1), and a reader skips a channel it has no class for. Each block is flushed as it is written, so a crash keeps everything before it.

**Replay ids.** A pawn's id in the file is its `NetworkEntity` id where it has one (the same on every machine), else a local id from 2^30 up. Ticks only go up in a file: a client's clock jumping back is skipped until it passes.

**The writer thread** only touches its queue (behind a mutex) and the file, and sleeps until a block arrives. It is not a job scheduler worker, because a slow disk there would hold up a tick.

**Safeguards** stop a recording with a warning and leave the file readable: `max_recording_seconds`, `max_file_megabytes`, `min_free_megabytes` (checked at the start and every minute), `max_folder_megabytes` (the oldest recordings go first, never the one being written; a file another instance has open is skipped), and the writer's queue (`max_queued_blocks` waiting, or a failed write). 0 switches a limit off. `get_stopped_reason()` says which one fired.

**What each channel writes.** Motion (1, version 2): column by column per tick (ids, position changes in whole millimetres, yaws, velocities, flags), zstd shrinks columns of similar numbers far better than mixed records; it is packed in C++ (`ReplayMotionPacker`) when the library is loaded, with the same bytes as the GDScript. Input (2): 20 bytes per changed pawn. Spawns (3), world (4), gameplay (5) and diagnostics (6) are event channels: a snapshot on a keyframe, then events.

**Gameplay events** (data in brackets): `hit` (attacker, ability, damage), `hit_intercepted` (by, interceptor), `died` (killer), `ability_started` (ability), `ability_cancelled` (ability, by), `step_started` (ability, step), `step_finished` (ability, step, reason: done, failed or cancelled), `ai_state`, `ai_behaviour` and `ai_target` (from, to, reason), `frozen` and `unfrozen` (the AI switch-off), `possessed` and `released` (peer), `fell` (report). Replay ids are 0 for none.

**The viewer.** Space plays; arrows step (Shift: ten); Home and End jump; `+` and `-` change speed; `[` `]` pick a pawn, F follows it, L toggles labels (on at the start with 40 pawns or fewer); right-drag turns the camera, the wheel zooms, WASD moves it. Ghosts take their team's colour, grey and lying down when dead, pale blue when frozen, darker when sleeping. Labels list flags as letters: G grounded, D dead, F frozen, S sleeping, C keeps chunks loaded, P player-controlled. With the diagnostics channel, a strip above the slider shows the slowest frame per column (blue to about 1/60 s, orange to 1/30 s, red beyond); click to jump, and the panel shows that tick's frame and costliest scopes.

## Settings worth knowing

| Setting | Where | Default | What it does |
|---|---|---|---|
| `enabled` | `ReplayRecorder` | on | Off: `start_recording()` does nothing |
| `folder` | `ReplayRecorder` | `user://replays` | Where recordings go, a folder per role |
| `keep_recordings` | `ReplayRecorder` | 100 | Recordings kept per role's folder; 0 keeps all (and skips the folder size limit) |
| `block_seconds` | `ReplayRecorder` | 1 s | Block length: shorter seeks faster, longer makes smaller files |
| `headless_runs_apart` | `ReplayRecorder` | on | Tests and dedicated servers record into `headless/`, so they never push out played games |
| `max_recording_seconds` | `ReplayRecorder` | 3 hours | A recording stops at this length |
| `max_file_megabytes` | `ReplayRecorder` | 2048 | A recording stops at this file size |
| `min_free_megabytes` | `ReplayRecorder` | 1024 | No recording with less disk space than this |
| `max_folder_megabytes` | `ReplayRecorder` | 4096 | Old recordings are deleted to keep a role's folder under this |
| `use_cpp_packing` | `ReplayMotionChannel` | on | Packs motion in C++ when the library is loaded |

## Tests

`replay/tests/replay_selftest`: recording through the writer thread and reading back motion, input, spawns, chunks and sources, gameplay events, keyframes, a file cut short, an unknown channel, pruning old recordings, and the C++ and GDScript motion packing giving the same bytes. `diagnostics/tests/diagnostics_selftest` covers the diagnostics channel. Run them with `bash tools/run_tests.sh replay`.
