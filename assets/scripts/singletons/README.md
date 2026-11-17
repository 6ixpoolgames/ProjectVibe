<!-- Written by Claude (claude-opus-5-5), 2026-11-17: an index of the project's autoloads, beside their code. -->

# Autoloads

The project's four autoloads: the few services every game needs, reachable from any script by name. The owner wants as few as possible: only truly universal functionality lives here, and game rules and per-game defaults go in GameMode modules.

**Status:** built, tier 0. Not yet: the load ladder and the timing record still sit in the tick driver (see the refactor candidates in [CHANGELOG.md](CHANGELOG.md)).

| Autoload | What it is | Documented in |
|---|---|---|
| `TickDriver` | Runs all gameplay in numbered, fixed-length ticks, in a fixed phase order, and replays ticks for rollback | Here: [CHANGELOG.md](CHANGELOG.md); design in [NETCODE_SPEC.md](../../../docs/netcode/NETCODE_SPEC.md) section 3 and [SCALING_SPEC.md](../../../docs/scaling/SCALING_SPEC.md) section 7 |
| `NetworkSession` | Multiplayer: connecting, spawning, inputs, snapshots | [netcode/README.md](../netcode/README.md), [netcode/CHANGELOG.md](../netcode/CHANGELOG.md) |
| `GameMode` | Holds the game's rules as optional modules | [game_mode/README.md](../game_mode/README.md), [game_mode/CHANGELOG.md](../game_mode/CHANGELOG.md) |
| `NavMarkerManager` | Holds every nav marker and answers searches for them | [navigation/README.md](../navigation/README.md), [navigation/CHANGELOG.md](../navigation/CHANGELOG.md) |

Every class and function is in the generated reference (`python tools/docs/make_reference.py singletons`, which writes [REFERENCE.md](REFERENCE.md)).

## The tick driver

Everything that simulates registers with `TickDriver` and gets called once a tick, in phases: input, capture input, simulate, record. A frame runs as many ticks as the time covers (usually one, at most `max_ticks_per_frame`), so the game slows down rather than freezing when overloaded. `rollback(from_tick)` puts predicted parts back and replays later ticks, which the netcode uses on clients. The rules are under "How it works" below.

**Take part in ticks.** Call `TickDriver.register(self)` and write any of `_tick_input`, `_tick_capture_input`, `_tick_simulate`, `_tick_record`. `dt` is always the tick's length. Pawns, `TickStateComponent` and `NetworkEntity` register themselves.

**Time things in ticks.** `TickDriver.seconds_to_ticks(seconds)` for a time a designer typed; settings counted in ticks are written for 60 a second and converted with `ticks_at_rate()`, so they last as long at any tick rate.

**Random numbers.** `TickDriver.tick_rng(key, salt)` instead of `randf()`, so a replayed tick rolls the same.

| Setting | Default | What it does |
|---|---|---|
| `tick_rate` (or project setting `project_base/network/tick_rate`, or `-- --tick-rate=30`) | the physics rate | Ticks per second, chosen before a match |
| `max_ticks_per_frame` | 3 | Most ticks one frame may run; the rest of the time is dropped |
| `load_ladder_enabled` | on | When overloaded, AI pawns run every 2nd or 4th tick |
| `load_step_override` | automatic | Forces the load step (tests pin it to 1) |

## How it works

### TickDriver

One tick runs: `before_tick`, every `_tick_input`, every `_tick_capture_input`, every `_tick_simulate`, `after_simulate`, every `_tick_record`, `after_tick`. A frame runs as many ticks as the elapsed time covers (usually one), wrapped in `before_tick_loop` and `after_tick_loop`. `dt` is always the fixed tick length, never the frame's delta. A participant only gets the calls it has.

**Registering.**
- Order within a phase: lower `order` (`register`'s second argument, default 0) first; equal order keeps registration order. Every machine registers a level's pawns in the same order, so they run in the same order.
- Registering twice changes nothing. Unregistering an unknown object does nothing.
- Registering during a tick takes effect from the next tick. Unregistering during a tick stops its calls at once, so a pawn despawned mid-tick isn't simulated or recorded afterwards. A freed participant is skipped and dropped.
- Gotcha: if a participant also defines `_physics_process` (a fallback for when there's no driver), turn it off with `set_physics_process(false)` in `_ready`, not `_enter_tree`. Godot switches it on at ready, and the object would tick twice. See `samples/TickSamplePawn.gd`.

**Time.**
- At most `max_ticks_per_frame` ticks a frame; time beyond that is dropped (the game slows down instead of freezing) and counted in `dropped_ticks`.
- `tick_factor` scales how fast ticks happen (time dilation). The netcode nudges it on clients; it is 1.0 offline and on the server.
- A frame with more than one tick (dilation, catching up, or a tick rate above the physics rate) calls each participant's optional `_sync_collision()` between its ticks, so bodies collide with each other's latest positions. Frames with one tick pay nothing. `step()` is for tests and doesn't do this. Only entities with a `TickStateComponent` get it.
- `active = false` pauses ticking, and nothing builds up while paused.
- It runs in `_physics_process`, so physics queries are safe during ticks. The default `tick_rate` is the project's physics rate, and the autoload sets physics to the tick rate anyway (`physics_follows_tick_rate`), so it is one tick per physics frame.
- `move_and_slide` scales velocity by Godot's physics delta, not the tick. If `tick_rate` differs from the physics rate, a motor multiplies velocity by `get_physics_factor()` before `move_and_slide` and divides after.

**The load ladder** (pawn spec 8.21). Each tick's cost is measured against its budget (the tick's length). While ticks use more than `raise_above` of it for `raise_after_ticks`, `load_step` doubles (1, 2, 4). It halves again after `lower_after_ticks` ticks in a row under `lower_below`, or in a row where the load it predicts for the lower step, from what stepping up saved, fits under `raise_above` less `step_down_headroom`. `AIActivationManager` makes every AI pawn run at most every `load_step`-th tick, so an overloaded game sheds AI work, the bulk of a tick, instead of falling behind: the whole game's AI at 30 (or 15) ticks a second, with every timer still lasting as long (`Pawn.ticks_elapsed`). Players' pawns always run every tick. Tick numbers don't change, so nothing in the netcode does either. `load_step_override` forces a step; `load_ladder_enabled` off keeps it at 1. All the tick counts are written for 60 a second.

**Rollback** (netcode spec 3.5). `rollback(from_tick)` puts predicted participants back to how they ended `from_tick`, then replays every later tick up to the last finished one. A participant is predicted if it has `_rollback_load(tick) -> bool`, `_rollback_input(tick)`, `_rollback_simulate(dt, tick)` and `_tick_record(tick)`; `TickStateComponent` provides all four.
- While replaying, `is_resimulating()` is true (cosmetic effects must check it), `tick` reads as the tick being replayed, and `tick_rng` rolls repeat exactly. Input phases don't run; saved inputs are restored instead.
- Everything not predicted stays where it is during the replay, the standard accepted inaccuracy. The exception is an entity in `FOLLOW_SERVER` mode with `follows_during_rollback` on: it stands on server data, extrapolates past it on its velocity, then returns to where it was.
- Loading is staged. Resimulated participants load first; if none could, nothing happens and it returns false. Following ones then join if they want to and are near one of those (`wants_to_join_rollback`). Then collision positions sync, then each one's optional `_rollback_after_load(tick)` runs, so a floor check there sees everyone else in place. `is_resimulating()` is true through all of this.
- When two or more participants replay, each one's optional `_sync_collision()` runs after loading and after each replayed tick. Each one's optional `_rollback_finished()` runs once the replay is over, before `after_rollback`.
- Allowed between ticks or from `before_tick` (where the netcode applies snapshots). During the phases, or during another replay, it warns and returns false. With physics bodies, call it during the physics frame, or `move_and_slide` uses the rendered frame's delta and replayed movement is the wrong length.
- A participant that no longer has `from_tick` keeps its current state and sits the replay out. It returns false, with no side effects, if nothing could be loaded or `from_tick` is in the future.

### NetworkSession

**One tick on a client.** `before_tick`: world messages, then snapshots (which may roll back), then remote entities are moved; the tick's phases; `after_tick`: inputs and snapshot acknowledgements are sent. **On the server.** `before_tick`: received inputs are queued; the phases; `after_tick`: snapshots are sent (on snapshot ticks).

**Rules** (tests in `tests/net_selftest.gd`):
- A client with a different content hash is refused with a message saying so. The hash covers the packet format, tag sets, input actions, engine build, physics settings, every entity type's schema, and the game's files. Set the project setting `project_base/network/build_id` to name a build instead of reading its files: the normal way for a release, and also for the same project on different operating systems, since line endings can differ. The tick rate isn't in it: the server hands it over in WELCOME, after the check.
- Input for an entity the sender doesn't own, broken packets of any kind, and too many packets from one client are dropped (`max_packets_per_second`, `max_bytes_per_second`, `max_packet_bytes`; a client that hasn't passed the handshake may only send HELLO).
- A snapshot older than the newest one seen is dropped. Input for a tick the server has already run is dropped, and the client gets corrected. The server repeats the last input when one is missing, and never rewinds for movement.
- A client that joins late gets everything that exists. Entities still owned by a client that leaves are removed; `player_leaving` fires first, so something can take back what it wants to keep (`PossessionCoordinator` does this for a possessed pawn, which stays in the world with no owner).

**Time dilation** (netcode spec 4.2). The server reports how early each client's inputs have been arriving. A client cutting it too fine speeds up at once, going by the last half second. It only slows down again if the last 5 seconds have all been safe, so a rough connection keeps the lead it has shown it needs; its lead settles on the smallest that gets inputs there in time. Only clients dilate. A client well behind where its clock says it should be, after a freeze say, jumps straight back instead of slowly catching up, because every tick behind is another input arriving too late.

**Snapshots.** Each client gets each entity's changes since its baseline for that client (delta snapshots, netcode spec 11.4.1): the newest snapshot whose part holding that entity it acknowledged. An encoding is made once per entity and baseline and shared. A snapshot is cut into parts of at most 1100 bytes of entities, each its own packet with the same tick, under ENet's packet size (1392 bytes); a lost part doesn't lose the snapshot. The server keeps which entities went in which part for 48 ticks, so an ACK can say which arrived. A baseline older than 48 ticks, or none, means the entity goes in full. The client keeps 64 ticks of received state per entity to decode deltas against. A delta entity's id has bit 31 set; its state list is the ticks back to the baseline, then masks of 30 entries each, then the changed values.

**Packet formats.** Every packet starts with a type byte. `u8`, `u16`, `u32` and `u64` are unsigned, the others signed.

| Packet | Direction | Fields after the type byte |
|---|---|---|
| HELLO | client to server | protocol `u32`, content hash `i64` (12 bytes) |
| WELCOME | server to client | tick rate `u16` |
| REFUSED | server to client | reason (UTF-8 string) |
| PING | client to server | client time in microseconds `u64` |
| PONG | server to client | the PING's `u64`, server tick `u32` |
| SPAWN | server to client | entity id `u32`, owner `u32`, type name, position (or the missing marker) |
| DESPAWN | server to client | entity id `u32` |
| OWNER_CHANGED | server to client | entity id `u32`, new owner `u32` (9 bytes in all) |
| INPUT | client to server | entity id `u32`, newest tick `u32`, newest snapshot tick read `i32` (-1: none), count `u8` (1 to 16), then that many input lists, newest first |
| ACK | client to server | count `u8` (up to 8, newest first), then per tick: tick `u32`, part count `u8`, one bit per part (1: read) |
| SNAPSHOT | server to client | tick `u32`, margin short `i16`, margin long `i16`, missed inputs `u32`, server features `u8`, load percent `u8`, load step `u8`, part `u8`, part count `u8`, entity count `u16`, then the entities |
| WORLD_MESSAGE | server to client | channel name hash `u32`, bytes |
| CLIENT_MESSAGE | client to server | channel name hash `u32`, bytes |

INPUT, ACK, PING, PONG and SNAPSHOT go unreliably; the rest are reliable. Input packets repeat the last `input_redundancy` inputs (3 by default), so three lost packets in a row are needed to lose one. The margins in a snapshot are the worst input margin over the last 30 and the last 300 input packets (ticks early; 32767: unknown). The server's checks on INPUT: the sender must own the entity, the count is 1 to 16, the newest tick isn't a history length or more ahead of the server's, and every list has exactly the entity's input fields. On ACK: at most 8 entries, each tick once, no future ticks. A server keeps at most 128 packets from one client between ticks.

### GameMode

Which modules start comes from the project setting `project_base/game_mode/modules` (script paths, with a `.release` override for release builds), else `DEFAULT_MODULES`. An empty list starts none, and the game still runs. A path that doesn't load or isn't a `GameModeModule` warns and the game carries on without it; adding a second module of one type warns and keeps the first. Checked in `game_mode/tests/game_mode_selftest.gd`.

### NavMarkerManager

It stores every nav marker, gives each a stable id, and answers searches. It is written so its insides can move to C++ later without changing its callers: callers use only the public functions, which take and return plain values; searches return ids, and `get_marker` fetches the full data only when needed; what searches read sits in flat arrays ("rows"); a chunk registers its whole list in one call; searches call no script code in their loops; requests apply on the next tick; and ids come from an FNV-1a hash written out in the script, because Godot's `hash()` could differ from a C++ version.

**Rows.** Every marker is one row, the same index in each array (`_positions[7]`, `_masks[7]` and `_ids[7]` describe one marker). A removed marker's row is reused later.

**Search.** The world is split into square cells (`CELL_SIZE`, 32 m) and a search only looks at nearby cells. Each cell keeps a linked list through the rows: `_cell_heads` gives a cell's first row and `_next_in_cell` the row after each one, so adding and removing a marker is instant. Searches break ties by lower id, so every machine picks the same marker.

**Odd cases** (checked in `navigation/tests/nav_marker_manager_selftest.gd`): a duplicate id, an undeclared tag or a null marker is refused, with one warning for the whole list; an unknown id is harmless; releasing a chunk that isn't registered does nothing; a search with an undeclared or empty tag finds nothing and doesn't add the tag. Module rules are at the top of `NavMarkerModule.gd`, checked in `navigation/tests/nav_markers_selftest.gd`.

**The debug report.** If markers exist of a type no module announced, it warns once per type, after registrations have gone quiet for `report_quiet_seconds`. It warns again only if a new unclaimed type appears, or a type loses its last module. Debug builds only. Turn it off with the project setting `project_base/nav/report_unhandled_markers`, for a game that leaves a type unhandled on purpose.

## Tests

`singletons/tests/`: `tick_driver_selftest` (phases, order, registering mid-tick, the frame limit, rollback) and `tick_rate_selftest` (a match at another tick rate). The load ladder is checked in `pawn/tests/tick_step_selftest` and `game_mode/tests/game_mode_selftest`. Run them with `bash tools/run_tests.sh <name>`. The other autoloads' tests are with their systems.
