# State Store Spec v0.5 (agreed direction; steps 1 to 5 built, and ability spec parts 1 to 5)

*Written by Claude (claude-opus-5-5), 2026-11-19, from the discussion with the owner the same day.*

**Status:** the code audit is done (section 12) and the measurements are in (section 13). Steps 1 to 5 are built on `refactor/tick-core`, rewriting the classes that run on ticks in place (the owner, 2026-11-19; sections 13.4-13.12); master keeps the working v0 to go back to. Details still open are in section 14.

**What it is:** one central record of everything that matters to play, tick by tick: a C++ service with a GDScript twin, holding every gameplay entity's state in plain columns, with a history of recent ticks. Rollback, lag compensation, snapshots, replays, AI sensing and diagnostics all read it, instead of each gathering its own copy from the nodes. Around it: a refactor of the tick driver, and deterministic replay.

**Why:** the 300-pawn mass battle (2026-11-18) ran at half speed with every AI pawn already at the load ladder's lowest rate. Most of the main thread's cost was reading nodes and calling each pawn's parts one by one, not computing. Worker threads only help once data is gathered once into plain buffers, and several systems gather the same data today (section 2).

## 1. Decided

| Question | Answer | Whose call |
|---|---|---|
| One central record | Everything recorded each tick goes through one C++ service that builds its tables from what systems declare, a grown version of the pawn table's columns. It absorbs every consumer | the owner |
| Source of truth | The store is the final truth at tick boundaries: commit at the end of each tick. Nodes are the working copy during a tick. The client accepts the delay for what it doesn't predict | the owner |
| What records | Every gameplay entity: whatever play and replay need to be deterministic | the owner |
| Slots | Never move. A freed slot is emptied, waits until no frame in the history still holds its old occupant, then is reused with a new generation | the owner |
| References and lists | Object references become ids. Lists of varying length become a fixed number of slots holding ids | the owner |
| Holders | Node and scene structure is projected onto a holder per entity (as `AIContextComponent` is for the AI), updated on events; the store reads from the holder | the owner's idea; section 6 |
| Replays | Play back the full record, so they're exact on any machine. Every pawn's applied input command is recorded, AI included. No AI runs during a replay | the owner |
| Branches | Starting play from a rewind is a branch, the only time AI decisions run again. Running forward is deterministic on the same machine; physics drift is corrected from the store | the owner |
| AI on a branch | AI state is saved at keyframes so a branch resumes where the AI was. What's saved is declared like any other column and pruned at design time | the owner |
| Designers own cost | The cost of what they add is shown (bytes per entity, per column), not blocked | the owner: "we can't baby proof everything" |
| Physics | Drift correction from the store, kept as a safety net; physics re-ran exactly on one machine (13.3), so deterministic physics of our own isn't needed for same-machine re-runs | the owner; measured 2026-11-19 |
| How it's built | A full refactor of everything that runs on ticks, around the tick driver and the store, on a branch, rewriting classes in place: no parallel old paths or backup switches. Master's v0 is the way back | the owner, 2026-11-19 |
| Ability state | Abilities are designed to keep tracked state small; an ability design doc comes with this refactor | the owner |
| Twins | The store has a GDScript twin. The per-entity recording paths it replaces are retired | the owner |
| Lag compensation | Tests against the history's hitbox positions; nothing is moved back and no physics query runs (12.2) | the owner |
| The client's store | Received frames (what the server said) and predicted frames (what it simulated for its own entities), compared locally to reconcile. Only inputs go to the server (12.2) | the owner |
| Consolidation | Every per-system history (12.2's table) folds into the store | the owner |
| Measurements | Not the bot-client profile (it measures code being replaced). A state inventory, the cost of one dispatch call, and a drift test (section 13) | the owner |

## 2. What it replaces

Today, each tick, the same state is gathered several times:

| Today | Reads | Where it goes |
|---|---|---|
| `PawnTable.refresh` (C++) | position, team, velocity, yaw, grounded, stat columns | AI sensing, the pawn grid, swing hit checks |
| `TickStateComponent._tick_record` with `TickStateRecorder` (C++ fast path) | each entity's declared state list | rollback history, snapshots |
| `NetworkEntity._tick_record` (GDScript) | position, every tick, on the server | lag compensation (64 ticks) |
| `ReplayMotionChannel.write_tick` (GDScript) | position, yaw, velocity, six flags | replay motion, packed by `ReplayMotionPacker` (C++) |
| `ReplayInputChannel` | input | replay inputs |

Each pawn also has about three participants registered with the tick driver (the pawn, its `TickStateComponent`, its `NetworkEntity`), each called in its phases, even on ticks a stepped pawn skips: about 1,800 calls a tick at 300 pawns. Measured (13): the calls themselves cost only about 0.3 ms a tick; the cost is the work each does, mostly reading node properties one by one.

## 3. Terms

| Term | Meaning |
|---|---|
| Tick | One fixed step of play, numbered. The tick driver's unit of time |
| Frame | The store's record of every entity at the end of one tick |
| Tick history | The last N frames, kept in a rotating buffer (a ring buffer): tick T is in frame T mod N, overwriting the oldest. Allocated once |
| Layout | The columns one kind of entity has (a pawn, a projectile, a door). Entities with the same layout share a table. ECS calls this an archetype |
| Column | One value per entity in a table: a type, an encoding, what it's used for, and how much history it keeps |
| Slot | An entity's row in its table. It never moves while the entity lives |
| Handle | Slot plus generation. A handle to a freed and reused slot doesn't match, so stale references are caught |
| Gathered | A column read from nodes at the end of every tick (position, velocity) |
| Pushed | A column a holder writes when something happens (target changed, ability added, a stat changed). Applied at the next gather, so a tick always reads one consistent frame |
| Holder | A part on an entity that mirrors its node structure as plain data and ids, and writes it into the store (section 6) |
| Recorded state | State that can't be worked out again. It goes in the store |
| Derived state | State a re-run rebuilds by itself from recorded state (a path from the nav mesh, a score). Not recorded every tick; saved at keyframes only where a branch needs it warm |
| Keyframe | A complete frame written into a replay at a fixed interval, so playback can start from it |
| Applied input command | The `InputCommand` the simulation actually used, after the server's checks and missing-input cover |
| Branch | Play started from a point in a replay or the history. New history from there |

## 4. The model: commit at the end of the tick

```
tick T:   [apply pushes]  input  capture  simulate  record ──► frame T committed (immutable)
                                                                   │
            jobs read frame T on workers ◄─────────────────────────┘
            (sensing, snapshot encoding, replay packing, checks)
tick T+1: results due at T+1 applied ─► input ... ─► frame T+1
```

- **During a tick**, nodes are the working copy: physics bodies and GDScript abilities change them.
- **At the end of the tick**, one gather commits them into frame T. From then on frame T doesn't change (except section 8's rollback rule).
- **Anything that changes state from outside a tick** (a correction, a rollback, a replay seek, a branch, a spawn) writes the store, and the store writes the nodes through their holders before the next simulate.
- **A debug check**: at the start of a tick, the nodes' values must match the last frame. A mismatch is a write that skipped the store. This doubles as the determinism tripwire.
- **Results land on a fixed tick** (the scaling spec's rule 3). Sensing reads frame T and its answer is used at T+1, always: stale by a designed amount, which is deterministic. Stale by however far a machine fell behind would not be.

## 5. Storage

### 5.1 Layouts, columns and slots

- **One table per layout.** A layout is built from what the entity's parts declare (section 6.1), before its first recorded tick, and is the same on every machine: its hash goes into the join check.
- **A column** has: a name, a type, an encoding (shared with the codec, `state_encoding.h`), and flags for its uses: rollback, replicate, replay, lag compensation, AI keyframe, and its history depth.
- **Types are plain data only:** whole numbers, floats, vectors, booleans as bits, enums, bit masks, ids (entity handles, ability indexes, resource ids, interned names such as states and actions).
- **Slots never move.** A freed slot goes into a queue in the order it was freed and is reused only once the history is deeper than its age. Reuse order is then the same on every run. The cost is a few dozen empty slots at most, which is small (owner and Claude agree memory isn't the bottleneck).
- **Order:** anything whose result depends on order (applying job results, say) goes by entity id, not slot.

### 5.2 Lists

A list of varying length becomes a fixed number of slots: active effects as 8 × (effect id, stacks, ends at tick), say. Each list sets its capacity and what happens when it's full (refuse, replace the oldest, replace the weakest), as a setting designers see. A list with no sensible cap stays out of the store and must be derived state.

### 5.3 The tick history

- A rotating buffer of frames, allocated once. Its depth is the deepest any consumer needs: rollback (64 ticks today), lag compensation (64), snapshot baselines (48), plus how far a job may run behind.
- **Per-column depth:** lag compensation needs positions every tick; full state is needed only on snapshot ticks on a server. A column keeps only the history its uses need.
- **A rough size:** 300 pawns × 40 values × 8 bytes × 64 frames is about 6 MB, before keeping less history for most columns. To be checked by the state inventory.

### 5.4 What isn't plain data, and where it goes

| Today | Becomes |
|---|---|
| A node reference: the current target, a hit's attacker | An entity handle |
| An `AbilityBase` object | The ability's index in the entity's ability list |
| A `Resource` (an effect, an ability setting) | A resource id from a registry, the same on every machine |
| A state or action name (`&"Combat"`, `&"sprint"`) | An interned id, as tags and input actions already are |
| A list (effects, queued hits) | Fixed slots of ids (5.2) |
| A `save_state()` dictionary | Nothing uses one outside the tests; the hook is quarantined (6.4) |
| Spawning and freeing | Spawn and despawn records in the store |
| Engine state we can't see (physics contact caches, sleeping) | Not recordable: the main source of physics drift (section 10) |

## 6. Writing

### 6.1 Declaring columns

- **Systems declare what they read or write**, as the pawn table's columns work today: required by a system, enabled by hand, or added by a game, plus pushed columns.
- **Entities declare their state** as `TickStateComponent` lists do today (designer-friendly: any property), and the store compiles each layout's list into accessors once.
- **AI behaviours declare the variables they save** for keyframes the same way.

### 6.2 Gathered columns

One C++ pass at the end of each tick reads every gathered column of every entity through the compiled accessors and rounds each value to its encoding. This is `TickStateRecorder` made general, with no per-entity GDScript call. Later, C++ systems (the crowd mover) can write their results straight into the store instead of into nodes.

### 6.3 Pushed columns and holders

- **A holder** mirrors an entity's node structure as plain data: its target as a handle, its abilities as indexes, its active effects as slots. It's updated when something happens, not every tick.
- **It writes into the store when that happens** (as `Stat.set_value` pushes into the pawn table today), applied at the next gather.
- **It works both ways.** A rollback, a seek or a branch loads the store, and the holder writes back into the nodes, turning handles back into nodes through the slot map.
- Most of an entity's state is pushed (target, abilities, team, stats); only what physics changes is gathered every tick (position, velocity, grounded). So the per-tick gather stays small.
- Candidate holders: `ControllerManager` (input), `AIContextComponent` (AI), `AbilityManager` (abilities), `EffectManager` (effects), the stats. To be settled per system in the reviews (section 14).

### 6.4 Custom state: quarantined

`save_state()` and `load_state()` (bespoke state as a dictionary, saved whole each recorded tick, sent whole in snapshots) have no users outside the tests (checked 2026-11-19). The owner's call: quarantine it rather than remove it. It's flagged, nothing new uses it, and it stays on the main thread outside the store, until it's revisited with the AI's optimisation for this refactor (AI state that doesn't fit columns may want it). State that doesn't fit a single value uses fixed slots (5.2) or several columns meanwhile.

## 7. Reading

| Reader | How |
|---|---|
| C++ jobs (sensing, snapshot encoding, replay packing, checks) | Direct views into frozen frames, on any thread. No node access |
| GDScript | `get_column(name, tick)`, `get_row(handle, tick)`, the same calls on the twin |
| Rollback | Loads a frame into the store, then writes nodes through holders |
| Lag compensation | Positions from the history; `NetworkEntity`'s own history goes |
| Snapshots | Deltas between frame T and each client's baseline frame, encoded per baseline once and shared, on workers |
| Replay | Selected columns of each frame, packed on workers, written by the replay writer's thread |
| AI sensing | The frame it reads today from the pawn table |
| Diagnostics | A frame's checksum each tick; sizes per column; costs per consumer |

## 8. Jobs and overload

- **Jobs that change play** (sensing, AI, movement) have a fixed due tick. If one is late, the main thread finishes it: it costs time, never a different result.
- **Jobs that only observe** (snapshots, replay, diagnostics) read frames that never change, so they may run behind by up to the history's depth. Each has its own rule when it can't keep up:
  - snapshots skip a send (deltas recover)
  - diagnostics drop
  - replay never drops: the main thread finishes its job instead
- **The tick history is fixed memory; the replay recorder archives it.** Old frames are overwritten in place, never freed. Anything kept longer than the history's depth is saved by the replay recorder: it packs frames into blocks (keyframe plus changes) on workers and hands them to the replay writer's own thread, which compresses and writes them to disk. That's why replay may never fall behind by more than the history's depth. Today's `ReplayRecorder` and `ReplayWriter` already work this way for their own channels; they move onto frames.
- **Rollback rewrites the past** on a client: a resimulation from tick T rewrites frames T to now. Observer jobs reading those frames must finish first (the change guard waits for them), or read a copy.
- **One thread pool.** Navigation's `WorkerPool` folds into the `JobScheduler`, so a 4-core machine doesn't run two sets of threads. The replay writer keeps its own thread for the disk.

## 9. The tick driver

- **Batched passes per phase.** Instead of calling each participant, a phase runs systems that loop over their entities, in C++ where it's hot. A GDScript participant still works, on the main thread, as the fallback.
- **Pawns grouped by step.** A pawn running every 4th tick isn't called on the ticks it skips.
- **Decisions that depend on time are recorded.** The load ladder steps pawns from the measured tick cost; the step in force each tick is a recorded decision, not recomputed on replay. The same for anything else timed by the machine (async builds finishing, path budgets), which must land on a fixed tick or be recorded.
- **Time is counted in ticks** *(the owner, 2026-11-19)*. The store's history, deadlines and records are all in ticks. The 120-unit fine clock (networking T1.1) assumed 120 ticks a second, which may never come, so it isn't part of this design. Steps decided by the server and announced ahead still are.
- **One timing tool.** `TickDriver.profile` folds into `PerfScopes`.

## 10. Deterministic replay

- **Playback** reads the record, so it's exact on any machine. Nothing is simulated. No AI runs.
- **Recorded:** keyframes of the store (with AI state, 11), every pawn's applied input command each tick it runs, spawns and despawns, the recorded decisions (9), and a checksum of each frame.
- **The controller layer is where determinism starts.** Everything before the applied command (players, the AI, the AI's jobs) needn't be deterministic; everything after it (abilities, effects, movement) must be, on one machine.
- **A branch** loads the nearest keyframe before the branch point, re-runs recorded inputs up to it, then hands control to players and the AI.
- **Drift correction:** while re-running, each tick's checksum is compared with the record; where they differ, the store's frame is applied (a hard correction, as a client applies the server's state). Past the end of the record there's nothing to correct against, and that's new history anyway.
- **Directors** (12.4): systems that decide from outside the core (spawning, AI switch-off and tick steps, the load ladder, possession, streaming, terrain edits, nav commits) have their outputs recorded as inputs, off while re-running to a branch point, live after it.
- **Sources of drift to close or record:** the load ladder and other time-based decisions (9); async work finishing on different ticks; wall-clock reads; randomness not from `tick_rng`; iteration orders that depend on instance ids; physics engine state (5.4).
- **Physics:** measure drift first (13). If it's small and rare, correction is enough. Deterministic movement of our own for pawns (the C++ mover on the wishlist: kinematic collide-and-slide plus separation) is the likely next step; full rigid-body physics of our own is not planned. Jolt has a cross-platform determinism build option; whether Godot's build uses it is still to check.

## 11. AI state

- **Saved at keyframes,** so a branch resumes where the AI was:
  - memory (`AIMemoryStore`): per remembered entity, awareness, certainty, last known position, last seen tick, threat, fading facts. The current target fits here, as a flag on one entry
  - the state manager's current and forced state
  - the behaviour manager's running behaviour and start tick, each behaviour's last end tick (cooldowns), the persistence curve, what it's waiting on
  - each behaviour's declared variables
  - a game's own inputs set with `set_input`
- **Not saved:** what each decision works out fresh (distances, readiness, scores), the sensing schedule and score jitter (from the tick number).
- **Pruned at design time:** built-in behaviours keep only ids and ticks. A designer's added variable is saved without extra code, and its cost is shown. A development check flags a variable that changes but isn't declared, as `rollback_coverage_selftest` does for pawns.

## 12. Abilities

The ability spec, [ABILITY_SPEC.md](../abilities/ABILITY_SPEC.md), has the detail; the ability refactor comes before the store (the owner). Agreed so far (the owner, 2026-11-19):

- **Three layers.** The *kind* is the code, on the ability node's script (`MeleeAttackAbility.gd`), compiled once and shared. The *definition* is a variant's values, a Resource the node references. The *state* is per pawn, in the store. A thin node holds only its definition reference, its pawn's handle and its column numbers.
- **Variants** are shared definition files, one based on another: the intended workflow for the shipped base and for designers and modders. **Embedded definitions** (Godot's "Make Unique" on the node) stay for quick tweaks while prototyping; saving one as a file promotes it to a variant.
- **Extending:** new data before new code (more keys, more steps), a subclass of the kind for new logic (a swing that homes in).
- **A missing or broken definition falls back** to the kind's own defaults **and announces it** (session log, diagnostics), naming the pawn and the slot. Definitions are in the join check's hash, so connected machines fall back the same way; the replay records it.
- **Timers are tick deadlines** (`ready_at`, `started_at`, `buffer_until`), never countdowns. Elapsed time is worked out from them. A rate change (haste) or a pause re-bases the deadline.
- **Swing arcs as keys** (time, angle, height, reach), interpolated; animation reads the same keys.
- **Nothing that adds up every tick** unless it's declared state.
- **Steps stay thin child nodes**, reusable building blocks the ability declares it uses (as Unreal's ability tasks are). Each step kind's code is shared; a step node can be run several times in one ability with different values.
- **No-code step timelines are the typical way** to sequence steps ("chains" until 2026-11-21); a bespoke ability script that runs the same step nodes is the alternate. In a step timeline, each entry names a step node, the values it runs with, and a **start rule**: at +N ticks from the ability's start; on another entry's start or end (with the end reasons that count, so a cancelled windup doesn't swing), optionally plus a delay; when a condition holds; or the first of several. Entries can run at the same time (turn and windup both at +0). A step decides its own end (its length or its condition), or ends with another entry or the ability.
- **Step timeline state** per entry: the tick it started and the tick it ended (-1 if not yet), so "at +10" is a deadline. Rules are checked in list order; a step that ends can start the next in the same tick, with the existing guard against loops.
- **Step conditions** are small data Resources over named values (angle to target, an action held, grounded), like the AI's `AICompareCondition`; the AI and abilities may share one condition base.

## 12.1 Systems to review *(tentative; each is discussed in turn and filled out before building)*

| System | What it likely means for the store | Status |
|---|---|---|
| Controllers | Input columns through the `ControllerManager`; the applied command recorded for every pawn; who has a pawn as a pushed column | reviewed 2026-11-19, fits |
| Abilities and steps | Section 12 | being designed |
| AI | Section 11 and 12.7 | reviewed 2026-11-19 |
| Effects | 12.6 | reviewed 2026-11-19 |
| Stats | 12.6 (the deeper stats pass stays for later) | reviewed 2026-11-19 |
| Netcode | 12.2 | reviewed 2026-11-19 |
| Spawning, world, streaming, terrain, navigation | 12.4 | reviewed 2026-11-19 |
| Visuals and animation v0 | 12.5 | reviewed 2026-11-19 |
| Replay | 12.3 | reviewed 2026-11-19 |
| Diagnostics | 12.3 | reviewed 2026-11-19 |
| Tick driver | Section 9 and 12.2 | reviewed 2026-11-19 |
| Pawn and the crowd mover | 12.8 | reviewed 2026-11-19 |
| Player, camera, UI, jobs, tags, platform | 12.9 (a light pass) | reviewed 2026-11-19 |

## 12.2 The tick driver and netcode: findings *(Claude, 2026-11-19, from reading TickDriver, NetworkEntity, TickStateComponent, LagCompensation, NetClock and NetworkSession)*

**The same data is kept many times.** Per entity, today:

| History | Where | Depth | Becomes |
|---|---|---|---|
| Own state (rollback, snapshots) | `TickStateComponent` ring; a server saves only snapshot ticks | 64 | Store frames |
| Inputs | `TickStateComponent` input ring | 64 | Input columns (applied commands, every tick) |
| Positions for lag compensation | `NetworkEntity` hit history, a fixed 64 that ignores the rewind cap setting (its REFACTOR row) | 64 | Store frames (positions every tick) |
| Server state, client side, for delta baselines | `NetworkSession._baselines` (`BaselineRing`) | 64 | Server frames in the client's store |
| Server state, client side, for placing followed entities | `TickStateComponent` authoritative ring | 64 | The same server frames |
| Server state, client side, for reconciling | `NetworkSession._reconcile_values` (dictionaries, newest only) | 1 | A per-column compare of server frame and predicted frame |

**Tick driver:**
- **One call per participant per phase,** found with `has_method` when registered; a pawn has three participants. Replaced by batched passes (section 9).
- **The load ladder decides from measured time,** inside the universal driver (its REFACTOR row: the rule belongs in a GameMode module). It becomes a recorded decision, and the driver only reports each tick's cost.
- **Saving depends on role** through three switches set by `NetworkEntity.refresh_input_saving` (`skip_input_capture`, `rounds_every_tick`, `history_interval_ticks`); offline saves nothing. With the store, every machine commits every tick (deterministic replay needs it offline too), and what each column keeps is its use flags and depth.
- **Rollback** calls each participant's load, input, simulate and record. With the store: load the frame, holders write the nodes, re-run with the batched passes.
- **Good as it is:** `tick_rng` (rolls from entity, tick and salt), fixed due ticks for queued effects (`after_simulate`), catch-up capped at 3 ticks a frame with collision synced between them.
- **Two timing tools** (`TickDriver.profile` and `PerfScopes`): one goes.

**Lag compensation moves bodies.** `LagCompensation` moves every other entity's body back to where the shooter saw it, runs a physics query, then puts them back, and only positions are kept. The standard instead: test against the history without moving anything (a hitbox history). The store's frames hold positions every tick, and `AIPawnGrid.find_touching` already tests exact capsules from plain data, so a rewound swing becomes the same test against frame T − k.

**Snapshots (server):** `_send_snapshots` loops over clients and entities on the main thread, reading state from the history but **sync values from live nodes** (`get_sync_values`), and `save_state` data. Encodings are shared per (entity, baseline). With the store: sync values are columns committed at the tick's end, and encoding is a worker job diffing frame T against each baseline frame; parts, ACKs and packet sending stay on the main thread as transport.

**The client's store (proposal, answers the open question in 14):** two histories, with the same layouts.
- **Received frames:** what the server said, by server tick, filled from snapshots (deltas rebuilt against an earlier received frame). They replace `_baselines`, the authoritative ring and the delta baselines. Followed entities are placed by interpolating between two received frames at the render tick: one batched pass instead of `follow_server_at` per entity.
- **Predicted frames:** what this client simulated for the entities it predicts (its own pawn, any marked predicted), by its own tick. Reconciling compares the received frame with the predicted frame for the same tick, column by column; a mismatch loads the received values into the predicted frame and re-runs from there.
- The client's clock, its time dilation and adaptive interpolation stay on the wall clock: a client's simulation isn't the one replays re-run, so that's fine.

**Determinism on the server.** Which inputs arrive in time depends on the network, so the applied command is what's recorded (already decided). Packet arrival order then doesn't matter to a re-run. Remaining order hazards are small: `_on_peer_disconnected` walks entities in insertion order (despawns should go by id); spawns and despawns become records anyway.

**NetworkSession** is about 1,900 lines doing many jobs (its own REFACTOR row). The snapshot sender and receiver change the most with the store, so that's the time to split it: connection and handshake, link statistics, clock and time dilation, world channels, snapshot sending, snapshot receiving. The join check's per-type `get_schema()` becomes the layout hash, plus the definitions' hash (ability spec). **Streamlining the netcode, apart from the store** *(accepted by the owner 2026-11-19, for the refactor)*:
- **One packet a tick from a client:** today it sends one input packet per entity it controls plus a separate ACK packet. One packet with every entity's inputs (with their redundancy) and the ACKs is the standard, and networking T1.4's "input batching".
- **Fewer switches.** `NetworkSession` has 13 on/off settings, many from comparing approaches while building it. Keep the ones that are real game choices (prediction, for MOBA-style games; lag compensation; predicting other players; the extrapolation cap). Make the settled ones always on (delta snapshots, time dilation, adaptive interpolation, reconciliation, correction smoothing) and remove the off-by-default experiment measured as no clear difference (`follow_during_rollback`, with the rollback-joining code in `TickStateComponent` and `TickDriver` behind it). The C++ encoding switch stays as the twin's backup.
- **Roles:** with those gone, `LOCAL_PREDICTED` and `REMOTE_PREDICTED` differ only in who supplies the input; one "predicted" role plus `is_local` may do. To check.
- **One kind of state.** The three property lists (input, state, sync) and the `save_state()` dictionaries become columns with flags (rollback, replicate), removing the separate custom-value path through snapshots and reconciling.
- **Spawn packets** name the entity type as a string; the registered type list is in the join check, so an index is enough.
- **`stats`** is an untyped dictionary of about 30 keys; a typed record, with the diagnostics rework.
- **Its REFACTOR rows:** the packet limits as exports, the base autoload naming a debug class, the tag sets listed by hand in the join check, a typed record for link statistics, the test-only `receive_authoritative_state`, and the missing-input defaults copied into `ControllerManager`.

Small items found on the way: a ternary at line 1596 with stray tabs inside it, an unused parameter in `handle_packet`, and a server accepting a SNAPSHOT packet into its inbox before rejecting it.

## 12.3 Replay and diagnostics: findings *(Claude, 2026-11-19, from reading replay/ and diagnostics/; accepted by the owner the same day)*

**Replay today** records six channels, each gathering its own data in GDScript once a tick ([REPLAY_SPEC.md](../replay/REPLAY_SPEC.md) section 3): motion (position, yaw, velocity, flags), input (the `ControllerManager`'s command), spawns, world (chunks and sources), gameplay events (from signals connected per pawn), and diagnostics.

**What changes:**
- **Motion and input become frames.** A block opens with a keyframe (a whole frame of every column flagged for replay) and each tick after it is the frame's changes since the last tick, applied commands included. That's the same delta encoding snapshots use, so **one encoder serves snapshots and replays**, on workers. The motion and input channels, their GDScript gathers and `ReplayMotionPacker`'s separate packing go.
- **Spawns become the store's spawn and despawn records.** The scene name becomes the entity type's index. The replay's own ids (entity ids, or local ids from 2^30 up for pawns that aren't networked) give way to entity ids, since every gameplay entity has one.
- **Gameplay events shrink.** Most of today's events are state changes that playback can work out from frames (ability and step started, AI state, behaviour and target, frozen, possessed, dead). Only one-tick things stay as events: hits, intercepted hits, falls. The viewer's timeline can still list everything, worked out from the frames when the file is read. That also removes the per-pawn signal connections and their closures.
- **The world channel stays** for now; whether chunk builds land on fixed ticks is the world audit's question.
- **The diagnostics channel stays**: it's how the game ran, not game state.
- **The viewer plays the store.** It loads frames into a store and the same state-driven visuals the live game uses draw them (section 10, ability spec 10), instead of the viewer's own ghost drawing from channel dictionaries. One visual path for live play and playback.
- **Size:** today about 2.7 MB a minute for 153 pawns, motion only. Full keyframes are larger; the state inventory (13) gives the number, and each column's replay flag lets a game choose.
- **Measured:** `replay.record` took 4.9 ms a frame in the 300-pawn run (1.6 ms a tick, most of the tick's after-tick phase), almost all of it the per-pawn GDScript gathers this replaces.
- **Its REFACTOR rows:** one list of the base's channels (written twice), a public way to read a block's ticks, and an index of blocks (opening reads and decompresses the whole file, about 160 MB an hour at mass-battle sizes). The block index matters more once seeking and branching start from any keyframe.

**Diagnostics today:** `DiagnosticsManager` (about 700 lines) times frames, keeps 30 s of frame records, spikes and the session log, feeds the editor's monitors, starts always-on recordings and sets the window title; `PerfScopes` times named scopes on the main thread only.

**What changes:**
- **Game speed up front.** The 300-pawn run read "dropped 0.0/s" while the game ran at half speed, because time slowed rather than being dropped. The summary leads with game speed (ticks run against ticks due, "53% speed"), beside the frame rate.
- **Worker time.** Worker jobs aren't timed per kind today (`PerfScopes` is main-thread only; the scheduler keeps its own stats). A panel and log line per job kind: time on workers, batches the main thread ran, waits. Later, a per-thread timeline.
- **Scopes per pass, not per pawn.** Per-pawn scopes cost about a microsecond each (hundreds a tick at 300 pawns). With batched passes, one scope per pass is cheaper and reads better.
- **New, from the store:**
  - a pawn inspector: any entity's columns at any tick in the history, in place of clicking nodes in the remote tree
  - sizes per layout and column, and history memory
  - the determinism tripwire (nodes against the last frame) and frame checksums
  - observer lag and overload counts (snapshots skipped, replay jobs finished on the main thread)
  - fallback warnings (ability spec 3) and the list of pawns running embedded definitions
  - per client: snapshot bytes and how old its baselines are, so a lagging client shows
- **One timing tool:** `TickDriver.profile` folds into `PerfScopes`.
- **Frame records** are a Dictionary per frame; a typed record or packed columns.
- **Its REFACTOR rows:** split the manager (frame timing, session log, captures, editor monitors), always-on recordings belong to the recorder, the window title in shipped builds, "late" thresholds as settings.

## 12.4 Spawning, world, streaming, terrain and navigation: findings *(Claude, 2026-11-19, from reading game_mode/, spawning/, world/, streaming/, terrain/, navigation/ and the nav headers; a helper read the world side)*

**The core and its directors.** The audit sorts these systems into two kinds, and that sorting is the rule for deterministic re-runs:
- **The simulation core:** pawns, abilities, effects, hits, movement. Given a frame and that tick's inputs, it should give the same next frame.
- **Directors:** systems that decide things from outside the core, often from timing or this machine's view: players and the AI (commands), `SpawnManager` and `PawnSpawner` (spawns), `AIActivationManager` (switch-off and tick steps, partly from the host's camera position), the load ladder, `PossessionCoordinator`, chunk streaming (what's loaded), terrain edits (arriving over the network), the nav mesh (tile commits).
- **The rule:** a director's output is recorded as an input to the core, like a player's command. Re-running up to a branch point, directors are off and their recorded outputs are applied on their ticks; after the branch, they run live. Outputs that already land in state columns (a pawn's tick step, frozen) are recorded by the store for free; the rest are records (spawns, possession, chunk and terrain changes, nav commits).
- **Nav paths drop out:** the AI's movement reaches the core only through its recorded commands, so a path that differs on a re-run doesn't matter before the branch.

**Timing found (all fine for live play, where the server is the authority, but each needs its output recorded or moved onto a tick):**
- `SpawnManager` and `PawnSpawner` run their due work in `after_tick_loop`, once a frame after the frame's ticks, so a spawn due at tick T happens after whichever tick ends that frame. **Move them to the start of a tick** (`before_tick`): a cheap fix that also puts spawns on fixed ticks in live play.
- `AIActivationManager` checks a share of pawns each physics frame (`_physics_process`), reading which chunks are built and the viewers (including this machine's camera). It becomes a pass on the tick; its outputs are columns.
- Chunks: only the chunks under sources are built on a fixed tick (`before_tick`); the rest finish in `_process` under a wall-clock budget, and unloading follows a frame-timed refresh. Collision, nav input and `height_at` answers change when they finish. The replay's world channel already records chunk built, collision and removed; a re-run applies them on their recorded ticks.
- Nav tiles are built on worker threads and committed under a time budget (`TileManager::commit_finished(budget_ms)`), and `NavServer.tick` runs once a physics frame from `TerrainNavFeeder` (its REFACTOR row: ticking nav belongs somewhere universal). The crowd mover walks pawns along the nav mesh (`moveAlongSurface`), so **nav commits reach the core**: commit at the start of a tick and record the commit tick, or rely on drift correction from the frames. Proposed: commit on the tick, recorded.
- Terrain edits have a tick in `TerrainEditLog`, but it's informational, and the replay doesn't record edits. They become records applied on their tick.
- Smaller: `NavigationManager`'s immediate-path budget (`paths_now_per_tick`) is shared, so which pawns search at once depends on call order (go by entity id); a link timeout uses the physics rate rather than `ticks_at_rate`; `TerrainBodyLifter` writes `global_position` directly (it becomes a recorded correction through the store).

**Duplication:**
- **The ground is kept about seven ways:** the terrain's height points, its meshes, physics collision shapes, `SightGeometry`'s copy (which also answers `ground_at` for the crowd mover), the nav server's input store and Detour tiles; height is read three ways (`height_at`, physics rays, nav `closest_point`). Most copies have reasons (physics, nav, workers), but one plain height field that the others are built from is the target; `SightGeometry` is already tagged as really being a world geometry.
- Chunk maths in three places (`TerrainGenerator.chunk_of`, `NavMarkerManager`, `ChunkStreamer`); two source scanners with their own timers (`ChunkStreamer`, `TerrainNavFeeder`); edited chunks tracked twice (`TerrainGenerator`, `TerrainEditLog`); `NavMarkerManager` keeps its own copy of the terrain's origin and chunk size, stale if the terrain moves; `PawnSpawner` copies `AIActivationManager`'s "is the ground loaded" rule (its REFACTOR row).

**Size and splits:** `TerrainGenerator` (about 1,000 lines: generation, staged builds, mesh, collision, height queries, edits) splits into a height-field model, a mesh and collision builder, and the edit path. `NavMarkerManager` (about 700 lines) mixes a column store, a spatial grid, the module registry and a debug report; its markers could become a layout in the store. `AIActivationManager` does two jobs (its REFACTOR row).

**REFACTOR rows met:** nav ticking in the terrain feeder; the kill floor's fall report (debugging inside a gameplay class); `NavTags` copying `TagRegistry`'s rules; test hooks in `NavServer`; `SightGeometry`'s name.

## 12.5 Visuals: findings *(Claude, 2026-11-19, from reading visuals/, the pawn's drawing and camera/)*

**Already state-driven.** The toy visuals (`ToyWaddle`, `FloatingSword`) read the pawn each rendered frame and change nothing simulated; the sword follows the melee attack's progress and the exact path the hits check. No signals. That's the model the store wants, so the change here is about cost and where the data comes from.

**What changes:**
- **Smoothing comes from the history.** `Pawn` keeps its own `_previous_position` and `_current_position` (and yaws) to smooth its `Visual` between ticks. Frames T−1 and T already hold both, so those copies go, and placing followed entities on a client (12.2) and smoothing drawn pawns become **one "place what's drawn" pass**, reading frames, writing transforms.
- **One loop, not three scripts per pawn.** Each pawn runs three `_process` calls a frame (the pawn's smoothing, the waddle, the sword); at 300 pawns, scripts took about 14 ms a frame, 5 of it in this. Animation v0's visuals manager (roadmap item 6) becomes a batched pass over drawn entities, reading frames, with level of detail (distant pawns skip the waddle and sword).
- **Drawing crowds.** The 300-pawn run made about 2,700 draw calls. Each pawn instances its own toy model and sword. For crowds, the standard is instanced drawing (Godot's `MultiMesh`, or the rendering server directly) driven from the same pass: that's animation v0's "cheaper drawing".
- **Level of detail by update rate** *(the owner, 2026-11-19)*: a distant pawn that's on screen steps its visual updates down (every 2nd or 4th frame, smoothed between) rather than stopping, so changes of detail don't jar; a pawn off screen skips them. The standard name is update rate optimisation.
- **Measured** (the 300-pawn run's replay, from 30 s on, ms a rendered frame at about 282 drawn pawns): the sword 2.89 (10.2 µs a pawn), smoothing 1.28 (4.6 µs), the waddle 1.05 (3.7 µs): 5.2 ms of the frame's 13.3 ms of scripts. The sword costs most because every frame it builds its target with trigonometry and a new basis, `swing_phase()` makes a new Dictionary, a swing calls `hit_offset_at` three times, and it writes `global_transform` (a world-space write under a top-level parent), even while just hovering.
- **The shader waddle v0** *(the owner, 2026-11-19; after the audits, with an A/B switch)*: only the waddle (rock, hop, breathe, squash and stretch) moves into the vertex shader; turns, leans, death and the other moments stay as node rotations. The toy's held pose is baked into a static mesh once per toy type, replacing each pawn's skeleton and paused `AnimationPlayer`. The sword's cheap fixes go in the same A/B test (the owner): its hover bob and sway in its own small vertex shader, its pose worked out only while something happens (a swing, a parry, a change of side, death), a local transform instead of `global_transform`, and the swing's phase read without a new Dictionary.
- **Gameplay drives animation, never the reverse** *(the owner agreed)*: hitboxes come from gameplay data (capsules, arc keys), and animation follows them. Hitboxes synced to the waddle aren't wanted.
- **Animation pipeline, for animation v0:** procedural rigid parts (today's toy look) are the cheapest way to animate when batched, and the waddle's maths could even move into the shader with per-instance values. A skeletal pipeline is more expressive, not faster. For crowds the usual answer is tiers: skeletal (and IK) up close, baked vertex animation played in the shader for the middle distance, the cheapest form far away. IK needs rigged models, a pose order (animation, then IK), ground heights for feet (the height field, 12.4), and the hands' targets can come from the ability's arc keys. To settle in the animation v0 review.
- **Visuals read the new ability layers:** the sword reads the step timeline's state and the definition's arc keys (ability spec 7), so what's drawn and what hits stay the same path.
- **Playback uses the same pass** (12.3): the viewer loads frames, and this pass draws them.
- **The camera** follows the drawn pawn and isn't simulation; no change.

## 12.6 Effects and stats: findings *(Claude, 2026-11-19)*

**Effects already follow the model.** An `Effect` is a shared Resource whose parts (`EffectPart`, Resources with code) keep no state; each pawn's state is a packed list of five numbers per effect (id, ticks left, period left, stacks, source), capped at 16 (`max_active_effects`). What changes:
- **Deadlines:** ticks left and period left become `ends_at` and `next_pulse_at` (ability spec 4); the countdown loop in `tick_effects` goes, and a pawn running every Nth tick needs no special counting.
- **The id registry to build on:** an effect's id is a hash of its file path, checked for clashes when registered (`Effect.register`). The definitions registry the ability spec asks for (ability spec 8, 12) can be this one, made general.
- **Sources by entity id only:** a source that isn't networked falls back to its instance id (`_source_key`), which differs between runs; every gameplay entity having an entity id ends that.
- **Held totals are derived state:** what held parts add to stats, ability priorities and resistances is worked out again from the list after any change or load (`_refresh`), so it's never recorded.
- **Its REFACTOR rows:** threat written straight into the AI's memory (a signal instead), and `EffectTags` as the third copy of the tag rules (with `TagRegistry` and `NavTags`): one tag-set class.

**Stats:** each stat is a Node under the pawn's `StatManager`. A stat's `value` (base plus held effects) is derived; only `current` (Health and other stats that change during play) is recorded, and it's already pushed into the pawn table. With definitions, a pawn's base values come from a stat block definition and only `current` values are columns; the stat nodes can thin out the same way ability nodes do. Its REFACTOR row: one place for the rule that keeps `current` between 0 and `value` (today written directly by `AbilityManager.revive`, `EffectManager` and a sample). The deeper stats design stays for the stats pass.

## 12.7 The AI: findings *(Claude, 2026-11-19; a helper read the AI's managers, senses, states and the C++ headers, checked against the 300-pawn run's timings)*

**Measured** (ms a rendered frame of about 3 ticks, about 189 pawn runs): the AI 13.7 (73 µs a run); deciding 5.35, of which the behaviour decision 3.69 (45 µs) and the C++ call 2.46 (30 µs a call); sensing 3.77; running behaviours 2.16; choosing state 0.95 and target 0.65. About 2.4 ms of the AI's time isn't inside any named scope: per-run bookkeeping.

**Why "C++ decides" still costs 30 µs a decision:** it isn't batched. Each pawn makes its own call (`AIDecisionModule`: `_decider.decide_pawn(row, …)`), through an untyped `Object`, so Variant dispatch, and the GDScript around each call does the heavy part: a Dictionary of rows read by string keys, every behaviour's action readiness asked again (`_write_readiness`, through `AbilityManager.can_start`) on every decision, every group's nearest point written again (`_write_group_points`). A batched entry point (`AIBatchDecider.decide(columns)`) already exists; only tests and replay use it.

**What changes:**
- **One batched decision call a tick** for the pawns due, through the existing batch entry point; readiness pushed by the abilities when it changes, group points written only when they change. These are the cheapest wins and don't need the store.
- **Scheduling by tick, centrally:** sensing passes, refreshes and decisions booked by tick rather than each pawn working out its schedule every run (the event scheduler item on the roadmap).
- **AI state:**
  - *in C++:* memory (`AIMemoryStore`) and the decider's rows, both keyed by **instance id**, which becomes entity id
  - *in GDScript:* the context's pending decision and hit facts, the state manager's and target selector's current, forced and queued choices, each behaviour's runtime, the sensing schedule
  - **behaviour state is held twice** (the behaviour nodes and the decider's rows, kept in step by events), and **the current target three ways** (the context, the selector, the decider). Section 11's plan, the target as a flag on one memory entry, makes it one.
  - input slots are numbered in first-use order, so keyframes save inputs by name.
- **Duplicates:** positions read live from nodes (sight, memory, inputs) though the pawn table has them; death read by property name from C++; twin pairs to keep (the GDScript backup and C++ decider, memory store, fade maths, sight rule) and one to drop (`SightSense`'s third copy of the sight rule, its REFACTOR row).
- **Determinism:** ties in "most aware" and "best target" are broken by instance id, and memory entries keyed by it, so a re-run on another machine could differ; `pawn_number` falls back to a hash of the node's name. Both go to entity ids. A hit or a warned swing wakes a decision at once, so the reaction tick depends on which pawn ran first; queue them to the next tick, like other cross-pawn effects (pawn spec 15.1). Main-thread sight checks read live positions of pawns that may have moved this tick; the job path reads the end-of-tick table and is fine.
- **Size:** `AIContextComponent` (about 490 lines), `AIBehaviourManager` (about 580) and `AIDecisionModule` (about 480, including the F10 key, debug code in shipping code) each mix several jobs. `ai_batch_decider.h`'s header still says nothing uses its answers.
- **Its REFACTOR rows met:** finding sibling parts written three times; forcing with a priority and queueing written twice (state manager and target selector); the sight rule's third copy; the memory store twin.

## 12.8 The pawn and the crowd mover: findings *(Claude, 2026-11-19)*

**The pawn** (`Pawn.gd`, about 720 lines, down from 877 after the slimming work of 2026-11-15 and 16) is the body (a `CharacterBody3D`), the hub that finds its parts, and the order of a pawn's tick: its input step (AI, then the controller) and its simulate step (effects, abilities, gravity, then a move by the crowd mover or `move_and_slide`).

**What changes:**
- **The pawn becomes the holder of its body's columns:** position, velocity, yaw, grounded, dead, team, tick step, last run tick, frozen. Sleeping stays derived (a rule of state and tick number, already deterministic and not recorded).
- **Its tick steps become the batched passes** (section 9): the input pass and the simulate pass loop over pawns grouped by step, instead of the tick driver calling each pawn.
- **Smoothing leaves the pawn** (its own REFACTOR row; 12.5): `_previous_position`, `_current_position` and the yaws go, read from frames. The sleep check's "nothing moved it since its last tick" compares with the last frame instead.
- **Hidden engine state:** after a rollback load, the pawn re-runs `move_and_slide` with no velocity to make the engine work out its private "on floor" flag again (`_on_state_loaded`). That's the kind of state the store can't hold (5.4), so it stays as a step after any load, and the drift test (13) shows whether it's enough.
- **Entity ids:** the check-tick stagger falls back to the instance id for a pawn with no entity id; every gameplay entity having one ends that.
- **Its REFACTOR rows:** the streaming source contract, detectability as a pass-through to a stat, the shared table and grid as static state on the pawn class (they become the store), smoothing in the pawn, and clearing input on a role change (the `ControllerManager`'s job). The fallback `_physics_process` (a pawn ticking itself without a tick driver) stays for scenes with no driver.

**Where the pawn's 716 lines go** (408 code, 196 comment, 112 blank; the owner, 2026-11-19: still too big). Rough line counts with comments:

| Part of `Pawn.gd` today | Lines | Goes to |
|---|---|---|
| Tick stepping: `_prepare_run`, `fired_since_last_run`, `fires_in_run`, `next_run_tick`, the step and stagger | ~70 | The tick driver's step grouping (section 9) and the central schedule (12.7) |
| Movement: gravity, skip-when-still, the crowd hand-off, `_move_with_physics`, `finish_crowd_move`, `finish_move_by_physics` | ~60 | A movement pass, with the crowd mover: one owner of how every pawn moves. This revisits the 2026-11-16 call that kept `move_and_slide` and gravity on the pawn (Godot's `CharacterBody3D` model); the body stays the pawn, the movement rules leave it, as Unreal splits `Character` from its `CharacterMovementComponent` |
| Finding parts in `_enter_tree` and `_ready` | ~75 | Mostly the `PawnInitializer` and the holder's declare step |
| Streaming source contract (distances, group, distance moved) | ~45 | A small part of its own (its REFACTOR row) |
| Smoothing `Visual`, network interpolation and correction hooks | ~45 | The "place what's drawn" pass (12.5) |
| The pawn table and grid as static state | ~35 | The store |
| Sleeping (`_can_sleep`, `_is_check_tick`) | ~30 | The movement pass |
| Detectability pass-through | ~25 | Gone: callers read the stat |
| Network role hooks | ~20 | The `ControllerManager` and `NetworkEntity` |
| Body shape and radius getters, flags, part references, rollback floor rebuild | the rest | Stays |

What stays is the body, the general flags (dead, frozen, team), the references to its parts and its column declarations: likely 150 to 200 lines with comments.

**The crowd mover** (`CrowdMover.gd`, C++ `CrowdBatch`) gathers each AI pawn's position, motion and radius into lists in GDScript every tick, runs the batch (C++ on workers), then calls each pawn back (`finish_crowd_move`). Measured: 2.46 ms a rendered frame (0.82 ms a tick) at 300 pawns. With the store it reads positions from the frame being built and writes results straight into position columns, with one pass writing node transforms; the per-pawn GDScript gathering and calling back goes. Its walls come from the nav mesh, so it's one of the places nav commits reach the core (12.4).

**Step 2's design** *(agreed with the owner 2026-11-19)*:
- **Team on the pawn**, as a pushed column: a property of the unit, which keeps its team whoever possesses it.
- **Pushed entries** in a `TickStateComponent` list (an entry ending in `pushed`): the store reads them once when binding, then takes what the holder pushes when the value changes; a rollback writes them back to the node, and the tripwire checks them. The pawn's team and tick step and stats' current values (Health) are pushed.
- **Recording only what changed:** a pawn that didn't run this tick (its load step) and that nothing touched is recorded by copying its previous row forward, with no node reads. The pawn marks itself changed when it runs; anything that changes it between its runs (an effect landing) marks it too. The tripwire catches a write that forgot to.
- **The pawn's own move stays** (gravity and `move_and_slide`), for games with few pawns and scenes without the tick driver or the crowd mover. **The crowd mover leaves the pawn:** a pawn has a `mover` (set by the `PawnInitializer` from the game's crowd mover, or none); the pawn asks it to take each tick's move and otherwise moves itself, and never names the crowd mover. Abilities keep steering by writing the pawn's velocity, which the one move per tick applies; a named motion call (`add_impulse`) comes with abilities v2.
- **Slimming:** smoothing the visual moves to its own part (`VisualSmoother`), the shared pawn table and grid to a holder class (`SharedPawnTable`), and detectability is read from the stat by its callers.

## 12.9 Player, camera, UI, jobs, tags and platform: a light pass *(Claude, 2026-11-19)*

- **Player and camera** are this machine's presentation: input is read each frame and turned into one command a tick (presses latched between), and the camera follows the drawn pawn. Standard, and outside the core. Their REFACTOR rows: the `InputMap` names written into `PlayerController`, and path following written twice (player and AI controllers; the controllers review).
- **UI** (`MatchOptionsPanel`) is small and outside the core.
- **Jobs:** `TickJobs` holds the one `JobScheduler`; navigation's own thread pool folds into it (section 8).
- **Tags:** `TagRegistry`, `NavTags` and `EffectTags` are three copies of the same tag-set rules (each tagged REFACTOR): one tag-set class used three times.
  *(Claude 2026-11-22: done: the three are merged into one tag registry with categories; see [tag spec](../tags/TAG_SPEC.md).)*
- **Platform:** `RunEnvironment` keeps a switch only tests turn on (its REFACTOR row).

**The audit is complete** (2026-11-19), with the overview ([ARCHITECTURE.md](../ARCHITECTURE.md)) and the measurements (13). Next, per the owner: commit, push and branch, then rewrite in place: the tick driver and the store, the pawn and the movement pass, abilities v2 ([ABILITY_SPEC.md](../abilities/ABILITY_SPEC.md)) written straight against the store, then the AI, netcode, replay and diagnostics, and the directors onto ticks. The shader waddle A/B (12.5) is independent.

## 13. Measure before building

Done 2026-11-19, on master before branching, with two measuring tools in `samples/tests/` (`dispatch_measure`, `state_inventory_measure`). Debug build, headless.

### 13.1 Dispatch cost

300 pawns, three do-nothing participants each (shaped like today's pawn, recorder and network entity), 200 ticks:

| What | A tick | Each |
|---|---|---|
| The tick driver calling 1,800 empty participant methods | 341 µs | 0.19 µs |
| A plain GDScript loop calling a method 1,800 times | 210 µs | 0.12 µs |
| A plain loop doing the work inline, no call | 38 µs | 0.02 µs |
| A call into C++ through an untyped `Object` (300) | 31 µs | 0.105 µs |
| The same call, typed | 8 µs | 0.028 µs |
| A property read: direct / `get()` by name / `get_indexed()` | 10 / 16 / 21 µs | 0.03 / 0.05 / 0.07 µs |

**What it means:** calling participants one by one costs about 0.3 ms a tick at 300 pawns, not the several milliseconds the record phase takes. **The cost is the work inside the calls**, chiefly reading node properties one at a time (below). Batching the passes still pays (less dispatch, and work in C++ or on workers), but the bigger win is not reading cold values every tick. Typed calls into C++ are about four times cheaper than untyped ones, so the store and the AI decider are called typed (12.7 found the decider called untyped).

### 13.2 State inventory

A 150-pawn battle (50 a faction, meeting at 40 m), counted from 10 s to 40 s, over about 257,000 pawn-ticks. Each pawn records **45 kinds of state entry** (ten vectors, the rest whole numbers, a few floats and packed lists). How often each changed from one tick to the next, as a share of pawn-ticks (most pawns ran every 4th tick, so about 25% is the most a value can change):

| Changes on | Entries |
|---|---|
| 26% | `_last_run_tick` (moves on every run) |
| 11–13% | position, velocity, yaw; **Sprint's cooldown countdown** |
| 7–8% | **RangedAttack's cooldown and run countdowns** |
| 1–2% | **Jump's time off the ground, Knockback's and Parry's countdowns**, previous held actions, Sprint's run countdown |
| under 1% | grounded, Health, Knockback's push, Death, tick step, combo and the rest |
| never in this fight | 25 entries (unused abilities' timers and step states, effects, Dash) |

Inputs: look pitch 10%, look yaw 9%, move 7%, held actions 2%.

**What it means:**
- **Countdowns are about a third of all changes** (Sprint, RangedAttack, Jump, Knockback, Parry), and `_last_run_tick` another quarter. Tick deadlines (ability spec 4) and working the last run out from the schedule (9) remove well over half of the per-tick changes, leaving the body's position, velocity and yaw as almost all of what changes.
- **Most entries are cold:** 25 never changed and most of the rest change on under 1% of ticks. They're pushed columns, never gathered every tick (6.3).
- **Memory is small:** about 45 values a pawn, roughly 250 bytes, so 300 pawns × 64 frames is about 5 MB before cold columns keep less history.
- **The gather is the cost:** the C++ recorder took **6.4 µs a pawn** to read and round its whole state list through Godot's property reflection (`get_indexed`): about 0.14 µs an entry, 1.9 ms a tick at 300 pawns if done every tick. So the store's gather reads only the hot columns (position, velocity, yaw, grounded) every tick, through direct engine calls for the body's transform rather than reflection, and everything else arrives pushed.

### 13.3 Drift

Today's `TickDriver.rollback` was used to re-run the whole game from its saved state and recorded inputs, then compare every pawn's state with what it had before (within each entry's encoding).

| Run | Rewound | Pawns that differ |
|---|---|---|
| Marching, no fighting, every pawn moving by physics (`--spawn-distance=300 --no-crowd`), 153 pawns | 1, 10 and 30 ticks | **0** |
| Fighting at 40 m, crowd mover on, 142 pawns | 30 ticks | 139: positions up to 2.5 m, velocity, yaw, Health on 6, Knockback on 7 |

**What it means:** **physics re-runs exactly on the same machine**: Jolt and `move_and_slide` gave identical results over 30 re-run ticks. The fighting run's differences come from gaps in today's rollback, built for a client predicting its own pawn, not from physics: it doesn't run the crowd mover's batch while re-running, doesn't deliver hits (`after_simulate` isn't sent), and can't bring back projectiles that despawned. Those are exactly what the store's re-run covers (10), so **drift correction should rarely have anything to correct**, and deterministic physics of our own isn't needed for same-machine re-runs. The drift test is run again on the new core with fighting, crowds and projectiles.

Re-running costs about 8.8 ms a tick for 153 pawns (263 ms for 30 ticks), so a branch from a keyframe a second back takes about half a second at that size.

### 13.4 Step 1 built: the store and the commit *(Claude, 2026-11-19, branch `refactor/tick-core`)*

What step 1 is: the C++ `StateStore` and its twin `StateStoreGD` (`assets/scripts/state_store/`), the tick driver's commit phase, rollback rewriting rows through the store, and `TickStateComponent` as the holder that feeds it. Today's pawns record into it unchanged. Every machine records and rounds every tick (the saving switches are gone). All 68 suites pass; the twins give the same handles, rows and checksums.

| Measured (300-pawn march, headless) | Result |
|---|---|
| Commit, ms a tick | **2.0**: about 6.2 µs per pawn for its whole state list, the same as the old recorder |
| What that adds | Offline didn't record or round before, so this is new cost there (the price of replay offline); a server now keeps every tick, not only snapshot ticks |
| Drift after a rewind (marching, `--no-crowd`) | 0 of 153 pawns differ for 1, 10 and 30 ticks |
| Re-run cost | 5.5 to 10 ms a tick for 153 pawns, as before |
| Tripwire (`verify_store_each_tick`, 90 pawns, 40 s) | One entry written between ticks: the pawn's `tick_step`, set by `AIActivationManager`. A director, as section 10 expects: it moves onto a fixed tick as a recorded input in step 7 |

Step 1 isn't meant to be faster: the gains come from pushed columns replacing most per-tick reads (step 2 on), the duplicate gathers reading the store instead (pawn table, lag compensation, replay motion), and worker jobs reading frames.

### 13.5 Step 2 built: the pawn as holder, rows carried forward *(Claude, 2026-11-19)*

The design is in 12.8 ("Step 2's design"). Built: rows carried forward for entities nothing marked (`set_carry_forward`, `mark_changed`), pushed `TickStateComponent` entries bound to a node (team, tick step, stats' current values), the pawn's `mover` (the crowd mover no longer named by the pawn), `VisualSmoother`, `SharedPawnTable`, and detectability read from the stat. The pawn is 638 lines (from 716). All 68 suites pass.

| Measured (300-pawn march, headless; step 1 in brackets) | Result |
|---|---|
| Commit, ms a tick | **1.2** (2.0) |
| Whole tick, ms | 9.3 (10.0) |
| Drift after a rewind, marching | 0 of 153 for 1 and 30 ticks |
| Tripwire, marching (90 pawns, 90 s) and fighting (153 pawns) | Only `tick_step`, the director write from 13.4: no change between runs went unmarked |

Found on the way: `PawnTable` dropped a push for a column that was off, and the pawn's `detectability` property had hidden it (fixed: such pushes now wait), and `ai_sensing_job_selftest` had never really varied detectability.

### 13.6 Step 3 built: the pawn's parts, its source and its step *(Claude, 2026-11-19)*

Built: each pawn part sets its reference on the pawn as it enters the tree, instead of the pawn looking through its children (so it works with or without the GameMode); the streaming source is a part, `PawnStreamingSource` (a default part, the game's distances, in the sources' group only while it might count); clearing input on a role change is the `ControllerManager`'s (`NetworkEntity.role_changed`); and the tick driver doesn't call a pawn before its `due_tick`. The pawn is 577 lines (313 code), from 638.

| Measured (300-pawn march, headless, `--size=100`; step 2 run beside it from its own checkout, the same day) | Step 2 | Step 3 |
|---|---|---|
| Input, ms a tick | 3.9 | 3.7 |
| Simulate, ms a tick | 2.5 | 2.5 |
| Commit, ms a tick | 1.45 | 1.3 |

Step 2's own figures in 13.5 (commit 1.2, tick 9.3) were from a faster run of the machine; the comparison above ran both steps back to back. Most pawns were on every 4th tick (the load ladder at step 2), so the saving is the calls on skipped ticks, about 0.3 ms a tick, as 13.1's call cost predicts.

**The crowd mover: measured, not changed yet.** Of its 1.1 ms a tick at 300 pawns, GDScript around the batch is most: gathering the moving pawns 0.18 ms, their nav tiers and every other pawn as obstacles 0.25, and calling each pawn back 0.45 (about 4.5 µs a pawn: its velocity, position, rounding and the end of its run: `_position_after_run`, the `VisualSmoother`, the `ControllerManager`'s input bookkeeping). The C++ batch and its physics queries are about 0.25. Reading positions from the store would save part of the gathering, but the store's newest frame is the last tick's, one tick behind pawns that moved by physics this tick, and the calling back stays until the per-pawn end-of-run work moves into batched passes (smoothing into the "place what's drawn" pass, 12.5). Writing results straight into the store needs the frame being built to be writable during the tick, with one pass placing nodes from it. That's a design to agree, not a quick change.

### 13.7 The crowd reads the others from the store *(Claude, 2026-11-20)*

The owner's call (2026-11-20): read the other pawns from the store's last frame and accept that a pawn moved since then may overlap for a tick, which collision corrects, rather than build for it. Built:

- **`StateStore.get_vector3s(handles, column, tick)`**, both twins: one Vector3 column, by name, for a list of entities in one call, with a NaN x where there's no row.
- **The crowd mover's members:** every pawn joins as it enters the tree and leaves as it leaves, with its width, slope and shape found once (`add_pawn`, `remove_pawn`, `refresh_pawn`). Neither the moving pawns nor the others are asked for them each tick, and it no longer looks through the pawns' group.
- **The others stand where frame `tick - 1` has them**, except the few that moved by physics this tick (`note_moved`, from `Pawn._move_with_physics`) and any without a row (new, paused, or under a parent that's moved or turned, since the store keeps its own position, not the world one), which are read from their nodes. The crowd runs last in simulate, so for the pawns that didn't run this tick (most of them, on a load step) the last frame is exactly where they are.
- **What stays stale for a tick:** a pawn moved by code since the last commit (a teleport, a respawn). Its moving pawns still start from their nodes, so a crowd pawn itself is never put back.

| Measured (300-pawn march, headless, `--size=100`, two runs each, step 3 from its own checkout beside it) | Step 3 | Reads from the store |
|---|---|---|
| `movement.crowd`, ms a tick | 1.07 | 0.87 |
| gathering the moving pawns (`crowd_gather`) | 0.18 | 0.11 |
| the others and nav tiers (`crowd_others`) | 0.24 | 0.12 |
| finishing each pawn (`crowd_finish`) | 0.41 | 0.41 |
| Simulate, ms a tick | 2.48 | 2.28 |

Finishing each pawn is now most of what's left around the batch (13.8).

### 13.8 Writing during the tick, teleports and the move check *(Claude, 2026-11-20)*

The owner's calls (2026-11-20): test writing the table during the tick before deciding; delete passes where it stays modular; one general teleport instead of code per ability; a cheap sanity check for moves, with speed limits caught some other way.

**Writing through, tested.** `StateStore.write_through(handles, column, values, tick)` (both twins) writes one column for many entities at once, into their nodes and into the row this tick's commit records, which then skips reading those nodes. The crowd mover writes its moved pawns' position, velocity and `grounded` through it in three calls (`CrowdMover.write_moves_through`, on). Mass battle, 300 pawns, two runs each:

| ms a tick | Off | On |
|---|---|---|
| Finishing the moved pawns (`movement.crowd_finish`) | 0.43 | 0.34 |
| The commit | 1.21 to 1.30 | 1.25 to 1.35 |

The store's tripwire (`verify_store_each_tick`) shows the same three warnings either way, from spawning: the rows written through match the nodes. The commit didn't get faster, because position, velocity and grounded are 3 of about 47 columns a pawn has: the other 42 are ability timers and step states (about 3 a ability, 14 abilities), Health and the effects list, each a script property read through the engine, for every pawn that ran (101 a tick here; 202 more are copied forward). The commit's time is those reads (about 0.6 ms) and finding each column's node (about 0.2 ms).

So: what pays is the abilities' state becoming pushed columns, written when it changes (6.3), which is the owner's idea of writing during the tick where it counts. That belongs to the abilities step (done in 13.10). Readers still read the last frame: a row written through is never read before the commit, so results don't depend on which system ran first. The rule on writers: whatever writes a written-through property later in the same tick must write through too, or call `mark_changed`, which drops what was written through for that entity so the commit reads its nodes (2026-11-21: `Pawn.teleport` does, so a teleport after the crowd moved a pawn is recorded).

**`Pawn.teleport(to)`.** Every instant move goes through it (respawns now do): the crowd reads the pawn from its node this tick (`CrowdMover.note_moved`, which `_move_with_physics` calls too), its Visual snaps instead of gliding, the store reads it even on a tick it doesn't run, and `last_teleport_tick` lets the move check through. Not yet: clients and replays still blend across a teleport between two snapshots; that needs a marker in the snapshot (netcode, later).

**`MoveSanityCheck`** (diagnostics, every build, after each tick, `DiagnosticsManager.check_moves`): from the store alone, warns once per entity that moved further than its velocity explains (the faster of its last two velocities, over the ticks its run covered, times 1.5, plus 0.5 m), unless it teleported. A dash's velocity explains a dash's move, so no ability needs anything for it; speed limits themselves are left to another check. Its first pass over every entity is the store's `find_long_moves` (both twins), which returns only the long moves; the check looks up the owner of those alone. 0.03 ms a tick at 300 pawns (0.12 when the pass was GDScript reads, 2026-11-20), so it runs in release builds too (owner's call, 2026-11-21).

**Not done here:** moving the rest of the finish out of the per-pawn call; done in 13.9.

### 13.9 Finishing the crowd mover: nothing calls each pawn back *(Claude, 2026-11-21)*

The owner's call (2026-11-21): finish the crowd mover before the abilities step, with all three pieces, the drawing pass included. After a crowd move, each pawn was called back for three things; each has moved:

- **Input bookkeeping** (`ControllerManager.finish_tick`): called in the pawn's own simulate, after its abilities (the last to read the input), before it moves. What the commit records is unchanged.
- **"Has something moved it since its run?"** `_position_after_run` is replaced by a flag, `_moved_since_run`, which `Pawn.teleport` and a rollback load set or clear. A teleported pawn doesn't sleep or skip its move on its next run. A position set directly no longer wakes a sleeping pawn: everything that moves a pawn instantly goes through `teleport` (the `TerrainBodyLifter` now does), and the `MoveSanityCheck` warns about anything that doesn't.
- **Smoothing: the "place what's drawn" pass (12.5).** One `VisualPlacer` (made on first use, under the TickDriver) places every pawn's Visual once a frame in one call: the C++ `VisualPlacement`, or its twin `VisualPlacementGD`. Each `VisualSmoother` holds the pawn's slot and tells the placer about the runs it finishes itself, snaps and corrections; the crowd tells it about all its pawns' runs in one call (`VisualPlacer.note_runs`). The placer keeps the last two runs' positions and yaws itself rather than reading the store's frames: a pawn on a load step has rows copied forward between its runs, a teleport between runs would glide from the wrong row, and a client's remote pawns aren't committed at all, so reading frames would need all three handled for no gain.

| Measured (300-pawn mass battle, headless, `--size=100`, two runs each, against step 4 the same day) | Step 4 | Now |
|---|---|---|
| `movement.crowd`, ms a tick | 0.85 | 0.70 |
| finishing the moved pawns (`crowd_finish`) | 0.36 | 0.22 |
| Drawing the Visuals (`animation.smoothing`), ms a frame | 0.65 (303 calls) | 0.31 (1 call) |

What's left in the finish is the GDScript loop building the lists for the three write-throughs and the placer (about 2 µs a pawn). The placer's 0.31 ms is the engine's own cost of moving 303 nodes and turning their models.

### 13.10 The abilities step, part 1: ability state pushed, timers as deadlines *(Claude, 2026-11-21)*

The owner's call (2026-11-21): push and go on to the abilities step. Abilities v2 ([ability spec](../abilities/ABILITY_SPEC.md)) is large, so it's built in parts; this first part is the agreed, mechanical one, and the one 13.8 measured as paying:

- **Every built-in ability's state is pushed** (6.3): each property's setter calls `AbilityBase.push_state`, and the manager registers them as pushed entries, so the commit copies them and reads no ability node. `get_pushed_properties()` lists them; `get_rollback_properties()` stays for properties read at every commit, the easy way for a quick ability with no setter. Steps change their numbers through `AbilityBase.set_step_value`, because GDScript doesn't call a property's setter when one element of a packed array is written.
- **Timers are tick deadlines** (ability spec 4): `started_at` and `ends_at` (a run), `ready_at` (cooldown), `buffer_until` (a waiting press), the manager's `combo_open_until`, Jump's `left_ground_at`. Nothing counts down; the manager keeps the soonest deadline still ahead, and when it passes moves `readiness_version` on and looks again. Death runs with `ends_at = NEVER` while Health is 0. `ticks_left()`, `cooldown_ticks_left()` and the like are worked out from the deadlines, for readouts and tests.

| Measured (300-pawn mass battle, headless, `--size=100`, two runs each, the same day) | Before | Now |
|---|---|---|
| `commit`, ms a tick | 1.42 to 1.63 | 0.60 to 0.80 |
| `pawn.abilities`, ms a frame | 0.93 | 0.93 |

The commit roughly halved. Deadlines didn't make the abilities faster (the countdowns were cheap); they make the state still while a timer runs, so nothing is pushed, sent or rolled back while one does. The tripwire (`verify_store_each_tick`) shows only the three spawning warnings it showed before.

A cooldown now counts as over from the start of the tick it ends on (the countdown reached 0 only when the abilities ran), so the AI may press one tick sooner; `readiness_version` notices a passed deadline when read, so the AI's kept answers stay right. Two smaller timing changes, both only for a pawn on a load step: a run started between its runs (a knockback from a hit) now counts from the tick it started, where the countdown counted the whole span since the pawn last ran; and a readout between its runs shows the time left now rather than at its last run. Deadlines keep running while a pawn sleeps, but a running cooldown still keeps a pawn awake, so its AI hears when it ends.

### 13.11 The determinism check *(Claude, 2026-11-22, the owner's request)*

**What it is:** the standard desync checksum, on one machine. `python tools/determinism/run_determinism_check.py` plays the mass battle offline several times from the same start (`--runs`, default 2) and, after every tick's commit, compares a fingerprint of the store: the frame checksum, a hash of each entity's row, and a hash of each layout column across all entities. At the first tick that differs it names the entities and columns, from a names file written beside each run. The run itself is the test bed `samples/tests/determinism_check.tscn`. The load ladder is off by default (`--ladder` turns it on), since it follows how loaded the machine is.

**First findings** (team size 50, 1200 ticks; runs differ some of the time, not every time):
1. **Terrain streaming.** With the factions 300 m out, a soldier still falling at tick 10 in one run had landed in another (`position`, `velocity`, `yaw`). `ChunkStreamer` builds chunks under a time budget per frame (`max_ms_per_frame`), so how much ground exists by a given tick depends on how fast the machine was just then. Only chunks under a streaming source are built before the tick, and soldiers aren't sources.
2. **Nav mesh tiles.** With everyone spawned 40 m out (no streaming at stake), one goblin's `velocity` differed at tick 589. `NavServer` builds tiles on worker threads and commits finished ones under a time budget (`commit_budget_ms`), so which tiles exist, and so which paths are found, depends on timing.
3. **A 1 mm difference at 300 pawns.** After the landing schedule (13.12), at team size 100 over 3600 ticks, runs split into two groups that first differed at the same tick (2144) by exactly 1 mm in one soldier's `position` (the store's rounding), velocity the same; with the job scheduler's workers off too, so not thread timing. A trace of that soldier (`--trace`) showed the same start and velocity giving positions 1 µm apart in z (right on the half-millimetre rounding boundary) and 6 µm apart in height. The cause found: the landing schedule held a chunk's collision switched off, `SightGeometry` leaves switched-off shapes out and never noticed them switched on, so the crowd mover found no ground on landed chunks and handed those soldiers to physics movement, whose last bits vary from run to run. With the collision body kept out of the scene until it lands, 4 runs of 3600 ticks at 300 pawns agree. The physics fallback (steep ground, no ground) can still vary in its last bits; the check will name it if it shows.

The first two break the rule sensing keeps (section 4, the scaling spec's rule 3): work done off the tick, or under a time budget, must land on a fixed tick. Fixed by the landing schedule (13.12): afterwards both cases agree over 4 runs of 1200 ticks.

**Across separate sessions, from the replays** *(Claude 2026-11-22, the owner's request)*: every offline game records a replay, so determinism across sessions can be judged from the recordings alone, without the check's own run. `python tools/determinism/compare_replays.py` compares two recordings tick by tick (`samples/tests/replay_compare.tscn`: pawns, their motion and input, events other than diagnostics) and names the first tick, pawn and field that differ; `--sessions N` plays the mass battle in N separate headless sessions first, in real time as a player's game runs. It sees what the recording keeps (positions to the millimetre, yaw and velocity as half floats), so it's coarser than the fingerprints, but it works on any two recordings, including games played by hand. First large run, after the fixes above: 3 sessions of 200 a faction (up to 603 pawns at once), 7200 ticks each, load ladder pinned, agree on every tick; the recordings hold 462 deaths, 3885 hits, 1064 spawns and 112 streamed chunks. Each session took about 3.4 minutes for 2 minutes of play, so ticks ran behind real time and several ran in some frames, and they still agreed. With the load ladder working, the same run (3 sessions) also agreed; but the machine was overloaded from the first ticks in every session, so the ladder likely climbed at the same ticks each time. That is agreement under steady overload, not proof: the ladder follows measured tick time, so a load near the edge of the budget can still split sessions.

**Across platforms** *(Claude 2026-11-23, the owner's request)*: Windows against Linux (Ubuntu in WSL2, the same computer: so the operating system, compiler and C runtime differ, not the processor). The Linux library is built in WSL from a copy of the checkout.
- **First:** a real-time session's replay agreed (200 a faction, 7200 ticks, the whole battle), but the determinism check's fingerprints split at tick 18: one soldier set off a tick earlier on Linux, and from there the battle went its own way (5 entities differed by tick 120, 311 by tick 600, all of them by tick 7200). The replay missed it because that session happened not to hit the case, and a replay keeps velocity as half floats.
- **Narrowed down** with new tools: `run_determinism_check.py --compare A B` (fingerprint files from two machines), and the run's `--trace` (now with the move input, the path state and every AI decision), `--nav-dump` (every nav mesh triangle, link and tile state, bit for bit) and `--paths-to` (every pawn's path state, and the nav server's path search log: `NavServer.debug_log_path_steps`). The nav meshes were identical, every decision and path the same; only a queued search finished a tick sooner, because an earlier search had snapped its goal to the neighbouring polygon and taken 8 steps instead of 5.
- **The cause:** Detour's `findNearestPoly` keeps the first polygon with the lowest score, in the order its bounding-volume tree hands them over, and builds that tree with `qsort`, which isn't stable: equal keys come out in a different order under MSVC's C runtime and glibc. Ties are common (a point over a polygon within climb height scores 0). **Fixed** in our code (`GroundDomain`'s `nearest_poly`): the same score, exact ties settled by the lower polygon ref.
- **After the fix:** the fingerprints of 200 a faction (603 pawns) over 7200 ticks agree between Windows and Linux on every tick, every entity, every column.
- **Made general** (the owner's request: other level generators, such as dungeons, will feed nav): Recast and Detour now sort stably (`native/src/stable_qsort.h`, forced into their sources only, which stay untouched). Recast sorted a region's holes and candidate diagonals with `qsort` too, and grid-aligned levels are full of exact ties, so the nav mesh itself could have differed; and Detour's own nearest-polygon searches, such as an off-mesh link attaching to a polygon, now meet polygons in the same order everywhere. Afterwards the same 603-pawn, 7200-tick match agrees between Windows and Linux on every value, and the nav meshes at tick 600 are identical bit for bit. A generator's own side of this is in the world spec ("Determinism: what repeatable has to mean").
- **What's still a risk:** only one processor was tested, and the engine's own math functions (sin, cos, pow in GDScript) come from each platform's runtime; none of them made a difference in these runs. Play is server-authoritative, so none of this affects online play: it matters for input-based replays shared between platforms, and a lockstep mode.

**Under contention, on other floors** *(Claude 2026-11-23, the owner's request)*: several copies of the same check run at once on one machine, competing for its cores, so frame lengths, ticks per frame and when worker threads finish all shift. 4 copies of 200 a faction over 7200 ticks each match the run made alone on every tick and every value (about 6 minutes for all four); so do 4 copies on another floor (`--terrain-seed=9137`, 150 a faction, 3600 ticks), whose map differs from the default one from the first tick. So how busy the machine is changes nothing, with the load ladder pinned; the ladder follows measured tick time by design and needs its own test.

### 13.12 The landing schedule *(Claude 2026-11-22, agreed with the owner the same day: both a fixed delay and a record)*

**The rule.** Work done off the tick (terrain chunks built across frames, nav tiles built on worker threads) may finish whenever it likes, but it **lands** (becomes something play can see: ground to stand on, a height, a nav tile a path can use) only on its **landing tick**, decided when it's asked for: the tick it was asked for plus a fixed delay. If it isn't finished by then, the tick waits for it (a hitch on a machine too slow for the delay). So the same start lands the same work on the same ticks, however fast the machine is. On top of that, every landing is **recorded** (tick, kind, key): the determinism check compares the records, and an input-based replay can land the same work on the same ticks from them.

**Terrain chunks** (`ChunkStreamer`, `TerrainGenerator`):
- The streamer decides what's wanted on ticks (every `refresh_seconds`, counted in ticks), not on frames. Each newly wanted chunk gets a landing tick: now + `landing_delay_ticks`, spread so no more than `max_landings_per_tick` land on one tick, in order of urgency (ties by chunk).
- Building still runs in frames under `max_ms_per_frame`, but it stops just before **publishing**: the chunk's points (what `height_at` reads), its collision and `chunk_built` (nav, markers). Its mesh is only a picture, so it may show before. On its landing tick, before the tick runs, the chunk is published, finishing any building left first (the wait).
- Chunks under a streaming source are still built and published at once, before the tick: they're asked for and land on the same tick.
- Unloads happen before the tick too, in a fixed order, so ground never vanishes at a time that depends on the machine.
- Without a tick driver (the editor, a scene with no driver), it works as before: each chunk lands as soon as it's built.

**Nav tiles** (`NavServer`, C++):
- Each build is given a landing tick when it's dispatched: the nav tick + `build_delay_ticks`. A build that finishes early waits; at its landing tick, the builds due are committed in the order they were dispatched, waiting for any still running. The time budget for commits goes.
- The nav server ticks with the game: once per tick, after the tick (the feeder connects to the tick driver), not once per physics frame; the sources' interests are updated on ticks too.
- `is_idle` and how many builds may run at once follow from the landings, so they're the same on every run.

**The record.** `LandingLog` keeps every landing as (tick, kind, key) for recent ticks; the determinism check adds each tick's landings to its fingerprint, so a run that landed something on a different tick is named as such. Saving it in replays waits for input-based replay (the state store's step after this), which is what would read it.

**Measured, not guessed:** the check runs before and after (13.11), and the cost of waiting shows as `streaming.landings` and the nav tick in diagnostics.

## 14. Open

- **Reviews still to do** (the owner): the other major systems, which may change this spec. Abilities and AI behaviours are next; the controllers were reviewed on 2026-11-19 and fit (input commands are already plain data; their holder is the `ControllerManager`).
- **An architecture overview** (the owner, 2026-11-19): written, [ARCHITECTURE.md](../ARCHITECTURE.md).
- **Names:** `StateStore` is a working name for the service and its twin.
- **Clients:** proposed in 12.2 (received and predicted frames); to agree.
- **Variable data that can't be capped:** which lists stay derived (paths, AI memory facts beyond the store's slots).
- **Projectiles and other short-lived entities:** their own layout, and whether spawning goes through the store for them first.
- **Build order:** a sketch, to agree after the reviews: measure (13); the store with its twin beside the pawn table, fed by one gather; lag compensation and replay motion reading it; rollback history moved in; snapshot and replay encoding on workers; batched tick passes; deterministic replay and branches.

- **Determinism leaks** *(Claude 2026-11-22, from the determinism check, 13.11)*: settled the same day, both a fixed delay and a record: the landing schedule (13.12).
