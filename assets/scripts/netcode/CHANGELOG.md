<!-- Written by Claude (claude-opus-5-5), 2026-11-17: the netcode's running changelog (the owner's call: history leaves the code
comments and lives here, next to the code). Newest first. Add an entry with every change; code comments say what the code does
now, this says how it got here and why. -->

# Netcode changelog

The netcode is this folder (`TickStateComponent`, `StateEncoding`, `NetworkEntity`, `NetPackets`, `NetClock`, `LagCompensation`), the `NetworkSession` autoload (`singletons/NetworkSession.gd`), the C++ codec and recorder (`NetCodec`, `TickStateRecorder` in `native/src/`), and the test tools in `debug/`. It runs on `TickDriver` (`singletons/`), which has its own history. Design: [docs/netcode/NETCODE_SPEC.md](../../../docs/netcode/NETCODE_SPEC.md). Overview: [README.md](README.md).

## Refactor candidates

Code that works but doesn't yet fit the project's goals (reusable, extensible, efficient, designer friendly; production code kept apart from test and debug code). Each is marked `REFACTOR:` in the code. Sizes are rough: S an hour or two, M a day, L more.

| What | Where | Why | Size |
|---|---|---|---|
| Split `NetworkSession` into helpers with one job each | `singletons/NetworkSession.gd` | About 2000 lines doing many jobs: connecting and the handshake, the entity list and spawning, the clock and time dilation, inputs, encoding and acknowledging snapshots (deltas, parts), reconciliation, interpolation, world and client channels, connection statistics. Helpers (a snapshot sender and receiver, a clock, the channels) would be easier to read, test and extend, with the autoload keeping the public API | L |
| Stop the session naming `NetMonitors` | `NET_MONITORS_SCRIPT` in `NetworkSession` | A base autoload names a file in `netcode/debug/`; `docs/TEST_AND_DEBUG_CODE.md` says a base class should never name a debug class. NetMonitors could attach itself, from an editor-only plugin or a module like `DiagnosticsManager` | S |
| Let systems add their own part to the content hash | `content_hash()` in `NetworkSession` | The netcode names three other systems' tag sets (`TagRegistry`, `NavTags`, `InputActions`). A list systems register into would let a new tag set, or a game's own, join the handshake check without editing the session | S |
| Export the packet limits and `bind_address` | `max_packets_per_second`, `max_bytes_per_second`, `max_packet_bytes`, `bind_address` in `NetworkSession` | Plain vars, unlike the session's other settings, so a designer can't set them without code | S |
| A `LinkRecord` class for connection statistics | `_new_link()`, `_links` in `NetworkSession` | A Dictionary read by string keys, where the server's other per-client record is a class (`PeerRecord`); a class catches a mistyped key when the script loads | S |
| A separate part for following the server | `TickStateComponent.gd` | Two jobs in one class: recording and replaying this machine's own state, and placing an entity drawn from server data (`follow_server_at`, the follow cache, extrapolation, about 300 lines) | M |
| Drop or keep the dictionary form of server state | `receive_authoritative_state()` in `TickStateComponent` | Only tests call it (snapshots use `receive_authoritative_values`): a test-only door in production code. The tests could build the list themselves, or the owner may keep it as a by-name convenience | S |
| Size the lag compensation record from the rewind cap | `HIT_HISTORY_SIZE` in `NetworkEntity` | A fixed 64 ticks, while how far back lag compensation goes is a setting (`rewind_cap_seconds`). A cap above about 1 s, or a higher tick rate, silently rewinds nothing | S |
| A public way to sync a body's collision now | `NetworkEntity.rewind_to`, `restore_after_rewind` | They call `TickStateComponent._sync_collision`, a private function of another class | S |

## 2026-11-18

- **Comments rewritten to the reference style** (the documentation pass): every class, member and function comment is now one or two lines, with the class comments cut to a summary, a short paragraph and an example. The long explanations moved to the README's new "How it works" section (roles and hooks, what a `TickStateComponent` lists and its custom state, rounding and the physics-body rules, following the server, lag compensation, the clock, the wire format). Twin-parity notes (`TickStateRecorder`, `state_encoding.h`, `NetCodec`), packet and encoding details, rollback rules and `REFACTOR:` tags stay in the code. The `debug/` files lost their dated notes and now start with a plain `#` header line, so the reference page no longer opens with it. Stale comment fixed: `NetTestBench.toggle_feature` pointed at `NetworkSession.FEATURES`, which is `NetDebugModule.FEATURES`.

## 2026-11-17

- **Rounding every tick only where something replays** (the owner: "the skip"). A tick whose state isn't saved was still rounded on every machine, so a client replaying it matches the server. Where no machine replays an entity, that was work for nothing, and measured at 600 pawns offline it was 5.0 of the record phase's 5.8 ms a tick. `TickStateComponent.rounds_every_tick` (on by default) is now off offline (unless `keep_history_offline`) and, on a server, for an entity no client predicts: not owned by a client, not `is_predicted`, and `default_predicted` off. AI pawns and the host's own pawn. Saved ticks are rounded either way, so snapshots carry the same values, and a change of owner (possession) sets it again. `round_position` follows it. Checked in `net_selftest`.
- **The change check for deltas in C++** (C++ bundle stage 3). `NetCodec.delta_state` compares an entity's state with its baseline when the library is there; `NetworkSessionSingleton.delta_state_lists` is the GDScript version, split out of `_delta_entity_bytes` so `net_codec_selftest` can compare the two.
- **Hits without a rewind.** `LagCompensation.would_rewind()` says whether a check would move other entities back in time (`_ticks_to_rewind`, split out of `_rewind_others`). When it wouldn't (every AI swing, all offline play), `MeleeSweepStep` asks the pawn grid in C++ where pawns are now.
- **Comments corrected:** `NetClock` said time dilation was still to come; `NetworkSession`'s header said snapshots were still sent in full; `TickStateComponent` said parts came from "the nexus", which was never built; ACKs are per part, not per snapshot; `MAX_INBOX_PER_PEER` got its own comment; `receive_authoritative_state` is for tests. Commits 23d4c85 (networked mass battle fixes, code audits) and 15b25b6 (the C++ bundle).
- **Documentation pass.** Dated notes moved here; doc comments in Godot's markup; `README.md` and this file. Stale comments fixed against the code: `NetworkSession.content_hash` said it covered the tick rate (it hasn't since 2026-11-16); `_is_in_snapshot` said an entity with only sync properties never goes in a snapshot (it has since N3, 2026-11-16); `_peers` was described as a Dictionary of welcomed and connected_at (it holds `PeerRecord`s), and `_on_peer_connected` said the per-client records were declared there; `_within_limits` described what pings used to do; `TickStateComponent.get_schema` said the handshake "will" compare its hash (it does); `NetworkEntity.set_role` said it was for the test switches (it's how every feature switch reaches an entity); `LagCompensation` said it rewinds once per attack (once per check: `melee_spheres` checks many spheres in one); the session's "one tick on a client" left out world messages and ACKs. Refactor candidates listed above.

## 2026-11-16

- **Delta snapshots** (netcode spec 11.4.1, networking T1.3, the owner's call after the networked mass battle dropped its client). Each client gets each entity's changes since its baseline for that client (`DELTA_ID_BIT`, change masks of `DELTA_MASK_BITS`, `DELTA_MAX_BASELINE_AGE`), encoded once per entity and baseline and shared between clients; a client keeps `BASELINE_RING` ticks of what it received per entity to decode them. `delta_snapshots_enabled` turns it off to compare. Snapshots are cut into parts of at most `SNAPSHOT_PART_BYTES` (1100), each its own packet, under ENet's 1392-byte packet size. The mass battle's snapshots went from 44 KB to 4.5 KB and its client from 14 to 144 fps.
- **Per-part acknowledgements.** A new `ACK` packet type (added at the end, so the numbers before it don't move) says which parts of which snapshots a client read in full, sent after every tick whether or not the client controls anything. Each entity's baseline is the newest snapshot whose part holding it was acknowledged. The first version acknowledged whole snapshots inside input packets: at 300 pawns a snapshot was about 70 parts and almost never arrived whole, and a spectating client, sending no inputs, never acknowledged anything. `MAX_ACK_ENTRIES` (8) and one entry per tick keep a forged ACK cheap.
- **Remote entities write only what changes** (`TickStateComponent._place_between`). A client placed 154 remote pawns by writing all 42 of each one's values every tick, 9.5 ms a tick. It now writes what differs from what it last wrote, and blends only what moves; `follow_refresh_seconds` (0.5, entities taking turns) writes everything again now and then, in case something else wrote a property. Snapshots are stored as lists (`receive_authoritative_values`), without a dictionary per entity.
- **Diagnostics from the session** (profiling the networked mass battle). `connection_ended(peer, reason, details)` says why a connection ended, with ENet's round trip and loss (`get_link_stats`); stats gained snapshots sent and their bytes, parts received, deltas without a baseline and the largest packet each way; `COUNTING_STATS` names the ones diagnostics turns into rates (the owner's call: no hard-coded names in diagnostics). Snapshots carry the server's tick load and load step (`server_load_percent`, `server_load_step`), and `get_newest_snapshot_tick()` lets the samples show how fast the server really ticks (the owner's request). `get_match_options()` offers `snapshot_rate` and `delta_snapshots_enabled` in a start menu.
- **From the networking assessment** (T1.0). N1: with no welcomed client, the server gathers and encodes nothing (a host alone spent 1.4 ms a tick). N2: input packets that are empty, claim a tick too far ahead, or have the wrong number of fields are rejected before their timing counts. N3: an entity with only sync properties records its ticks and goes into snapshots. N4: snapshot lists of the wrong size are refused, counted (`schema_mismatches`) and warned about once per entity type, rather than read as empty.
- **Pawn M4 and 8.22.** `NetworkEntity.input_owner`: the server's input hooks go to the node holding the input (a pawn's ControllerManager). `TickStateComponent.round_position()` lets the CrowdMover round a position the way recording will (the owner's call: fold the crowd mover's guardrail into quantisation).
- **Audit fixes.** `PeerRecord`, `SnapshotPart`, `PartsRead` and `BaselineRing` replace dictionaries and lists read by position (tests make peers with `_new_peer`). `NetPackets.UNRELIABLE_TYPES` and `is_unreliable()` list unreliable types once (NetDebugModule had to be patched by hand for ACK). `StateEncoding.as_float32`, `NetworkSession.refresh_entities`, `send_now`, `handle_packet` and `set_tick_factor` lost their underscores, since other classes call them. NetMonitors is found by its file, so an export without `netcode/debug/` still loads. The tick rate left the content hash (the server hands it over in WELCOME, after the check, so a client at the default rate was refused by a 30-tick server). A client that stops sending inputs gets no margins and runs at normal speed, instead of acting on old ones until its clock resynced. A client no longer caps what its server sends (two large snapshots in one frame lost the newest). With no time to go back, `LagCompensation` rewinds nothing, instead of asking every entity. `follow_server_at` skips its searches for a frozen entity. Each list's encodings are kept rather than rebuilt for every snapshot. Commits 3dd18ba and 493d561.

## 2026-11-12

- Whole-number divisions marked as meant, and a Vector3-or-null return written as an `if`, so the editor doesn't warn.

## 2026-11-10

- **Several spheres in one rewind.** `LagCompensation.melee_spheres` checks the spots a sweeping swing passes through in one tick with one rewind; `melee` is a list of one.
- **Graphs in the editor's debugger.** `debug/NetMonitors` adds the netcode's numbers to Debugger > Monitors while the editor's debugger is attached.
- `NetworkSession.get_type_scene()`, which SpawnManager reads a type's team from. The tick rate chosen per match (tier 1 step 6): the server sends it in WELCOME. Commits cc5c8c9, fd9b3db, 22c60cf.

## 2026-11-09

- **Saving only what's read** (pawn spec 12.1). `TickStateComponent.history_interval_ticks`: a server saves state only on snapshot ticks, offline nothing (unless `NetworkEntity.keep_history_offline`), a client every tick; other ticks are only rounded. Saving was the biggest cost per pawn. `get_snapshot_interval()`, and changing `snapshot_rate` tells every entity.
- **Recording in C++.** `TickStateRecorder` records the state list with exactly the same values as GDScript once every entry is matched and its encoding settled; `TickStateComponent.use_native` (or `-- --gdscript-record`) compares. Commits ce7eeef and 696f755.

## 2026-11-07

- **Test tools out of the session.** The fake network and live feature switches moved to `debug/NetDebugModule`, an optional child that fills `packet_filter`; without one, the session does none of it (`docs/TEST_AND_DEBUG_CODE.md`).
- **Owners and pausing.** `set_entity_owner` (an `OWNER_CHANGED` packet, `NetworkEntity.change_owner`, `entity_owner_changed`) for swapping pawns; `player_leaving` fires before a leaving client's entities are removed, so PossessionCoordinator can keep a possessed pawn. `NetworkEntity.set_paused` stops every tick an entity causes; `_apply_role_to_driver` became the one place that decides what ticks. A player joining spawns nothing by itself.
- **World and client channels** (`WORLD_MESSAGE`, `CLIENT_MESSAGE`): systems that aren't entities, such as terrain edits, send their own messages, with a catch-up for late joiners.
- **Smaller packets and missing input.** Small ints take 1 or 2 bytes (`INT8`, `INT16`, `PROTOCOL_VERSION` 5). A missing input repeats for `missing_input_hold_ticks`, then fades over `missing_input_fade_ticks`. `TickStateComponent.add_state_properties()` adds entries for parts added after the scene was made (pawn spec step 6).
- **From the audit of 6df1464:** world messages are cleared on leave; the named input actions are part of the content hash; an entity whose only state is `save_state()` data goes into snapshots. Commits 7034e97, cf91dbb, 846a72d, 6df1464.

## 2026-11-06

- Navigation's own tags (`NavTags`) joined the content hash.

## 2026-11-05

- **Snapshots encoded in C++** (`NetCodec`, `use_native_encoding`), with `NetPackets.write_world`, moved from the session, as the fallback; the same bytes either way, and a library built for another format is refused.
- **Custom state in snapshots.** What `save_state()` returns goes to clients and is corrected like list entries (`PROTOCOL_VERSION` 4).
- **A real build check.** `content_hash()` covers the engine build, every physics setting and the game's files, not only the entity lists, or a build id (`BUILD_ID_SETTING`). It's worked out at host or join, not during the handshake.
- **Per-client limits.** `max_packets_per_second`, `max_bytes_per_second`, `max_packet_bytes`, checked before anything else; until the handshake only HELLO is accepted. An input packet is read whole before its timing counts.
- The server stops saving inputs nobody reads (`skip_input_capture`). The clock's drift is checked every frame. Network parts of a tick appear in the driver's profile. Commits 201c960 to 4aea6ae (profiling, Jolt, the networked nav stress test, review fixes in time dilation and the test bench).

## 2026-11-04

- **Rollback state** (netcode spec sections 5 and 6): `TickStateComponent` and `StateEncoding`, with following the server (`FOLLOW_SERVER`, `follows_during_rollback`, `follow_server_radius`, extrapolation) and replay fixes.
- **Stage v0 multiplayer:** `NetworkSession`, `NetworkEntity`, `NetPackets`, `NetClock`, `LagCompensation`: connection and handshake, prediction and reconciliation, interpolation, lag compensation.
- **Time dilation and the test bench:** clients run faster or slower to keep their lead (`from_lowest` leads), adaptive interpolation, and `NetFakeConditions` and `NetTestBench` for testing at a bad network's worst. Commits 0b9616f, 6a55405, 5d9659c.
