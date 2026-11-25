<!-- Written by Claude (claude-opus-5-5), 2026-11-17: the diagnostics system's overview, beside its code. -->

# Diagnostics

Measures how every frame went and what it cost, keeps session logs and captures for bug reports, records the numbers into the replay, and shows on-screen panels, one key each. It ships in release builds too.

**Status:** built, tier 0 (diagnostics v0). Not yet: splitting "rest" into deferred calls, drawing and waiting, GPU timing pass by pass, clients sending their numbers to the host, and a performance baseline check.

| File | What it's for |
|---|---|
| [README.md](README.md) | This overview: what's here and how to use it |
| [REFERENCE.md](REFERENCE.md) | Every class, setting and function, generated from the code's doc comments (`python tools/docs/make_reference.py diagnostics`) |
| [CHANGELOG.md](CHANGELOG.md) | What changed and why, newest first, and the refactor candidates |
| [DIAGNOSTICS_SPEC.md](../../../docs/diagnostics/DIAGNOSTICS_SPEC.md) | The full design: what a frame is, scopes, panels, logs, captures, costs |

## The pieces

```
 any system ── PerfScopes.begin/end ──┐
 TickDriver's profile ────────────────┼─► DiagnosticsManager ─┬─► history and spikes (in memory)
 engine warnings ── DiagnosticsLogger ┘   (once a frame)      ├─► session log, captures (user://diagnostics/)
                                                              ├─► ReplayDiagnosticsChannel ─► the replay
                                                              ├─► the editor's Debugger > Monitors
                                                              └─► DiagnosticsPanels (F1...F12) ─► NavDebugView (F9)
```

- **`PerfScopes`** marks work: `begin()` and `end(name, started)`. With nothing listening it costs one true-or-false check, so the marks stay in shipping code. Scopes that run very often (one per behaviour per pawn per tick, say) use `begin_detailed()`, which only times while `PerfScopes.detailed` is on as well: F4 switches it on while it's open.
- **`DiagnosticsManager`** is a GameMode module, listed by the project setting `project_base/game_mode/modules` and its `.release` override; the base never names it. Every frame it measures physics, scripts and the rest, adds TickDriver's phases and every scope, keeps the newest frames in a ring buffer (`DiagnosticsFrameHistory`; the replay keeps the whole session) and the spikes, writes the session log, feeds the replay and the editor's monitors, and starts a replay when play starts if nothing else did.
- **`DiagnosticsLogger`** catches the engine's warnings and errors from any thread, for the log and the replay.
- **`MoveSanityCheck`**, in every build, runs after each tick (`check_moves`): from the state store alone (its first pass is `StateStore.find_long_moves`, 0.03 ms a tick at 300 pawns), it warns once about any entity that moved further than its velocity explains and didn't teleport (`Pawn.teleport`). It catches code that sets a position directly; it doesn't judge speeds.
- **`DiagnosticsPanels`** are the on-screen panels. **`ProjectileTraceView`** (F5) draws each projectile's planned path and what it met. **`NavDebugView`** draws navigation in the world (its history is in [navigation's changelog](../navigation/CHANGELOG.md)).

It works with `replay/` (channel 6, `ReplayDiagnosticsChannel`, and the viewer's strip), `TickDriver` (its profile and load ladder), `NetworkSession` (its counters and connections) and `AIActivationManager` (how many AI pawns run every tick, 2nd and 4th).

## How to use it

**See the keys.** Run any scene with the manager listed and press a key; press it again to hide.

| Key | What it shows |
|---|---|
| F1 | The keys, and the session log's name |
| F2 | Frame graph: a bar per frame, physics, scripts and the rest, with lines at 1/60 and 1/30 s |
| F4 | Timings: the last second's averages, the tick, the load step, the server's tick rate, and the most expensive scopes |
| F6 | Spikes: the newest frames over budget, and what took the time |
| F7 | Pawn inspector: Ctrl + left click a pawn for its flags, Health, input, abilities, effects and AI |
| F8 | Log: warnings and errors, with how often each came |
| F5 | Projectile trace: each projectile's planned path, where it flew, what it met (green hit, grey met but not hit, orange the world) and where it ended; kept 3 s after it's gone (debug builds only) |
| F9 | Nav view: the nav mesh, links and markers around the camera (debug builds only) |
| F12 | Capture: a folder with a screenshot, the history as a table, the spikes, the log and where the replay is |

**Time your own code.**
```gdscript
var started := PerfScopes.begin()
# ... the work ...
PerfScopes.end(&"ai.sensing", started)
```
Names are dotted, general first. Name animation work `animation.something` and it joins the animation figure.

**Find a bug report's files.** Session logs are in `user://diagnostics/sessions/`, captures in `user://diagnostics/captures/` (runs with no display use `headless/` inside it). The capture's `capture.txt` names the replay that was recording.

**Read the numbers in code.** `GameMode.get_module(DiagnosticsManager)`, then `get_summary(seconds)`, `get_server_ticks()` (cheap enough for a HUD every frame), `get_history()` (the ring buffer, to read every frame), `get_frames(newest)` (records, for tests and tools), `get_spikes()` or `capture()`.

**Leave it out.** Take `DiagnosticsManager.gd` out of the `modules` setting, or its `.release` override for release builds only.

## How it works

**Measuring a frame.** A frame is timed from the end of the last frame's scripts to the end of this one's, so a slow frame's time and its breakdown stay together (Godot's `delta` would put the time on the next frame). Its parts: **physics** is the frame's physics steps (all of its ticks), stamped by a helper node that runs first in both physics and process; **scripts** is every node's `_process`, ending with the manager, which runs last; **rest** is what is left, drawing the last frame and waiting for the screen. Added to it: TickDriver's phases (as `tick.` scopes), every `PerfScopes` timing, render CPU and GPU time, draw calls, and memory, object, node and orphan counts (a leak shows as a count that only climbs). A spike is a frame over `spike_over_budget` times the tick's budget, kept with its whole breakdown; the first 30 frames (loading) never count.

**Scopes.** `PerfScopes` is main thread only: work on worker threads is timed by whoever waits for it. A scope costs about a microsecond, so ones that run per pawn per tick use `begin_detailed()`, which times only while F4 is open (or `mass_battle_measure --scopes` runs).

**Always on.** The manager starts a replay when play starts (hosting, joining, or a player taking a pawn offline) and none is running, so recordings exist for bug reports. It ships in release builds: the project setting's `.release` override lists it, and a game can leave it out of either list. The panels ship too; F5, F9 and F10 are debug-only. Its window title also names the role and process id.

**What the panels show.** F1 the keys and the session log's name; F2 the last seconds, a bar per frame split into physics, scripts and rest, lines at 1/60 and 1/30 s; F4 the last second's averages, the tick and up to 14 scopes; F6 the newest spikes; F7 a pawn's flags, abilities, effects, AI and input; F8 warnings and errors with counts; F12 a capture. "Late" is over 20 ms, "very late" over 34 ms.

**`get_summary(seconds)` keys.** The frame: `seconds` (less than asked when the history covers less), `frames`, `fps`, `frame_ms`, `physics_ms`, `scripts_ms`, `rest_ms`, `steps_per_frame`, `frame_worst_ms`, `over_60_percent` (frames over 20 ms), `over_30_percent` (over 34 ms), `render_cpu_ms`, `render_gpu_ms`, `draw_calls`, `animation_ms` (every `animation.` scope). Ticks: `ticks_per_second`, `dropped_per_second`, `load_step`, `step_counts` (AI pawns running every tick, 2nd and 4th), `tick_ms`, `tick_parts` (each phase and network part, ms a tick). `scopes`: name to `[ms a frame, calls a frame]`, most expensive first. Counts: `objects`, `nodes`, `orphans`, `memory_mb`, `pawns`, `dead`, `frozen`, `role`, `window`, `vsync`. `server`: `tick_rate` (as set), `ticks_per_second` (how fast its ticks really went: this machine's own offline or hosting, measured from snapshots on a client), `load_percent` and `load_step` (-1 before a client has any). `net`, in a session: `sent_kb_s`, `received_kb_s`, `snapshots_per_second`, `snapshot_kb` (average: as sent on a server, as received on a client), `largest_sent_kb`, `largest_received_kb`, `corrections_per_second`, `resyncs`, `underruns_per_second`, and the worst connection's `rtt_ms`, `loss_percent` and `seconds_since_heard`.

## Settings worth knowing

| Setting | Where | Default | What it does |
|---|---|---|---|
| `history_frames` | `DiagnosticsManager` | 3600 | Frames kept in memory for the live views (60 s at 60 fps, 15 s at 240); the replay keeps the whole session |
| `check_moves` | `DiagnosticsManager` | on | After each tick, warns about any entity that moved further than its velocity explains (`MoveSanityCheck`) |
| `spike_over_budget` | `DiagnosticsManager` | 1.2 | A frame over the tick's budget times this is a spike (over 20 ms at 60 ticks a second) |
| `spikes_kept` | `DiagnosticsManager` | 50 | Spikes kept, newest last |
| `log_every_seconds` | `DiagnosticsManager` | 5 s | How often a summary line goes into the session log |
| `repeats_logged` | `DiagnosticsManager` | 3 | Times one warning is written in full before it's only counted |
| `logs_kept` | `DiagnosticsManager` | 30 | Session logs kept |
| `headless_runs_apart` | `DiagnosticsManager` | on | Tests and dedicated servers write into `headless/`, so they never push out played games' logs |
| `radius` | `NavDebugView` | 60 m | How far each way from the camera F9 draws |

## Tests

`diagnostics/tests/diagnostics_selftest`: PerfScopes, the history, spikes, warnings, the session log, summaries, the editor's monitors, the replay channel, captures, the panels, and always-on recordings. `diagnostics/tests/nav_debug_view_selftest`: the F9 nav view. Run them with `bash tools/run_tests.sh diagnostics nav_debug_view`.
