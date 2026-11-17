<!-- Written by Claude (claude-opus-5-5), 2026-11-17: the netcode's overview, beside its code. -->

# Netcode

Multiplayer for any game built on the tick driver: a server that decides, clients that predict their own pawn and draw everyone else a moment in the past, and rollback when a prediction was wrong. Offline, none of it runs and entities play as single player.

**Status:** built, tier 0 (snapshots at stage v1: changes since an acknowledged baseline, in parts). Not yet: server projectiles (spec 9.2), relevancy and priority so a client only gets what it can see (packets v2), and rigid bodies and moving platforms in rollback.

| File | What it's for |
|---|---|
| [README.md](README.md) | This overview: what's here and how to use it |
| [REFERENCE.md](REFERENCE.md) | Every class, setting and function, generated from the code's doc comments (`python tools/docs/make_reference.py netcode`) |
| [CHANGELOG.md](CHANGELOG.md) | What changed and why, newest first, and the refactor candidates |
| [NETCODE_SPEC.md](../../../docs/netcode/NETCODE_SPEC.md) | The full design, what's measured, and what's planned |

## The pieces

```
 the server                                          a client
 ──────────                                          ────────
 NetworkSession ── WELCOME, SPAWN, snapshots ──────► NetworkSession ── ACKs, inputs ──► (server)
   │  (in parts, as changes)                           │  NetClock: runs a few ticks ahead
   │                                                   │
   ▼                                                   ▼
 an entity: NetworkEntity + TickStateComponent       the same entity, with a role:
   simulates for real; LagCompensation               your pawn predicts and rolls back,
   rewinds others to check a hit                     others are drawn between snapshots
```

- **`NetworkSession`** (`singletons/`, the autoload): hosts or joins, checks the two builds match (the content hash), spawns entities everywhere, and moves inputs and snapshots between machines inside `TickDriver`'s ticks. Also time dilation (a client runs slightly faster or slower to stay just ahead), and world and client channels for things that aren't entities, such as terrain edits.
- **`NetworkEntity`** makes a node networked: an id that's the same everywhere, an owner, and a role on each machine (authority, your predicted pawn, or a remote entity drawn from snapshots).
- **`TickStateComponent`** makes a node rollback-ready without code: list its properties in the inspector, and it rounds them each tick, keeps their history, and puts them back for a replay. Its recording runs in C++ (`TickStateRecorder`) when the library loads.
- **`StateEncoding`** says how precisely each value is kept (1 mm positions, angles in 65536 steps); **`NetPackets`** turns values into bytes (with `NetCodec` in C++ doing snapshots faster, the same bytes).
- **`NetClock`** estimates the server's tick from pings. **`LagCompensation`** checks a hit against where the attacker saw everyone.
- **`debug/`**: `NetDebugModule` (fake bad network and live feature switches, an optional child of the session), `NetFakeConditions`, `NetTestBench` (keys for both, debug builds only), `NetMonitors` (graphs in the editor's Debugger > Monitors).

## How to use it

**Make something networked.** Give its scene a `TickStateComponent` child and list what affects the next tick under State properties (`velocity`, `Walk:phase`, `:rotation:y @angle_u16`) and what the player wants under Input properties. Then add a `NetworkEntity` child after it. The entity keeps writing `_tick_input` and `_tick_simulate` as usual.

**Host and join.**
```gdscript
NetworkSession.register_type("pawn", preload("res://pawn.tscn"))  # same types, same order, on every machine
NetworkSession.host(7777)          # or NetworkSession.join("127.0.0.1", 7777)
NetworkSession.spawn("pawn", peer_id, Vector3(0, 1, 0))   # on the server, when the game wants it
```
`joined`, `refused`, `player_connected` and `player_leaving` say what happened. A joining player gets nothing by itself: the game spawns or hands over a pawn (`set_entity_owner`).

**Something only the server decides** (health, team): list it under Sync properties. It isn't rolled back; clients show the latest.

**Check a hit fairly.** On the server, `LagCompensation.hitscan(...)` or `melee_spheres(...)` with the attacker's `view_ticks_behind` (a client sends `NetworkSession.get_view_ticks_behind()` with its attack).

**Send something that isn't an entity.** `register_world_channel(name, receive, catch_up)` and `send_world_message` (server to clients), or `register_client_channel` and `send_to_server` (client to server; check what arrives).

**Try a bad connection.** Open `net_sample.tscn` twice, Host in one, Join in the other. In a debug build, `[` and `]` change the ping, Shift+F1 to F5 pick presets, and the number keys switch features (`NetTestBench`).

## Settings worth knowing

| Setting | Where | Default | What it does |
|---|---|---|---|
| `snapshot_rate` | `NetworkSession` | 30 | Snapshots a second |
| `interpolation_seconds` | `NetworkSession` | 0.1 s | How far in the past remote entities are drawn |
| `prediction_enabled` | `NetworkSession` | on | Your pawn reacts at once; off, it waits for the server (MOBA-style) |
| `rewind_cap_seconds` | `NetworkSession` | 0.35 s | How far back lag compensation goes; past it, players lead their shots |
| `input_redundancy` | `NetworkSession` | 3 | Inputs per packet, so a lost packet loses nothing |
| `delta_snapshots_enabled` | `NetworkSession` | on | Send changes since an acknowledged snapshot, not everything |
| `is_predicted` | `NetworkEntity` | off | Other clients simulate it ahead instead of drawing it from snapshots |
| `keep_history_offline` | `NetworkEntity` | off | Keep rollback history offline, for a single-player rewind |
| `history_size` | `TickStateComponent` | 64 | Ticks of history kept (about 1 s) |

## Tests

`netcode/tests/`: `net_selftest` (real connections between separate processes, about 8 minutes; runs only when named), `net_session_selftest` (session details that need no connection), `tick_state_selftest` (rollback state; `-- --gdscript-record` runs it without C++), `net_codec_selftest` (C++ against GDScript encoding, timed), `net_monitors_selftest`. Measurements: `net_measure` (numbers at set pings), `net_stress` (many clients and pawns on hills with nav), `net_profile` (where the time goes). Elsewhere: `pawn/tests/net_pawn_selftest`, `streaming/tests/net_streaming_selftest`, and `samples/tests/mass_battle_net_measure` for bandwidth and snapshot sizes at scale. Run them with `bash tools/run_tests.sh <name>`.
