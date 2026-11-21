<!-- Written by Claude (claude-opus-5-5), 2026-11-17: the diagnostics system's running changelog (the owner's call: history leaves
the code comments and lives here, next to the code). Newest first. Add an entry with every change; code comments say what the code
does now, this says how it got here and why. -->

# Diagnostics changelog

Diagnostics is this folder: `PerfScopes`, `DiagnosticsManager`, `DiagnosticsLogger`, `DiagnosticsPanels` and `NavDebugView` (whose history is in [navigation's changelog](../navigation/CHANGELOG.md)), plus `replay/ReplayDiagnosticsChannel` (in [replay's changelog](../replay/CHANGELOG.md)). Design: [docs/diagnostics/DIAGNOSTICS_SPEC.md](../../../docs/diagnostics/DIAGNOSTICS_SPEC.md). Overview: [README.md](README.md).

## Refactor candidates

Code that works but doesn't yet fit the project's goals (reusable, extensible, efficient, designer friendly). Each is marked `REFACTOR:` in the code. Sizes are rough: S an hour or two, M a day, L more.

| What | Where | Why | Size |
|---|---|---|---|
| Split the manager | `DiagnosticsManager` | One 700-line class measures frames, writes the session log, takes captures, feeds the editor's monitors, starts recordings and sets the window title. A session log writer and a capture taker of their own would each be easier to read and to swap | M |
| Always-on recordings belong to the recorder | `DiagnosticsManager._on_possessed`, `_set_role` | A replay rule living in diagnostics: a game without the manager gets no always-on recordings. An `always_on` setting on `ReplayRecorder` keeps the rule with the recorder | S |
| The window title in shipped games | `DiagnosticsManager._update_title` | A debugging convenience (role and process id, to tell instances apart) that also renames a release build's window, since diagnostics ship. A setting, or debug builds only, keeps a game's own title | S |
| "Late" and "very late" as settings | `DiagnosticsManager._summary`; the F4 panel's text; `replay/ReplayViewer`'s strip colours | Fixed at 20 and 34 ms (60 and 30 fps) in three places, while spikes follow the tick rate and `spike_over_budget`. A game aiming at another frame rate can't set them | S |

## 2026-11-21

- **The pawn panel reads abilities' time left and cooldowns from their deadlines** (`ticks_left()`, `cooldown_ticks_left()`), now that timers are tick deadlines (state store spec 13.10).

- **`MoveSanityCheck` runs in every build**, not only debug ones (owner's call): its first pass is now the store's `find_long_moves`, 0.03 ms a tick at 300 pawns instead of 0.12.

## 2026-11-20

- **`MoveSanityCheck`** (new): in debug builds, after each tick, warns once per entity that moved further than its velocity explains and didn't teleport (`Pawn.teleport`). Reads only the state store; 0.12 ms a tick at 300 pawns. Switched by `check_moves` (new, on); `get_move_check()` (new).

## 2026-11-19

- **The tick total counts the tick driver's new commit phase** (`tick.commit`, the state store's end-of-tick pass), so a tick's cost includes it.

## 2026-11-18

- **Comments rewritten to the reference style** (the documentation pass): class and member comments shortened, `GDScript note:` and "the owner's call" wording removed (the measuring method, PerfScopes' cost note and release-build behaviour kept). The frame-measuring explanation, the panels' contents and the `get_summary` keys moved to a new "How it works" section of the README. No stale comments found.
- **F1 lists F10** (the AI decision module's key: every pawn's decisions in GDScript and back), and no longer says the panels are debug-only (they ship in release builds; F9 and F10 are debug-only).

## 2026-11-17

- **Detail for timing scopes:** `PerfScopes.detailed` and `begin_detailed()`, for scopes that run very often (the AI's per state, per behaviour and per sense ones). They time only while detail is on, which the F4 timings panel switches on while it's open, and `mass_battle_measure --scopes` too. A scope costs about a microsecond; the AI's fine scopes measured about 0.2 ms a frame at 600 pawns, and they also inflate the numbers they sit inside (a check timed in three nested parts read nearly twice its real cost).
- **F9, the nav view.** `NavDebugView` draws the nav mesh, nav links and nav markers around the camera, made the first time F9 is pressed (debug builds only). Its history is in navigation's changelog.
- **Health in the pawn inspector** reads `stat_manager.get_health()` only when the pawn has a StatManager.
- **Comments cleaned up** for the documentation pass: dated notes moved here, doc comments in Godot's markup. Fixed on the way: `PerfScopes` said nothing listens in a release build (the manager ships in release now); `get_summary`'s key list lacked `load_step` and `step_counts`; `get_last_summary` said the editor's monitors read it (nothing in the base does); the F4 and F6 panel descriptions ("every scope", "the slowest frames") now match what they show. The F1 panel's first line still says "debug builds only", which is out of date; it's text in code, so it waits for the next code change.

## 2026-11-16

- **Diagnostics v0** (the owner's request after the mass battle ran under 30 fps in play but not in Claude's runs): `PerfScopes`, `DiagnosticsManager` (frames measured from the end of one frame's scripts to the next, history, spikes, session logs, captures, the editor's monitors), `DiagnosticsLogger`, `DiagnosticsPanels` (F1, F2, F4, F6, F7, F8, F12), the replay's diagnostics channel, and recordings started whenever play starts. The old `PerformanceOverlay` went.
- **In release builds** (the owner's call, for bug reports): the manager moved from `debug/` to `diagnostics/`, and the `modules` setting's `.release` override lists it.
- **Headless runs apart** (the owner's call: test runs were deleting playtest logs): runs with no display write into `folder/headless`.
- **Profiling the networked mass battle:** each frame records what the session's counters added (`net_` keys, named from `NetworkSession.COUNTING_STATS` rather than hard-coded), summaries gain a `net` part (bandwidth, snapshots and their size, largest packets, round trip, loss, corrections, resyncs, underruns), and why a connection ended goes into the session log. Snapshot sizes count like with like: snapshots sent and their bytes on a server, received on a client (before, every client's bytes were divided by one count).
- **The server's tick rate** (the owner's request, for profiling on different hardware): `server` in summaries and `get_server_ticks()`, how fast the server's ticks really went (from snapshots on a client), with its load and load step; shown in F4, the session log and a monitor.
- **The load ladder and tick steps** (pawn spec 8.21): the load step, and how many AI pawns run every tick, every 2nd and every 4th.
- **An animation figure** (the owner's request): every `animation.` scope added up, in F4, the session log and a monitor.
- **The wider audit:** TickDriver's counts (rollbacks) are no longer shown as times; pawns are counted from `Pawn.GROUP`.
- **Ability steps** show in the pawn inspector (pawn spec 8.20), and its input comes from the ControllerManager (pawn M4).
