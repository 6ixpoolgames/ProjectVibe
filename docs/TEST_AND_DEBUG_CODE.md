<!-- Written by Claude (claude-opus-5-5), 2026-11-07: where test and debug code lives, as agreed with the owner. -->

# Test and Debug Code

**Rule:** code added for testing stays apart from code that goes into a release. Don't build guardrails for a test's situation into the base. What a sample or test does for its own convenience, such as giving each player a pawn, isn't a rule of the base.

## Where it goes

| Use | When | Example |
|---|---|---|
| **Script extension** | A test creates the node itself | `streaming/tests/SlowChunkStreamer.gd` extends `ChunkStreamer` |
| **Module** | The thing being tested is an autoload, because a test scene can't swap an autoload for an extension. The module is an optional child, and without it nothing changes | `NetDebugModule` for `NetworkSession` (planned) |

Folders: `tests/` for tests, `samples/` for samples, and `debug/` for tools used while playing a debug build.

## What can stay in the base

Small diagnostics that cost very little, and that moving would cost more than it gains:
- `get_stats` on `ChunkStreamer`, and `stats` on `NetworkSession`
- `profile_enabled` on `NetworkTime`
- `NetworkTime.step()`

A base class may offer one empty slot for a module to fill, such as a packet filter. It should never name a debug class.

## How to check it

Release exports leave out `tests/`, `samples/` and `debug/`. Any base code that still names something from those folders then breaks loudly. To test this, delete those folders from a temporary copy and check that the project still loads.

**Status:** planned. No export preset leaves those folders out yet, and this check hasn't been run.

## Netcode: planned

Agreed with the owner on 2026-11-07, not built yet. `NetworkSession` still holds these tools (netcode spec section 17, row 34).

| Piece | Where | Why |
|---|---|---|
| Fake network (`fake`, `fake_in`, `NetFakeConditions`), `NetTestBench` | `NetDebugModule` | The session keeps one empty slot for a packet filter, checked on send and receive |
| `set_feature`, `FEATURES`, `allow_debug_commands`, the `DEBUG_SWITCH` packet | `NetDebugModule` | Live switching is only for testing, and a release protocol shouldn't carry a debug packet. The client-to-server switch would try an RPC owned by the module |
| The ten feature settings, such as `prediction_enabled` | Stay for now | They're plain settings, and removing them means rewriting the comparison tests. Prune them later |
| `content_hash_salt` | Probably removed | It only exists to force a refused join. Check first whether `--build-id` can do that |

**Not checked yet:** snapshots also carry the server's feature settings (`SERVER_FEATURES`), and that code hasn't been read closely. It could change this plan.

## Done so far

- `simulate_slower_cpu` and `reset_worst_times` moved from `ChunkStreamer` to `SlowChunkStreamer`.
- The ray counter and aiming at the middle of the screen moved from `WorldCursor` to a test class in `player/tests/world_cursor_selftest.gd`.
- `"headless"` checks removed from `PlayerController` and `WorldCursor`.
- A rule on `Pawn` that only existed for test walkers removed. `net_test_node.gd` now turns on `ai_loads_chunks` for them.
