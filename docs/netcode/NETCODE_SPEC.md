<!-- Written by Claude (claude-opus-5-5), 2026-11-04: design spec for multiplayer (tick driver, rollback state, prediction, interpolation, lag compensation, packets), from the 2026-11-04 design discussion with the owner. Nothing built yet. -->

# Netcode Spec (draft 1)

**Status:** design draft, **not locked**. Written from the design discussion of 2026-11-04. **Built:** the offline tick driver (section 3, `assets/scripts/singletons/NetworkTime.gd`, test in `singletons/tests/tick_driver_selftest`). Everything else is a proposal.
**Scope:** everything engine-wide about multiplayer: the tick driver every simulated entity runs on, how state is saved and rolled back, prediction, interpolation, lag compensation, and what goes over the wire. The pawn-specific parts (abilities, input buffer, intent) live in `docs/pawn/PAWN_ARCHITECTURE.md`, which follows the rules here.
**Approach:** our own implementation, **modelled on the netfox addon's concepts** (a network clock, rollback driven by declared state and input properties, tick interpolation for visuals). We study netfox; we don't depend on it.
**Numbers** are ballpark estimates, not measurements.

How to read this:
- Section 1 is the model in one page. Section 2 explains the jargon.
- Sections 3–6 are the foundation that gets built first, and works offline: the tick driver, clocks, networked state, rollback.
- Sections 7–11 are the multiplayer features on top.
- Sections 12–17: security, authority, Godot notes, defaults, build order, open questions. Section 18 logs decisions.

---

## 1. The model

**Server-authoritative, with client-side prediction.** This is the standard model for competitive action games.

- **The server is the truth.** It runs the simulation at a fixed tick rate. Clients send it **inputs only**, never positions or results.
- **Your own pawn is predicted.** Your client runs the same simulation code on your inputs immediately, so controls feel instant. When the server's answer arrives, the client checks its guess and corrects it if needed (**reconciliation**).
- **Everything else is interpolated.** Other players and AI pawns are drawn about 100 ms in the past, blended between server updates: slightly behind, never jittery.
- **Hits are judged by the server with rewind** (**lag compensation**): it checks what the shooter actually saw.
- **Prediction is a setting, per game and per ability** (section 7). A MOBA can turn it off and keep its ping-based input delay; a shooter predicts movement and abilities.

**Out of scope:** lockstep (every machine running an identical simulation from inputs alone). It needs bit-exact determinism that GDScript floats and Godot physics don't give.

Single player is just "no network": the same code runs, the local machine is the authority, and nothing is sent.

---

## 2. Glossary

| Term | Meaning |
|---|---|
| **RPC** | Remote Procedure Call: calling a function on another machine. In Godot, a function marked `@rpc` can be called on other peers with `my_func.rpc(args)`. We use only a few RPCs, carrying our own packed bytes |
| **Peer** | One connected machine. The server is a peer too |
| **Tick** | One fixed simulation step, numbered. At 60 ticks/second, tick 600 is 10 s in |
| **Authority** | The machine whose version of something is the truth. The server, for gameplay |
| **Prediction** | A client simulating ahead on its own inputs without waiting for the server |
| **Reconciliation** | Fixing a wrong prediction: load the server's state, then replay the inputs since |
| **Rollback** | The load-and-replay mechanism itself |
| **Interpolation** | Drawing something between two known past states |
| **Extrapolation** | Guessing ahead from the last known state, when updates stop arriving |
| **Lag compensation** | The server rewinding hitboxes to what a shooter saw |
| **Snapshot** | A server → client packet describing the world at one tick |
| **Ack** | "Acknowledged": a peer confirming which packet it received last |
| **RTT** | Round-trip time: there and back. "Ping" |
| **Jitter** | How much the RTT varies from packet to packet |
| **Quantise** | Store a number with less precision to save bytes (a position to the centimetre) |

---

## 3. The tick driver

**(built, offline, 2026-11-04)** `NetworkTime.gd`, class `NetworkTimeSingleton`, autoload `NetworkTime`. Participants implement any of `_tick_input(dt, tick)`, `_tick_simulate(dt, tick)`, `_tick_record(tick)`; all rules and corner cases are at the top of the script.

One autoload (working name `NetworkTime`). **Every machine runs it**, server and clients, online and offline. Everything that changes gameplay state runs inside it; nothing gameplay-relevant runs in its own `_process` / `_physics_process`.

### 3.1 Why a registered list, not signals

A signal is also a list of "call these when X happens". A list we keep ourselves gives **control**:
- **Order:** we decide exactly who runs first (controllers before abilities before motors). A signal runs in connection order.
- **Subsets:** a rollback re-runs only predicted entities, from one tick. The server never re-runs anything.
- **Several calls per entity:** gather input, simulate, save, load, each at its own time.
- It also skips signal overhead (name lookup, copying the connection list on every emit), though control is the real reason.

**Signals are still used for the few coarse phase events** that whole systems listen to (`before_tick`, `after_tick`, `after_rollback`): there are only a handful of listeners.

### 3.2 Contents

| Part | Contents |
|---|---|
| Settings | `tick_rate` (60), `max_ticks_per_frame` (6: stops the "spiral of death" where a slow frame causes more ticks, which cause slower frames) |
| State | `tick` (current number), time accumulator, `tick_factor` (time dilation multiplier; always 1.0 on the server and offline), `interpolation_fraction` (how far between two ticks this rendered frame is, for visuals) |
| Time sync (client only) | smoothed RTT and jitter, estimated server tick, target lead, current lead (section 4) |
| Registry | participants grouped by phase. `register(entity)` / `unregister(entity)`; the nexus registers pawns at spawn by default |

### 3.3 The loop

```
every physics frame:
    accumulator += physics_delta * tick_factor
    ran = 0
    while accumulator >= tick_dt and ran < max_ticks_per_frame:
        run_tick()
        accumulator -= tick_dt
        ran += 1
```

`get_interpolation_fraction()` combines the accumulator with Godot's physics interpolation fraction, so rendered frames between physics frames get a smooth 0..1 value.

`run_tick()` runs these phases in order:

1. **before_tick:** apply network messages that arrived (inputs on the server, snapshots on the client; a snapshot may trigger a rollback, section 6).
2. **input:** local controllers write this tick's **input command**. The server takes each remote player's queued command for this tick, or repeats their last one if it's missing.
3. **simulate:** per entity, in a fixed order. For a pawn: ability manager → abilities / Walk → motor (`move_and_slide`). Always with the fixed `tick_dt`, never the frame's delta.
4. **record:** predicted participants save their state into history (section 6).
5. **after_tick:** queue outgoing packets.

Visual-only work (models, camera, UI, interpolating remote pawns) stays per rendered frame, outside the loop, using `interpolation_fraction`.

### 3.4 Server and client run the same loop

- **Server:** `tick_factor` is fixed at 1.0, so the loop produces exactly `tick_rate` ticks per second. It is the reference timeline. It doesn't send its clock for clients to run on; it sends **tick numbers** and **timing feedback** (section 4).
- **Client:** the same loop, with `tick_factor` adjusted by time dilation.
- **Offline:** the same loop, factor 1.0, nothing sent.

*(Revised 2026-11-04 while building:)* the loop runs **inside `_physics_process` with its own accumulator**, not in `_process`. Physics queries are only safe during the physics step, and the accumulator still lets a dilating client run zero or two ticks in a physics frame. By default `tick_rate` = the project's physics rate, so offline it's exactly one tick per physics frame. `move_and_slide` scales velocity by Godot's physics delta, so if the two rates differ a motor multiplies velocity by `get_physics_factor()` before `move_and_slide` and divides after (the approach netfox uses). Godot can't be made to step RigidBody physics on demand, so rigid bodies are server-authoritative and interpolated, not predicted (section 14).

### 3.5 Rollback entry point (client)

```
rollback(from_tick):
    load server state into predicted participants for from_tick
    for t in from_tick + 1 .. current tick:
        re-apply the stored input command for t
        simulate and record, with is_resimulating = true
```

The driver owns order and timing only. **History data lives with each entity** (section 6).

---

## 4. Clocks and time dilation

### 4.1 Three clocks on a client

| Clock | Where it sits | Used for |
|---|---|---|
| **Predicted time** | ahead of the server by the **lead** | your own pawn and predicted abilities |
| **Server time (estimate)** | the server's present | measuring and adjusting the other two |
| **Interpolation time** | behind the server by the **interpolation delay** (~100 ms) | drawing remote pawns |

The server's timeline is the present. Each client runs **ahead** of it for its own inputs, so they arrive just in time, and draws others **behind** it, so there are always two snapshots to blend between.

### 4.2 Time dilation

**Only clients dilate. The server never does.**

- Each client has a **target lead**: `RTT / 2 + k × jitter + 1 tick`. A low-ping client has a small lead; a high-ping client a large one.
- The server reports, in every snapshot, how early that client's inputs are arriving and whether any were missed.
- **The client adjusts toward its target, not toward its ping.** Running further ahead than needed (inputs arrive too early: wasted latency, more mispredictions) → slow down slightly. Falling behind (inputs late or missed) → speed up slightly.
- Adjustments are small (a few percent, clamped). **At steady state every client runs at 1.0**; dilation only happens while correcting. A pawn moving 2% faster for a second is unnoticeable.
- It is **not** animation smoothing: it changes how many simulation ticks the client runs per second. Smoothing is interpolation (section 10).

**Stages:**
- **v0 (naive):** at connect, measure RTT a few times, set a fixed lead (`RTT / 2` + 3 ticks), never adjust. Fine on stable connections; a lag spike costs a few missed inputs.
- **v1 (dynamic, the goal):** continuous RTT and jitter measurement (ping/pong a few times a second, smoothed), server feedback, gentle tick-rate adjustment. v1 is v0 plus a feedback loop, so switching is cheap.
- The **interpolation delay adapts the same way**: more jitter, draw a little further in the past.

---

## 5. Networked state

### 5.1 Three kinds of property

GDScript has no custom annotations (no `@replicated`), and Godot's own `MultiplayerSynchronizer` has no tick numbers, history, acks or rollback. So each networked component **declares lists of property names**:

| Kind | Direction | Saved per tick? | Example |
|---|---|---|---|
| **input** | client → server, every tick | yes (client input history) | move direction, held mask, presses |
| **state** (rollback) | predicted locally, corrected by the server | yes | velocity, ability phase, cooldowns, buffer contents |
| **sync** (server-only) | server → clients | no (clients keep a few snapshots to interpolate) | health, team, remote pawn transforms |

- **Default: automatic from the lists.** Inspector-friendly for designers.
- **Override:** a component with unusual state implements `save_state() -> Dictionary` / `load_state(Dictionary)` instead.
- **Not listed = not networked.** That's the safe default for single player and for anything cosmetic.

### 5.2 What "state" must include

Everything that affects the future, not just position. To replay tick 501 from tick 500 a pawn needs position, velocity and grounded flag; the active ability with its phase and elapsed ticks; cooldowns and charges; the input buffer contents; predicted stats like stamina. If a value influences the next tick and isn't in state, replays drift.

### 5.3 Encodings and quantisation

Every property in the schema has an **encoding type**: `float`, `vector3_cm` (centimetres), `angle_byte`, `angle_u16`, `int`, `bitmask`, `bool`. Quantisation is **in from v0** (section 11.4).

**Rule: authoritative state is quantised at the end of every tick, on server and client alike.** Both sides then simulate from exactly the values the wire can carry, so quantisation alone never causes a misprediction. (Quantising only when sending would make every prediction differ by a rounding error.)

### 5.4 Schema and hash

At startup each networked entity type's property lists become an ordered **schema**. Server and client run the same code, so schemas match. A **hash** of all schemas, the tag registry and the protocol version is compared at connect (section 11.2).

---

## 6. History and rollback

### 6.1 Histories

Fixed-size ring buffers; anything older than the worst supported round trip is useless.

| History | Where | Size (default) | Holds |
|---|---|---|---|
| Input | client, per local player | 64 ticks (~1 s) | input commands the server hasn't confirmed |
| State | client, per predicted entity | 64 ticks | predicted state at each tick |
| Snapshot | client, per remote entity | ~4 snapshots | sync state to interpolate between |
| Hitbox | server, per hittable entity | 64 ticks | hitbox transforms for lag compensation |
| Sent snapshots | server, per client | ~32 | baselines for delta compression (stage v1) |

### 6.2 Reconciliation

1. A snapshot arrives: "at your tick 500 you were in state S, and I've processed your inputs up to 500".
2. Drop input history at or before 500.
3. Compare S with the predicted state saved for 500. Equal within **tolerance** (per encoding; quantisation keeps it tight) → nothing happens. This is the usual case.
4. Different → `rollback(500)` (section 3.5).
5. **The visual model doesn't snap.** It keeps an offset from the corrected body that fades over ~100 ms. The pawn already keeps `CharacterModel` separate from the physics body.

Mispredictions come from things the client couldn't know: being shoved, stunned or hit, or colliding with a pawn that was really somewhere else.

### 6.3 Side effects during replay

- `NetworkTime.is_resimulating()` is true while replaying. **Cosmetic effects** (sound, particles, camera shake) only fire when it's false.
- Predicted events are labelled with their tick, so an event re-triggered by replay is recognised and not played twice.
- A predicted event the server's state contradicts (the Dash you predicted, but you were stunned at 499) disappears in the rollback; its effects are cancelled or faded.

### 6.4 Re-runnable code

Predicted code must give the same result from the same state and input. That means: fixed `tick_dt`; **ticks for all gameplay timing** (cooldowns, buffer windows, durations); **seeded randomness** per entity per tick (no global `randf()`); no reading wall-clock time.

---

## 7. Prediction policy

Prediction is a choice, not a given. MOBAs and RTS games often **don't** predict movement: you click, the server moves you, and the delay you feel is your ping. That's part of their feel, and fair to everyone. A shooter predicts so controls feel instant.

- **Project setting `default_prediction`:** `PREDICTED` (shooter, action) or `NONE` (MOBA-style felt delay). Default: `PREDICTED`.
- **Per-ability override** on `AbilityBase.prediction`: `INHERIT` (default), `PREDICTED`, `NONE`. Locomotion is an ability, so movement follows the same rule.
- **`NONE` still gives instant cosmetic feedback** (click marker, voice line, cursor), just no simulated result until the server says so.
- **Optional fixed input delay** (a few ticks): some genres (fighting games) prefer a small constant delay plus rollback to big corrections. It's a setting on the tick driver, default 0.

**Never predicted as final:** damage, death, pickups, anything changing another entity. The client may show a predicted hit marker; health changes when the server says so. (Hit-marker policy is per game, section 17.)

---

## 8. Abilities under prediction

Detailed in the pawn spec; the netcode rules are:
- An ability's **state** (section 5.1): active, phase, elapsed ticks, cooldown "ready at" tick, charges. The ability manager's buffer and `locked_mask` are state too.
- Abilities report **phase events** (started / hit / ended, with the tick). The server sends these; clients play animations and effects from them, and confirm or cancel predicted ones.
- Cosmetic code in abilities checks `is_resimulating()`.

---

## 9. Hit detection and lag compensation

### 9.1 Hitscan and melee

- The server keeps a hitbox history (section 6.1).
- An attack command says "fired at tick T, seeing others at interpolation tick T − d".
- The server moves the other hitboxes to T − d, runs the ray or melee shape, restores them.
- **The rewind is capped** (default 200 ms). High-ping players can't hit people long since behind cover; past the cap, they have to lead their shots. Per-game setting.
- Rewinding is done **once per tick for all of that tick's attacks**, not per bullet.

### 9.2 Projectiles

Projectiles are **simulated on the server**, tick by tick. Each tick, each projectile sweeps from its last position to its new one (a ray or shape cast) against hitboxes. A sweep is cheap.

**Cheap rejection before the sweep (broadphase)** is standard, and is where an idea like "is this projectile converging on or diverging from a target?" belongs:
- Only test targets near the projectile's path this tick: a spatial grid, or Godot's physics broadphase, which already does this when we use physics queries.
- A projectile moving away from every target within range can skip precise tests that tick.
- It's a **filter, never the judgement.** Discarding "likely misses within a margin" as final would be wrong in a competitive game (targets dodge into shots, projectiles curve or bounce).

**Sprays:** each bullet's spread comes from **seeded randomness** (seed from entity id + tick + shot index). The client draws predicted tracers that match the server's bullets exactly; the server alone decides hits.

**Projectile prediction** (the shooter sees their projectile spawn instantly) is a per-game choice (section 17). Tier 0: the server spawns it; the shooter gets an instant cosmetic muzzle flash and a client-side visual projectile that the server's one replaces.

Rollback (section 6) and hit detection are separate: rollback fixes **your own pawn's** prediction; hit detection is a server job, with rewind for fairness.

---

## 10. Remote entities and UI

- **Interpolation:** each remote entity keeps ~4 snapshots and is drawn at interpolation time, blended between the two snapshots around it.
- **Extrapolation:** if snapshots stop, continue along the last velocity for up to ~250 ms, then hold.
- **AI pawns are remote pawns to clients.** Sensing, memory, states and behaviours run only on the server.

UI reads from whichever timeline its value belongs to:

| Value | Shown as |
|---|---|
| Your own predicted stat (stamina) | predicted value, instant |
| Your own server-only stat (health) | latest confirmed value, optionally tweened |
| An enemy's health bar | latest confirmed value; per-game polish option to show it at interpolation time, so it drops exactly when the hit visibly lands |

---

## 11. Packets

### 11.1 Transport

- Godot's ENet peer.
- Our data is packed into `PackedByteArray` with `StreamPeerBuffer` and sent through a few RPCs that carry raw bytes. No per-property Variant messages.
- **Unreliable** channel for inputs and snapshots (disposable: the next one replaces them). **Reliable** channel for events that must arrive.

### 11.2 Handshake

The **handshake** is the connection setup, not gameplay:
1. Client connects and sends its protocol version and **content hash** (schemas + tag registry).
2. **Hashes match:** server assigns a player id and entity ids, starts time sync, sends the initial world (spawn events).
3. **Hashes differ:** the server **rejects** the connection with a clear message ("version mismatch: server runs X"). It can't impose code on a client, and a mismatched client would desync silently. Later (section 17): data-only content (stat blocks, ability settings, which are resources, not code) could be pushed by the server so modded servers work with vanilla clients.

Damage, deaths and one entity affecting another aren't handshakes. A client never affects a non-local entity directly: it sends inputs, the server resolves the result, and the result reaches everyone as **sync state** (health) or a **reliable event** (death).

### 11.3 Packet types

| Packet | Direction, rate, channel | Contents |
|---|---|---|
| **Input** | client → server, every tick, unreliable | last snapshot received (ack); first tick number; the last ~4–6 input commands (redundancy against loss) |
| **Snapshot** | server → client, 30 Hz default, unreliable | server tick; your last processed input tick; input timing feedback (early/late, missed); your own pawn's full state; per visible entity: id + sync fields |
| **Event** | reliable, as needed | spawn (id, type, initial state), despawn, death, phase events that must arrive |
| **Time sync** | a few per second | ping/pong with timestamps |

An input command is ~15 bytes (quantised move direction 2, move scale 1, aim 4, held mask 4–8, presses 2), so the input stream is ~5–6 KB/s even at 60 Hz with redundancy.

### 11.4 Stages

| Stage | Adds | Rough cost |
|---|---|---|
| **v0** (tier 0) | full snapshots, **quantised** (section 5.3), every entity to every client | ~20 bytes/entity; 20 entities at 30 Hz ≈ 12 KB/s per client |
| **v1** | per-entity **changed-fields bitmask** + delta against the last acked snapshot | idle entities ~2–3 bytes |
| **v2** | **relevancy + priority budget**: only what a client can plausibly see; each entity builds priority over time (nearer and more important builds faster); each packet is filled highest-first up to a byte budget, so distant things update less often | scales to many entities |

Quantisation goes in v0 because the schema already carries an encoding type per property, and quantising state every tick (section 5.3) is easier to get right from the start than to retrofit.

Other standard savings, applied throughout: don't send derivable data (animation comes from velocity and ability phase); ENet's packet compression as an option.

---

## 12. Security and validation

The server never trusts a client:
- It accepts inputs only, never positions, hits or stat values.
- It validates every input command: clamps `move_scale` to 0–1 and directions to unit length; drops requests for abilities the pawn doesn't have; rate-limits presses.
- Late or missing inputs are replaced by the last one, never by client-supplied catch-up state.

---

## 13. Authority and local-only things

- **`context.is_authority()` / `NetworkTime.is_server()`**, defaulting to true offline (the escape clause). AI, state changes, ability resolution, damage and stat writes run only where it's true. Non-authoritative copies display.
- **Entity ids:** the nexus gives each entity an id at spawn, the same on every peer. Anything that refers to another entity over the network (intent targets, memory facts, ability targets) uses the id, never a node reference.
- **Tag registry bits are assigned in a fixed order** (declared categories, sorted) at startup, so bitmasks agree across peers.
- **Local-only, never networked:** camera, cursor, UI, debug drawing, the player controller's raw device reading. Only the owning client has a player controller for its pawn; the server reconstructs intent from input commands.

---

## 14. Godot notes and C++

- Godot's high-level multiplayer (ENet peer, RPCs) handles transport. `MultiplayerSpawner` / `MultiplayerSynchronizer` are not used for gameplay entities: relevancy needs per-client spawning, and they have no tick history.
- `move_and_slide` can run several times in one frame for replay. Other bodies stay where they are during the replay, the standard accepted inaccuracy.
- Godot physics isn't deterministic across machines. Fine here, because the server corrects clients; it only rules out lockstep.
- **RigidBody props** are server-authoritative and interpolated at tier 0 (Godot can't step them on demand for replay).
- **C++:** not needed to start. The server never replays; a client normally replays only its own pawn for a few ticks; `move_and_slide` is already C++. Candidates once profiling says so: packet encoding (quantise, bit-pack, delta), history ring buffers, hitbox rewind. They'd go into a GDExtension like navcore, behind the same interfaces.

---

## 15. Defaults and escape clauses

| Situation | Behaviour |
|---|---|
| No network | Authority everywhere, `tick_factor` 1.0, nothing sent; the game runs as single player |
| Entity with no property lists | Not networked; runs locally (cosmetic objects) |
| Component without save/load or a state list | Not predicted; on clients it shows server state |
| Entity not registered with the tick driver | Doesn't simulate; the nexus registers pawns by default and warns if one isn't |
| Input missing on the server | Last input repeated |
| Snapshots stop arriving | Remote entities extrapolate briefly, then hold |
| Content hash mismatch | Connection refused with a message |
| Rollback longer than history | Snap to the server state, no replay, and warn |

---

## 16. Build order

The foundation (1–3) works offline and comes before the ability system, so abilities are built on it from day one.

1. **Tick driver, offline:** loop, phases, registry, `interpolation_fraction`. Headless test: order of phases, max ticks per frame, fixed delta. **Built 2026-11-04.** The pawn pipeline moves onto it as the new ability-based pawn parts are built (the old movement code is left as it is, per CLAUDE.md); that also removes today's ~2-frame input lag.
2. **Networked state contract:** property lists, encodings, quantise-each-tick, save/load overrides, state history.
3. **Offline rollback test:** a headless test that forces `rollback(n)` and checks replay reproduces the same states, and that cosmetic effects don't refire. This proves re-runnable code without a network.
4. Transport + handshake + entity ids + spawn events.
5. Input packets, server input queues, snapshots v0, reconciliation.
6. Interpolation of remote entities; extrapolation.
7. Clock sync and fixed lead (dilation v0), then dynamic dilation (v1).
8. Lag compensation for hitscan and melee; server projectiles.
9. Delta compression (packets v1), then relevancy and priority (v2).
10. A two-client test scene with simulated latency, loss and jitter.

---

## 17. Open questions

1. **Target player counts and genres** to tune defaults (tick rate, snapshot rate, history length).
2. **Hit markers:** predicted (instant, sometimes wrong) or confirmed (late, always right)? Per-game setting; which default?
3. **Projectile prediction** beyond the tier 0 cosmetic version.
4. **Data-only mod content** pushed by the server, so a modded server accepts vanilla clients.
5. **Rigid body props:** stay server-only, or predict some later?
6. **Relevancy method** for v2: distance, line of sight, or both.
7. **Dedicated server builds:** headless export without rendering, cameras or UI.

---

## 18. Decisions so far

| Decision | Date |
|---|---|
| Full competitive model: server-authoritative, client prediction, reconciliation, interpolation, lag compensation | 2026-11-04 |
| Own implementation, modelled on netfox's concepts; no dependency | 2026-11-04 |
| One tick driver runs all gameplay, on every machine, online and offline; a registered list in fixed phases, signals only for coarse phase events | 2026-11-04 |
| Only clients time-dilate, toward a target lead from their own RTT and jitter; v0 fixed lead, v1 dynamic | 2026-11-04 |
| Networked properties are declared as input / state / sync lists; save/load override; not listed = not networked | 2026-11-04 |
| Quantisation from v0; authoritative state quantised every tick on both sides | 2026-11-04 |
| Prediction is a project default plus a per-ability override, so MOBA-style felt input delay is possible | 2026-11-04 |
| Projectiles: server-simulated, per-tick sweeps, broadphase culling as a filter only; seeded spread | 2026-11-04 |
| Content hash mismatch refuses the connection | 2026-11-04 |
| Lockstep is out of scope | 2026-11-04 |
| The tick driver and state contract are built before the ability system | 2026-11-04 |
| The tick loop runs inside `_physics_process` with its own accumulator (physics queries stay safe); default tick rate = physics rate; `physics_factor` for `move_and_slide` | 2026-11-04 |
