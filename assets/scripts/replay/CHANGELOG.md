<!-- Written by Claude (claude-opus-5-5), 2026-11-17: the replay system's running changelog (the owner's call: history leaves the
code comments and lives here, next to the code). Newest first. Add an entry with every change; code comments say what the code does
now, this says how it got here and why. -->

# Replay changelog

Replay is this folder: `ReplayRecorder`, `ReplayWriter`, `ReplayReader`, `ReplayViewer` and the channels (`ReplayChannel` and the classes extending it), plus the viewer's scene `assets/scenes/replay/replay_viewer.tscn` and the C++ `ReplayMotionPacker` (`native/src/`). Design: [docs/replay/REPLAY_SPEC.md](../../../docs/replay/REPLAY_SPEC.md). Overview: [README.md](README.md).

## Refactor candidates

Code that works but doesn't yet fit the project's goals (reusable, extensible, efficient, designer friendly). Each is marked `REFACTOR:` in the code. Sizes are rough: S an hour or two, M a day, L more.

| What | Where | Why | Size |
|---|---|---|---|
| One list of the base's channels | `ReplayRecorder._init`, `ReplayReader._init` | The same list is written out twice (the recorder's without diagnostics, which `DiagnosticsManager` adds). One static list on `ReplayChannel` is one place to add a base channel | S |
| A public way to read a block's ticks | `ReplayViewer._fill_strip` | The viewer reads `ReplayReader._blocks`, the reader's private data. A `get_block_ticks(index)` keeps the reader free to change how it stores blocks | S |
| An index of blocks | `ReplayReader.open` | Opening reads the whole file into memory and decompresses every block once just to learn its ticks. At mass-battle sizes (about 160 MB an hour) a long recording is slow to open and heavy to hold; an index (at the end of the file, or a block header outside the compression) would fix both | M |

## 2026-11-22

- **Comparing recordings** (the owner's request: judge determinism across separate sessions from their replays): `samples/tests/replay_compare.tscn` reads two recordings with `ReplayReader` and names the first tick, pawn and field that differ (pawns, their motion and input, and events other than diagnostics), then the totals; `--latest=FOLDER --count=N` compares the newest N, each with the oldest. `tools/determinism/compare_replays.py` runs it, on two files, the newest recordings, or after playing the mass battle in N separate headless sessions (`--sessions`). The mass battle sample takes `--team-size`, `--quit-after-ticks` and `--no-load-ladder` for those sessions.

## 2026-11-18

- **Comments rewritten to the reference style** (the documentation pass): class comments cut to a summary and a short paragraph, member comments to a line, `GDScript note:` and "the owner's call" wording removed. The gameplay events' data, the file layout, the writer thread, the safeguards and the viewer's keys and colours moved to a new "How it works" section of the README. Stale comments fixed: `ReplayReader.get_header` and the header comment now list `first_tick` and `block_seconds` too.

## 2026-11-17

- **Hits a HitInterceptor stopped** go into the gameplay channel as `hit_intercepted` (by, interceptor), pawn spec 8.23.
- **The AI's parts through its context.** The gameplay channel reaches the AI's state manager, behaviour manager and target selector through `pawn.ai_context`, after the audit moved them there.
- **Motion packing in C++** (the C++ bundle, stage 3). `ReplayMotionChannel` gathers each pawn's values and `pack_lists` packs them in C++ (`ReplayMotionPacker`) when the library is loaded, with the same bytes; `use_cpp_packing` off, or no library, packs in GDScript as before. The packer forgets pawns as they leave.
- **Comments cleaned up** for the documentation pass: dated notes moved here, doc comments in Godot's markup. Fixed on the way: `ReplayEntityChannel` said three overrides where there are four, and that the reader drops a gone pawn's record (it keeps it, and only lists pawns the spawns channel has); the world channel's source events and snapshot described "on/off" states it no longer records; the gameplay channel's list lacked `hit_intercepted`; `add_channel` said the base's ids are 1 to 5 (1 to 99, with diagnostics at 6); the diagnostics channel said it's filled only in debug builds (diagnostics ship in release too); `keep_recordings` 0 also skips the folder size limit, now said.

## 2026-11-16

- **Safeguards** (the owner asked that recording can never run away): `max_recording_seconds` (3 hours), `max_file_megabytes` (2 GB), `min_free_megabytes` (1 GB, checked every minute), `max_folder_megabytes` (4 GB, oldest deleted first, never the file being recorded or one another instance has open), and the writer's queue (`max_queued_blocks`, 60 blocks, raised from 30 at the owner's call). Each stops the recording with a warning (`get_stopped_reason`); after a failed write the writer writes nothing more.
- **Diagnostics in the replay.** Channel 6, `ReplayDiagnosticsChannel`, holds each frame's timings and scopes, warnings and captures (filled by `DiagnosticsManager`). The reader gives `frame.diagnostics` and `get_diagnostics()`, and the viewer shows a strip of the slowest frames above its slider; click it to jump there. The panel moved up to make room.
- **Headless runs apart** (the owner's call: test runs were deleting playtest recordings): runs with no display record into `folder/headless/<role>`.
- **Match options:** `enabled` is offered in a start menu (`get_match_options`).
- **The wider audit:** a tick that isn't after the last one recorded is left out, since a client's clock can jump back and the reader counts on ticks only going up (the same ticks twice gave it the wrong frames); the input channel compares and writes value by value instead of building a list three times per pawn per tick; pawns already there at the start come from `Pawn.GROUP`; `write_on_thread` left the inspector, since it's for tests.
- **The pawn rebuild:** hits and deaths come from the AbilityManager (pawn M3); input and "a player has it" from the ControllerManager (pawn M4); pawns can be chunk sources, so the world channel tracks only sources that count on this machine, and a source switched off is `source_removed` (`source_on`, `source_off` still read in old files) (pawn M2).
- **Ability steps** in the gameplay channel: `step_started` and `step_finished` (pawn spec 8.20).
- **Recording timed** for diagnostics, as the `replay.record` scope.

## 2026-11-15

- **Replay v0** (the owner's decisions the same day): `ReplayRecorder`, `ReplayWriter` on its own thread, `ReplayReader`, `ReplayViewer`, and five channels: motion, input, spawns, world and gameplay. 1 s blocks opening with keyframes, zstd-compressed; a file cut short opens up to its last whole block, and unknown channels are skipped.
- **Motion version 2** (the owner's request for better compression): positions as whole-millimetre changes since the pawn's last record, laid out field by field, so zstd packs them far better. 2.7 MB a minute at mass-battle sizes instead of 6.4. Version 1 files still read (`file_version`).
