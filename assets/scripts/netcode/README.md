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

## How it works

**Roles.** `NetworkEntity.role` is set per machine:
- `AUTHORITY`: the server (or offline). It simulates for real and its results count.
- `LOCAL_PREDICTED`: your own pawn on your client. It simulates ahead and gets corrected.
- `LOCAL_UNPREDICTED`: your own pawn with prediction off (MOBA-style). It sends inputs and waits, so what you do shows after your ping; it is drawn from snapshots like a remote entity.
- `REMOTE_FOLLOWING`: anything else on a client. It doesn't simulate: it is drawn in the past between snapshots, and stays where it is drawn during a rollback.
- `REMOTE_PREDICTED`: anything else on a client, when predicted. It simulates ahead on its last known input and gets corrected, like Rocket League cars. Off by default: it costs CPU on every rollback, needs input in every snapshot, and puts enemies at their present position, which doesn't suit aiming.

**Hooks on the parent** (all optional): `_on_network_role(entity)` (told its role before entering the tree), `sanitize_network_input(values) -> Dictionary` (the server cleans a client's input; never trust it), `_network_input_missing()` (no input for this tick, so the last one repeats), `_on_network_interpolated()` (a remote entity was just moved between snapshots), `_on_network_corrected(jump)` (a rollback moved it, for hiding the jump on the visible model). The two input hooks go to `NetworkEntity.input_owner` when set (a Pawn's ControllerManager sets itself), else to the parent.

**What a `TickStateComponent` lists.** Input properties are what the entity wants each tick (saved after the input phase, restored during a replay). State properties are everything that affects the next tick; a value that influences the future and isn't listed makes replays drift. Sync properties are server-only values (health, team): not rolled back, sent in every snapshot. Entries are matched to nodes when ticks run, not at ready, because children become ready before their parent and `PawnInitializer` may add parts later; an entry whose node or property is missing warns once and is looked for again every tick. A freed node just stops being saved. Arrays and Dictionaries are copied in and out of the history; objects can't be, so use `save_state`/`load_state` or an id. `history_size` is in ticks; a `correct_state` for a tick that is gone snaps the entity and warns.

**Unusual state.** If the parent (or a node in `custom_state_nodes`) has `save_state() -> Dictionary` and `load_state(Dictionary)`, they run alongside the lists. `save_state` must return a new Dictionary each call. The Dictionary also goes in every snapshot and is corrected like list entries, so its values must come out exactly equal on server and client (ints, bools, or floats you rounded yourself) and it should be small, since no encoding shrinks it. After every entity has loaded, the parent's `_on_state_loaded(tick)` runs if it has one, so a floor check there sees the others where they were.

**Rounding.** Every networked value is rounded to its encoding at the end of every tick, on server and client alike, so rounding alone never causes a misprediction (`StateEncoding.quantize`, twin of C++ `state_encoding.h`). A value that changes by less than half a step per tick would be rounded straight back and never move: at 60 ticks a second and 1 mm that stalls anything slower than about 3 cm/s, at 1 cm it would be 30 cm/s, which is why positions aren't in cm. Two rules for physics bodies (see `samples/TickSamplePawn.gd`): `safe_margin` must not be a whole number of steps (Godot's default of 1 mm is; float noise then flips the contact and the engine snaps the body up to 2.4 cm into the floor), and don't turn a body by writing `rotation` every tick (it slowly changes the scale and so the collision shape, differently in a replay); keep facing as a plain number and turn only the model.

**Following the server (`rollback_mode`).** `RESIMULATE` (default) is for what this machine predicts: it is put back and its `_tick_simulate` runs again. `FOLLOW_SERVER` is for what it doesn't predict: not simulated, drawn between snapshots with `follow_server_at`, which writes only values that change. During a rollback such an entity normally stays where it is drawn; with `follows_during_rollback` on it stands where the server says, so predicted bodies bump into it. For ticks the server didn't send it starts from the newest earlier server state and moves on that state's velocity up to `extrapolation_cap_seconds`, then holds (velocity only: no steering, gravity or collisions; vertical is ignored by default because with no gravity a falling pawn would sink). When the replay ends it gets back exactly what it had. Position is the parent's `position` or `global_position`; velocity is any entry called `velocity`. With nothing listed it uses `position` (plus `velocity` if the parent has one) without adding them to `state_properties`, so the handshake schema stays the same. A late packet older than its history slot is ignored; after a teleport or respawn call `clear_authoritative_state`. Tested with CharacterBody3D and plain nodes, not yet rigid bodies or animated platforms.

**Lag compensation.** A client says how many ticks behind its own tick it was drawing others (`view_ticks_behind`). The server limits it to between 0 and `rewind_cap_seconds` and to what the client's snapshot acknowledgements make believable (`NetworkSession.limit_view_ticks_behind`); past the cap a high-ping shooter has to lead the target. An entity with no record of that tick stays where it is for the check. Everyone is put back to their real position (the collision world too) before the check returns. One rewind serves each check, so `melee_spheres` checks several spheres in one.

**The clock.** The client sends pings and each pong says which tick the server was on. A ping that came back quickly spent little time queued, so `NetClock` estimates the server's tick from the fastest recent one and the round trip from the average. A client runs ahead by half the round trip plus a margin, set when it starts ticking and set again only if it drifts well away; day to day, time dilation (`TickDriver.tick_factor`, from the margins the server reports) keeps it right.

**On the wire.** Every value starts with a one-byte tag saying how it is stored, so a reader never guesses and a bad packet is spotted and dropped. Packet type is the first byte of a packet; new types and tags go at the end so numbers don't move. `NetPackets` bumps `PROTOCOL_VERSION` with any format change (part of the handshake's content hash); `NetCodec` in C++ holds its own copy of the format.

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
