# Replay Spec v0.1 (replay v0, being built)

*Written by Claude (claude-opus-5-5), 2026-11-15, from the owner's decisions the same day.*

**Status:** v0 agreed and being built. **What v0 is for:** debugging tier 0, such as recreating a pawn falling through the floor. **What it grows into:** the full replay feature. So v0 records only the data points t0 debugging needs, in a file layout that later features add to without breaking.

## 1. Decided

| Question | Answer | Whose call |
|---|---|---|
| What's recorded | Every pawn, AI ones included: position, facing, velocity, flags (grounded, dead, frozen, sleeping, has a chunk source, has a player). Their **inputs**. Spawns and despawns. Chunks built and removed, and the chunk sources. Gameplay events: hits, deaths, abilities, AI state and behaviour changes, freezes, possession, kill floor reports | the owner |
| How often | Every tick, at the TickDriver's tick rate | the owner |
| When it starts | When the game starts: on the host when the player picks Offline or Host, on a client when Join has connected. It stops when the session ends | the owner |
| Where files go | `user://replays/host/` (host and offline) and `user://replays/client/`, kept apart. The newest 10 of each are kept. *Claude 2026-11-16: runs with no display (tests, dedicated servers) use `user://replays/headless/host/` and `.../client/`, with their own 10, so test runs don't push out played games (`headless_runs_apart`)* | the owner: "sensible default saves, host and client folders separate" |
| Physics | Keyframes correct any drift, so no deterministic physics of our own for now. Revisit when a game truly depends on physics | the owner |
| Writing to disk | On a thread of its own, not one of the job scheduler's workers: those run work a tick waits for, and a slow disk would hold ticks up | the owner asked; Claude's design |

## 2. The file

The layout every game replay uses, Unreal's included: a header, then **blocks**, each opening with a **keyframe** (everything as it is) followed by only what changed. Seeking to any moment means finding its block and reading forward from its keyframe, so nothing before that block is needed.

```
File:   header, then blocks until the end of the file
Header: "PBRP", format version (u16), header length (u32), then the header fields as one put_var Dictionary:
        tick_rate, first_tick, role ("host" or "client"), started (date and time), game (project name and version),
        channels: [{id, name, version}, ...]
Block:  raw size (u32), compressed size (u32), the block compressed with zstd
        Inside, uncompressed: first tick (u32), tick count (u16), channel count (u16), then for each channel:
        channel id (u16), byte count (u32), the channel's bytes
        A channel's bytes: for each tick: tick (u32), byte count (u32), that tick's data. The first tick is the keyframe.
```

- **Every block is complete on its own.** A crash, or a game killed mid-write, loses only the block being written: the reader stops at the first block that's cut short.
- **Unknown channels are skipped** by their byte count, so a newer game's file still opens in an older viewer, and a game's own channels never break the built-in ones.
- **Little-endian**, the order every target machine uses.

## 3. Channels

A channel is one kind of data, with an **id**, a **name** and a **version** in the header. Adding data later means adding a channel, or raising a channel's version and reading both versions. v0 has five:

| Id | Channel | Each tick | On a keyframe |
|---|---|---|---|
| 1 | `motion` | pawns whose state changed since their last record, laid out field by field: ids, position changes in whole millimetres (3 × i32, since that pawn's last record), yaws (half), velocities (3 × half), flags (u8). *Version 2 (2026-11-15); version 1 (whole f32 positions, record by record) is still read* | every pawn, with whole positions |
| 2 | `input` | pawns whose input changed: move input (3 × half), look yaw and pitch (half), held actions (u64), view ticks behind (half) | every pawn |
| 3 | `spawns` | spawned (id, name, scene, team) and despawned (id) | every live pawn |
| 4 | `world` | chunk built or removed, per terrain | every terrain (chunk size, origin) and its built chunks, and every chunk source (position, load and nav distances, on or off) |
| 5 | `gameplay` | events: hit, died, ability started, ability cancelled, AI state, behaviour and target changes, frozen, unfrozen, possessed, released, fell (the kill floor's report) | nothing: events are moments, not state |
| 6 | `diagnostics` *(2026-11-16, diagnostics v0)* | the frames that finished since the last tick: their times, physics steps, drawing, counts, and timing scopes; events for scope names, warnings and errors, and captures. Filled by the DiagnosticsManager in debug builds (docs/diagnostics/DIAGNOSTICS_SPEC.md) | the scope names so far |

**Pawn ids** are their `NetworkEntity` id where they have one, which is the same on every machine, so a host's file and a client's file can be compared pawn by pawn. Pawns that aren't networked get ids from 2^30 up, handed out by the recorder.

**"Changed" is exact:** a pawn whose record is the same as last tick, such as a sleeping or frozen one, writes nothing until the next keyframe. zstd then shrinks what's left.

## 3.1 Safeguards *(2026-11-16, the owner's request)*

A recording can never run away, outnumber the cap, or grow without limit. Each safeguard stops the recording with a warning saying why (`ReplayRecorder.get_stopped_reason()`), and the file stays readable up to there:

| Setting | Default | What it does |
|---|---|---|
| `max_recording_seconds` | 10800 (3 hours) | A recording stops at this length |
| `max_file_megabytes` | 2048 | A recording stops when its file reaches this size |
| `min_free_megabytes` | 1024 | A recording doesn't start, or stops, with less disk space than this. Checked every minute |
| `keep_recordings` | 10 | Recordings kept in each role's folder |
| `max_folder_megabytes` | 4096 | Old recordings are deleted, oldest first, to keep a role's folder under this. The file being recorded is never deleted, and one another instance has open is skipped |
| `max_queued_blocks` | 60 (about a minute; was 30, raised 2026-11-16) | If the disk falls this far behind, the recording stops rather than filling memory. After a failed write, the writer writes nothing more |

## 4. Classes (`assets/scripts/replay/`)

| Class | What it does |
|---|---|
| `ReplayRecorder` | A `GameMode` module (`GameMode.replay_recorder`). `start_recording(role)` and `stop_recording()`. Finds pawns as they enter and leave the tree, gives each a replay id, and once a tick (TickDriver's `after_tick`, which never fires during a rollback replay) asks each channel for that tick's bytes. Closes a block every `block_seconds` and hands it to the writer |
| `ReplayWriter` | The file and the thread. Takes finished blocks, and on its own thread compresses each with zstd and writes it. `close()` writes whatever is left and waits for the thread |
| `ReplayChannel` | The base for channels: id, name, version, and the calls a recorder makes (`begin`, `write_tick`, `end`) and a reader makes (`read_tick`) |
| `ReplayEntityChannel` | A channel of one fixed record per pawn, written for pawns whose record changed, and for all of them on a keyframe. `ReplayMotionChannel` and `ReplayInputChannel` extend it |
| `ReplayEventChannel` | A channel of events, each a kind, a pawn id and a Dictionary of plain values. `ReplaySpawnChannel`, `ReplayWorldChannel` and `ReplayGameplayChannel` extend it |
| `ReplayReader` | Opens a file, reads the header and every whole block, and gives the state at any tick: each live pawn's motion and input, the chunks and sources, and the events up to it |
| `ReplayViewer` | `assets/scenes/replay/replay_viewer.tscn`: opens the newest recording (or `-- --file=`), plays and scrubs it, and shows ghost capsules, chunk outlines, sources and the events |

## 5. Sizes and costs

About 25 bytes per pawn per tick for motion before compression, and less for input, which changes less. Pawns that don't change write nothing.

**Measured, 2026-11-15** (the owner's PC, headless, offline):
- `replay_selftest`, 3 to 4 pawns: about 11 bytes a pawn a tick on disk.
- `mass_battle_measure -- --size=50` (153 pawns marching and fighting), 100 s with and without `--no-record`: the file grows **6.4 MB a minute** (about 380 MB an hour). Recording costs **about 0.85 ms a tick** (the "other" column, which holds TickDriver's after_tick: 1.05 ms against 0.21), about 5% of a 60-a-second tick, and the physics frame rose by about 1 ms. Nothing else changed.
- So at mass-battle sizes, packing in GDScript is the cost to watch; moving it to C++ (6, last point) is the fix if it's needed.

**Motion version 2, measured the same way, 2026-11-16** (the owner's request for better compression): positions as millimetre changes, laid out field by field. The file grows **2.7 MB a minute** (about 160 MB an hour), 2.4 times smaller than version 1, and recording costs **about 0.65 ms a tick**, a little less than before. Raising zstd's level from Godot's default (3) to 9 shrank it only another 3% (2.6 MB a minute), so the level stays at the default: it's a project-wide setting, and not worth changing for that.

## 6. Later

- Driving the real toy figures from a recording instead of ghosts (the modular animation work keeps visuals reading only recorded state).
- A re-simulation check: replay inputs from a keyframe and measure how far physics drifts, before deciding anything about deterministic physics.
- Rebuilding the terrain in the viewer from the level's settings.
- The AI debug timeline reading from the recorder, so there's one recording, not two.
- Moving the per-tick packing to C++ (from the pawn table) if it costs too much at mass-battle sizes.
