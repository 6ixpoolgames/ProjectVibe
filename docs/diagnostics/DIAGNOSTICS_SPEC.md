# Diagnostics Spec v0.1 (diagnostics v0, built)

*Written by Claude (claude-opus-5-5), 2026-11-16, from the owner's decisions the same day.*

**Why it exists.** The owner's playtest of the mass battle ran under 30 fps, but Claude's runs of the same scene held 60. The tools of the time (a performance overlay in one sample, a perf log in another) couldn't say what a slow frame was doing, or work the same way wherever the game ran. Diagnostics v0 answers "where did this frame's time go?" in any debug build, the editor included. It records the answer next to the game itself, in the replay.

## 1. Decided

| Question | Answer | Whose call |
|---|---|---|
| Hook into replays? | Yes. The replay recorder and its writer thread carry the diagnostics too, as channel 6, so one file holds what happened and what it cost | the owner |
| What it's suspected of | Not the GPU (good hardware, a simple game), unless something leaks: so memory and object, node and orphan-node counts are recorded every frame | the owner |
| Recordings and logs | Always on in debug builds | the owner |
| Keys | One per panel, for readability, in a small font with nothing overlapping. A proper look comes with UI v0 | the owner |
| How it's switched on | The project setting `project_base/game_mode/modules` lists `DiagnosticsManager`. The base never names it. *(2026-11-16: the `.release` override lists it too, and it moved from `debug/` to `diagnostics/`: diagnostics ship in release builds, for bug reports, the owner's call)* | Claude's proposal, agreed; release, the owner's call |
| The performance baseline check | On request. Claude suggests a run when one is warranted | the owner |

## 2. The pieces

| Class | Where | What it does |
|---|---|---|
| `PerfScopes` | `assets/scripts/diagnostics/` (base) | Timing scopes. Systems mark their work with `begin()` and `end(name, started)`. With nothing listening it costs one check of a true-or-false, so the marks stay in shipping code |
| `DiagnosticsManager` | `assets/scripts/diagnostics/` (shipped, 2026-11-16) | A `GameMode` module. Every frame it measures the frame and keeps 30 s of history, spikes, session logs and warnings, and feeds the replay, the editor's monitors and the panels |
| `DiagnosticsLogger` | the same | Godot's `Logger`, catching every warning and error from any thread, for the manager to take once a frame |
| `DiagnosticsPanels` | the same | The panels, one key each, and the capture key |
| `ReplayDiagnosticsChannel` | `assets/scripts/replay/` (base) | Replay channel 6: each frame's numbers and scopes, plus warnings and captures as events. A plain data channel that the manager fills |

## 3. What a frame is

A frame is counted from the end of the last frame's scripts to the end of this one's. That keeps a slow frame's time and its breakdown in the same frame; Godot's `delta` would put the time on the frame after.

- **physics:** from this frame's first physics step to the start of `_process`. That covers all of this frame's ticks, the physics engine, nav and other nodes' `_physics_process`. **steps** says how many physics steps there were: more than 1 means catching up.
- **scripts:** every node's `_process`. A helper runs first and the manager runs last, by process priority.
- **rest:** everything else: drawing the last frame, and waiting for the screen with vsync on.

A frame is **late** over 20 ms, a missed 1/60 s with a millisecond of jitter either way. It is **very late** over 34 ms. It's a **spike** over the tick's budget × `spike_over_budget` (1.2, so 20 ms at 60 ticks a second). Spikes are kept with their full breakdown and written to the session log.

## 4. The timing scopes

Names are dotted, from the general to the particular. The same name used many times a frame adds up, and the count says how many.

| Scope | What it times |
|---|---|
| `tick.input`, `tick.capture`, `tick.simulate`, `tick.record`, `tick.before_tick`, `tick.after_tick` | TickDriver's phases (its own profile, read and reset every frame) |
| `tick.flush`, `tick.reconcile`, `tick.remote`, `tick.send_inputs`, `tick.send_snapshots` | The network session's parts, which it already times into TickDriver's profile |
| `ai` (`ai.sensing`, `ai.decide`, `ai.behaviours`) | Each pawn's AI step |
| `pawn.input`, `pawn.abilities`, `pawn.move_and_slide`, `pawn.hits` | Each pawn's input, effects and abilities, its one move, and hit delivery |
| `visuals.smoothing`, `visuals.waddle`, `visuals.sword` | The per-frame visual scripts |
| `ai.activation`, `streaming.chunks`, `streaming.ground_under_sources`, `nav.tick`, `nav.refresh`, `replay.record`, `world.kill_floor`, `debug.ability_draw` | The game-wide systems |

To time something new, wrap it: `var started := PerfScopes.begin()` … `PerfScopes.end(&"group.part", started)`. A C++ class that times itself can report with `PerfScopes.add(name, microseconds)`.

## 5. Keys and panels

| Key | Panel | Where |
|---|---|---|
| F1 | The keys, and the session log's name | top right |
| F2 | Frame graph: one bar per frame (physics blue, scripts orange, rest grey), with lines at 1/60 and 1/30 s | top right |
| F4 | Timings over the last second: the frame's parts, the tick, drawing, memory and counts, and the scopes, most expensive first (14 listed; the log has them all) | top right |
| F6 | Spikes, newest first, with their parts and top scopes | bottom left |
| F7 | Pawn inspector: Ctrl + left click a pawn to see its flags, running abilities and cooldowns, effects, AI state, behaviour and target, and input | bottom left |
| F8 | Warnings and errors, with how many times each came | bottom left |
| F12 | Capture: saves a folder (see 7) and says where | — |

The samples' own keys (F3 readouts, P pause, and so on) are unchanged. The mass battle's old F4 performance overlay is gone; its team and switch lines moved to the status text.

## 6. Session logs

Each run of the game writes `user://diagnostics/sessions/<date>_<time>_<process id>.log`, keeping the newest 30. The log contains:
- **A header:** the date, the game's name and version, Godot's version, debug or release, and whether the editor's debugger is attached. Then the command line, the CPU, thread count, GPU, display, tick rate and job worker setting.
- **A summary every 5 s:** fps, the frame's parts, late and very late frames, the tick, ticks a second, dropped ticks, drawing, memory and counts, pawns, the role, the window and vsync, and the top scopes.
- **Every spike**, with its breakdown.
- **Every warning and error,** written in full 3 times (`repeats_logged`), then counted, with a count line in later summaries. A flood can't slow the game: the logger keeps at most 500 between frames.
- **Role changes:** offline, host, client.

The window title shows the role and process id, so several instances can be told apart.

## 7. Captures (F12)

A capture goes in a folder of its own, `user://diagnostics/captures/<date>_<time>_<process id>/`, holding:
- `screenshot.png`
- `frames.csv`: the 30 s history, one row a frame, with its top scopes
- `capture.txt`: the tick, the replay file, the session log, a 5 s summary, the spikes, and the warnings and errors

The replay gets a "capture" event at that tick.

## 8. In the replay

`ReplayDiagnosticsChannel` (channel 6, replay spec section 3) records each frame's numbers and scopes, the scope names as they first appear (and all of them on each keyframe), warnings and errors, and captures. The replay viewer shows a strip above its slider: each tick's slowest frame, with lines at 1/60 and 1/30 s. Click it to jump to that moment. The panel shows the frame at the tick being viewed. Recordings start whenever play starts (hosting, joining, or a player taking a pawn offline) if nothing else has started one.

## 9. The editor's Debugger > Monitors

While running from the editor, the manager adds graphs under "Diagnostics": frame, physics and scripts times, physics steps, and the object, node and orphan-node counts.

## 10. Costs

- **With nothing listening** (release builds): one true-or-false check per scope.
- **In debug builds,** with the manager running: two clock reads per scope, about 20 scopes for each of 150 pawns a tick. That's a few tenths of a millisecond at mass-battle sizes, plus the frame record and the replay channel. The numbers include their own cost.

## 11. Later

- **Splitting "rest" three ways** *(the owner's call, 2026-11-16: a feature for later, unless a need comes up first)*: deferred calls and frees (from the end of scripts to `RenderingServer.frame_pre_draw`), drawing (`frame_pre_draw` to `frame_post_draw`), and waiting for the screen (from then to the next frame). The irregular grey spikes on the F2 graph are all in "rest", which today can't say which of the three it was.
- GPU timing pass by pass
- Tracking memory leaks by type
- Clients sending their numbers to the host
- A flame graph
- Timing scopes inside the C++ code
- The performance baseline check, as a scripted scenario with saved numbers and a tolerance
