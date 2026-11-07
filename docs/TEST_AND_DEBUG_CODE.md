<!-- Written by Claude (claude-opus-5-5), 2026-11-07: where test and debug code lives, as agreed with the owner. -->

# Test and Debug Code

**Rule:** code added for testing stays apart from code that goes into a release. Don't build guardrails for a test's situation into the base. What a sample or test does for its own convenience, such as giving each player a pawn, isn't a rule of the base.

## Where it goes

| Use | When | Example |
|---|---|---|
| **Script extension** | A test creates the node itself | `streaming/tests/SlowChunkStreamer.gd` extends `ChunkStreamer` |
| **Module** | The thing being tested is an autoload, because a test scene can't swap an autoload for an extension. The module is an optional child, and without it nothing changes | `netcode/debug/NetDebugModule.gd` for `NetworkSession` |

Folders: `tests/` for tests, `samples/` for samples, and `debug/` for tools used while playing a debug build.

## What can stay in the base

Small diagnostics that cost very little, and that moving would cost more than it gains:
- `get_stats` on `ChunkStreamer`, and `stats` on `NetworkSession`
- `profile_enabled` on `TickDriver`
- `TickDriver.step()`

A base class may offer one empty slot for a module to fill, such as a packet filter. It should never name a debug class.

## How to check it

Release exports should leave out `tests/`, `samples/` and `debug/`. Any base code that still names something from those folders then breaks loudly. To test this, delete those folders from a temporary copy and check that the project still runs.

**Status:** that check was run by hand on 2026-11-07, on Linux, with a real host and client. It isn't automated, and no export preset leaves those folders out yet, because the project has no release export.

## Netcode

| Piece | Where | Why |
|---|---|---|
| Fake network (`fake`, `fake_in`, `NetFakeConditions`), `NetTestBench` | `netcode/debug/` | The session keeps one empty slot, `packet_filter`, checked on send and receive |
| `set_feature`, `FEATURES`, `allow_debug_commands` | `NetDebugModule` | Live switching is only for testing. It uses the client message channel, so the protocol has no debug packet |
| The ten feature settings, such as `prediction_enabled` | Stay for now | They're plain settings, and removing them means rewriting the comparison tests. Prune them later |
| `SERVER_FEATURES` in snapshots | Stays | `default_predicted` changes roles on clients, so it's needed in a real game |

## Done so far

- The netcode tools above moved out of `NetworkSession`, and `content_hash_salt` is gone: a refused join is tested with `--build-id`.
- `simulate_slower_cpu` and `reset_worst_times` moved from `ChunkStreamer` to `SlowChunkStreamer`.
- The ray counter and aiming at the middle of the screen moved from `WorldCursor` to a test class in `player/tests/world_cursor_selftest.gd`.
- `"headless"` checks removed from `PlayerController` and `WorldCursor`.
- A rule on `Pawn` that only existed for test walkers removed. `net_test_node.gd` now turns on `ai_loads_chunks` for them.
