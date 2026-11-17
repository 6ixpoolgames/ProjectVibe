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

- **`PerfScopes`** marks work: `begin()` and `end(name, started)`. With nothing listening it costs one true-or-false check, so the marks stay in shipping code.
- **`DiagnosticsManager`** is a GameMode module, listed by the project setting `project_base/game_mode/modules` and its `.release` override; the base never names it. Every frame it measures physics, scripts and the rest, adds TickDriver's phases and every scope, keeps 30 s of history and the spikes, writes the session log, feeds the replay and the editor's monitors, and starts a replay when play starts if nothing else did.
- **`DiagnosticsLogger`** catches the engine's warnings and errors from any thread, for the log and the replay.
- **`DiagnosticsPanels`** are the on-screen panels. **`NavDebugView`** draws navigation in the world (its history is in [navigation's changelog](../navigation/CHANGELOG.md)).

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

**Read the numbers in code.** `GameMode.get_module(DiagnosticsManager)`, then `get_summary(seconds)`, `get_server_ticks()` (cheap enough for a HUD every frame), `get_frames()`, `get_spikes()` or `capture()`.

**Leave it out.** Take `DiagnosticsManager.gd` out of the `modules` setting, or its `.release` override for release builds only.

## Settings worth knowing

| Setting | Where | Default | What it does |
|---|---|---|---|
| `history_seconds` | `DiagnosticsManager` | 30 s | How much history is kept in memory |
| `spike_over_budget` | `DiagnosticsManager` | 1.2 | A frame over the tick's budget times this is a spike (over 20 ms at 60 ticks a second) |
| `spikes_kept` | `DiagnosticsManager` | 50 | Spikes kept, newest last |
| `log_every_seconds` | `DiagnosticsManager` | 5 s | How often a summary line goes into the session log |
| `repeats_logged` | `DiagnosticsManager` | 3 | Times one warning is written in full before it's only counted |
| `logs_kept` | `DiagnosticsManager` | 30 | Session logs kept |
| `headless_runs_apart` | `DiagnosticsManager` | on | Tests and dedicated servers write into `headless/`, so they never push out played games' logs |
| `radius` | `NavDebugView` | 60 m | How far each way from the camera F9 draws |

## Tests

`diagnostics/tests/diagnostics_selftest`: PerfScopes, the history, spikes, warnings, the session log, summaries, the editor's monitors, the replay channel, captures, the panels, and always-on recordings. `diagnostics/tests/nav_debug_view_selftest`: the F9 nav view. Run them with `bash tools/run_tests.sh diagnostics nav_debug_view`.
