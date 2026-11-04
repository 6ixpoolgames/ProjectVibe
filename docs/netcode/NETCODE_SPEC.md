<!-- Written by Claude (claude-opus-5-5), 2026-11-04: design spec for multiplayer (tick driver, rollback state, prediction, interpolation, lag compensation, packets), from the 2026-11-04 design discussion with the owner. Nothing built yet. -->

# Netcode Spec (draft 1)

**Status:** design draft, **not locked**. Written from the design discussion of 2026-11-04. **Built:** the offline tick driver (section 3, `assets/scripts/singletons/NetworkTime.gd`) and rollback state with offline replay (sections 3.5, 5 and 6, `assets/scripts/netcode/`). Tests: `singletons/tests/tick_driver_selftest`, `netcode/tests/tick_state_selftest`. Everything else is a proposal.
**Scope:** everything engine-wide about multiplayer: the tick driver every simulated entity runs on, how state is saved and rolled back, prediction, interpolation, lag compensation, and what goes over the wire. The pawn-specific parts (abilities, input buffer, intent) live in `docs/pawn/PAWN_ARCHITECTURE.md`, which follows the rules here.
**Approach:** our own implementation, **modelled on the netfox addon's concepts** (a network clock, rollback driven by declared state and input properties, tick interpolation for visuals). We study netfox; we don't depend on it. Unreal and Overwatch are studied the same way: we copy principles, never code.
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
   - **capture input** *(added 2026-11-04)*: predicted participants round and save the input, before anything simulates and possibly consumes it.
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

**(built 2026-11-04)** `NetworkTime.rollback(from_tick)`. A participant is predicted if it has `_rollback_load`, `_rollback_input`, `_rollback_simulate` and `_tick_record`; `TickStateComponent` provides all four. During a replay `NetworkTime.tick` reads as the replayed tick. It's allowed between ticks and from `before_tick`, and refused during a tick's phases or another replay. When two or more participants replay together, each one's `_sync_collision()` runs after loading and after each replayed tick (section 5.2). Once the replay is over, each one's optional `_rollback_finished()` runs (section 6.5).

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

**Not built yet.** `NetworkTime.tick_factor` exists and the tick loop respects it, but nothing sets it, because clock sync and server feedback need packets (build step 7).

**Frames with more than one tick** *(found and fixed 2026-11-04)*. A speed-up makes some frames run two ticks, and catching up after a hitch or a `tick_rate` above the physics rate do the same, while the server runs one per frame. A moved body only reaches the collision world at the next physics step, so the second tick collided with positions from before the first. Two pawns touching diverged from a one-tick-per-frame run by 0.8 cm with two ticks every 50 frames (about a 2% speed-up), and 20.9 cm with two ticks every 10 frames. The driver now calls each participant's `_sync_collision()` between ticks in such a frame, and both cases come out at 0.000 m. Frames with one tick pay nothing, and frames with no tick needed no fix. Only entities with a `TickStateComponent` get this. Tested with Jolt on flat ground.

### 4.3 How late things are, in tick numbers

Your pawn runs ahead of the server, and other pawns arrive from behind it, so the gap between them is bigger than either alone. At 60 ticks/s:

| Round trip | Your lead over the server | Newest server data, ticks behind your tick | Other pawn as drawn, ticks behind your tick | Replay length |
|---|---|---|---|---|
| 100 ms | 3 | 6 | 12 | 6 |
| 200 ms | 6 | 12 | 18 | 12 |

- **Newest data** is a full round trip behind, not half: half for the packet to arrive, and half because your pawn runs that far ahead.
- **As drawn** adds the ~100 ms interpolation delay.
- **Replay length** is also about one round trip, so the whole replay is past the newest server data.
- The lead's safety margin (`k × jitter + 1 tick`, or 3 ticks in stage v0) adds to all of these. This is why dilation is the other half of prediction: it can't shrink the gap below one round trip, but it stops wasted lead from making replays longer, and keeps inputs arriving in time.

---

## 5. Networked state

### 5.1 Three kinds of property

**(built 2026-11-04)** `TickStateComponent`: add it as a child of the entity and fill in the lists in the inspector. Entries look like `velocity`, `Walk:phase` or `yaw @angle_u16`. Entries are matched to nodes while ticks run and looked for again until found, so parts added later or removed at runtime are fine. Arrays and Dictionaries are copied per tick; Objects can't be, and warn. Only the input and state kinds are active so far; sync is declared and appears in the schema, but nothing uses it until packets exist.

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

**Engine-private state** *(found 2026-11-04)*: `CharacterBody3D` keeps its own "on floor" flag, which can't be set and still holds what the body is doing *now* after a load. Left alone, the first replayed tick snapped an airborne pawn to the floor (up to 4.9 cm of error in testing). So gameplay reads its own `grounded` property (in the state list), and the entity's `_on_state_loaded(tick)` hook makes the engine recompute the flag, then restores position and velocity. See `TickSamplePawn.gd`; the real motor does the same.

### 5.3 Encodings and quantisation

Every property in the schema has an **encoding type**: `vector3_mm` (the default for positions and velocities), `vector2_mm`, `vector3_cm`, `angle_u16`, `angle_byte`, `float`, `raw` (ints, bools, bitmasks), or `auto` to pick by type. Quantisation is **in from v0** (section 11.4). So far this only rounds values; packing them into bytes comes with the packets.

*(Revised 2026-11-04: positions are in **millimetres, not centimetres**.)* Rounding every tick means a value that changes by less than half a step per tick is rounded straight back. At 60 ticks/s, 1 cm stalls anything slower than 30 cm/s completely (measured: 0.2 m/s moved 0 m); 1 mm stalls below 3 cm/s, and 0.2 m/s moves 0.18 m in a second. Speeds are off by at most 3 cm/s, identically on server and client. `vector3_cm` and `angle_byte` remain for values that don't build up tick by tick, like a target point.

**Two rules for physics bodies** *(found 2026-11-04 by replaying a real `CharacterBody3D` and comparing)*:
- **`safe_margin` must sit between two rounding steps; the sample uses 0.0014.** A body rests one margin above the floor, and Godot's default is exactly 1 mm. Rounding parked it precisely on the edge of "touching", so float noise flipped the contact and the engine snapped it up to 2.4 cm into the floor while walking on flat ground.
- **Don't turn the body by writing `rotation` every tick.** Each write goes through Godot's Euler and scale conversion and adds a float error, so the body's scale drifted (about 0.99995) and differently in a replay. That changed the collision shape and gave errors up to 19.5 cm lasting 42 ticks. Facing is a plain `yaw` property in the state list; the body stays unrotated and only the model turns.

**Bodies replaying together must see each other** *(found 2026-11-04)*. With Jolt, a moved kinematic body reaches the collision world only at the next physics step; `force_update_transform()` doesn't help. A replay happens within one frame, so bodies collided with where the others were at the *end* of the replay, giving up to 2 m of error. `TickStateComponent._sync_collision()` makes the body static for that one call, because a static body's position applies at once, then restores its mode. Two pawns pushing against each other then replay with 0 mm of error. About 1.3 microseconds per call in a small test scene, and a replay of just one body skips it. Tested with Jolt only.

**A body replaying against one that isn't:** measured in section 6.5, with the open part in section 17, question 8.

**Measured replay accuracy, flat floor and a wall, one machine:** with both rules, most paths replay with 0 mm of error, across 7 different paths tested. One path showed about 2 mm for one tick, so it isn't always zero: contact can still come out slightly differently, for reasons not fully traced. The self-test requires at most 1 cm, gone within a few ticks. Rounding helps rather than hurts: with rounding off, the same runs were clearly worse. Slopes and moving platforms are not tested yet.

**Rule: authoritative state is quantised at the end of every tick, on server and client alike.** Both sides then simulate from exactly the values the wire can carry, so quantisation alone never causes a misprediction. (Quantising only when sending would make every prediction differ by a rounding error.)

### 5.4 Schema and hash

At startup each networked entity type's property lists become an ordered **schema**. Server and client run the same code, so schemas match. The default list that `FOLLOW_SERVER` uses when nothing is listed isn't part of the schema, because that mode can differ between machines. A **hash** of all schemas, the tag registry and the protocol version is compared at connect (section 11.2).

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
3. Compare S with the predicted state saved for 500 (`matches_state`). Equal within **tolerance** (per encoding) → nothing happens. This is the usual case. Tolerance is one and a half rounding steps (1.5 mm for positions and velocities). A difference larger than that causes a small replay and a correction too small to see, which is cheap, so this is deliberately strict. Two machines over a network may need more, which gets measured when packets exist.
4. Different → `rollback(500)` (section 3.5).
5. **The visual model doesn't snap.** It keeps an offset from the corrected body that fades over ~100 ms. The pawn already keeps `CharacterModel` separate from the physics body.

Mispredictions come from things the client couldn't know: being shoved, stunned or hit, or colliding with a pawn that was really somewhere else.

### 6.3 Side effects during replay

- `NetworkTime.is_resimulating()` is true while replaying. **Cosmetic effects** (sound, particles, camera shake) only fire when it's false.
- Predicted events are labelled with their tick, so an event re-triggered by replay is recognised and not played twice.
- A predicted event the server's state contradicts (the Dash you predicted, but you were stunned at 499) disappears in the rollback; its effects are cancelled or faded.

### 6.4 Re-runnable code

Predicted code must give the same result from the same state and input. That means: fixed `tick_dt`; **ticks for all gameplay timing** (cooldowns, buffer windows, durations); **seeded randomness** per entity per tick (`NetworkTime.tick_rng(key, salt)`, no global `randf()`; the rolls depend only on key, tick and salt, so there's no generator state to save); no reading wall-clock time.

### 6.5 Bodies that don't replay

**The mismatch can't be removed.** A replay needs the other pawn's positions on ticks your machine hasn't received (section 4.3), and some of them don't exist yet, because that player hasn't pressed those inputs. So the goal is to make the error small, let the server's correction settle it, and fade what's left on the visible model (section 6.2).

**What the client does:** during a replay, an entity that isn't predicted takes its position from server data as far as that goes, and from an estimate past it (`FOLLOW_SERVER` mode). This is smoothing on the client, and doesn't affect what the server decides:

| Replayed tick | Other entity's position | Source |
|---|---|---|
| Up to the newest server data | Where it really was | Server data |
| Past the newest server data | Newest position, carried forward on its velocity, up to a cap | Estimate |

Your correction and the other pawn's data normally arrive in the same packet, so nearly the whole replay is past the newest data. Server data mostly sets the starting point, and the estimate does the rest. Only the replay uses this. The pawn is still **drawn** at interpolation time.

**Velocity-only and full prediction.** Both guess the other pawn's movement past the newest server data, but differently:

| | Velocity-only (`FOLLOW_SERVER`, default) | Full prediction (`is_predicted`) |
|---|---|---|
| What runs each replayed tick | `position + velocity × time` | The entity's real simulation, with its last known input held |
| Steering, acceleration, gravity | No | Yes |
| Collides with things | No, it can pass through walls while estimated | Yes |
| Needs from the server | Position and velocity | Full state and input |
| Rewrites its own predicted state | No, it gets back what it had | Yes, and it's corrected like your own pawn |

**Measured offline, 2026-11-04, through the real code.** Two pawns seeking each other, with the other pawn changing direction at random every 10 ticks; 25 runs across 5 paths, replaying from every tick of a 40-tick window, each from the true state. The other pawn is drawn 6 ticks older than the newest server data. Numbers are how far the replay ended from the real run: average, with the worst case in brackets, in cm. Full prediction was measured once by hand in a temporary test; it's not a finished code path.

| Other pawn during the replay | 1–6 ticks | 7–12 ticks | 13–20 ticks | 21–40 ticks |
|---|---|---|---|---|
| Held where it's drawn | 10.3 (60.4) | 14.9 (59.6) | 26.3 (76.8) | 83.5 (229.9) |
| Held at newest server data (cap 0) | 2.7 (28.4) | 11.3 (61.1) | 17.1 (60.8) | 61.2 (191.9) |
| **Velocity-only, cap 0.2 s (default)** | 1.1 (13.5) | 4.2 (22.9) | 10.3 (38.9) | 60.9 (216.0) |
| Fully predicted, held input | 0.3 (13.5) | 2.2 (13.5) | 6.3 (40.3) | 66.9 (200.9) |

**The cap.** How far the estimate runs before the pawn holds still:

| Cap | 1–6 ticks | 7–12 ticks | 13–20 ticks | 21–40 ticks |
|---|---|---|---|---|
| 0.1 s | 1.1 (13.5) | 4.7 (33.6) | 13.1 (53.3) | 47.3 (170.5) |
| **0.2 s** | 1.1 (13.5) | 4.2 (22.9) | 10.3 (38.9) | 60.9 (216.0) |
| 0.25 s | 1.1 (13.5) | 4.2 (22.9) | 10.7 (49.8) | 67.7 (235.2) |
| 0.35 s | 1.1 (13.5) | 4.2 (22.9) | 11.1 (58.5) | 77.1 (240.8) |
| None | 1.1 (13.5) | 4.2 (22.9) | 11.1 (58.5) | 82.1 (240.8) |

**Reading it:**
- Velocity-only gets most of the benefit of full prediction at normal ping: at 200 ms, 4.2 cm against 14.9 cm for holding the pawn where it's drawn.
- 0.2 s is the default because it's the best up to 20 ticks and the highest cap tested that isn't worse than just holding at any length. 0.1 s does better only on replays over 20 ticks, a round trip above about 330 ms, and worse on normal ones.
- Full prediction is still the most accurate up to 20 ticks, which is why it stays available (section 7).
- **CPU, small scene, GDScript:** velocity-only added about 11–18 µs per pawn per replayed tick, and full prediction about 37 µs. These came from separate runs, and the order options ran in affected them, so treat them as rough.

**Replaying the client's own recording doesn't work.** That was the first version tried: the other pawn followed what this client had recorded for it. Since that record is late, it's even further from the truth than holding still. At 100 ms ping (1–6 tick replay, 12 ticks late) it averaged 4.5 cm against 4.2 cm held still, and at 200 ms (7–12 ticks, 18 late) 15.1 cm against 13.9 cm. Shifting that record forward by the lag can't help, because the drawn position is always older than the start of the replay.

**Limits of these measurements:** a stand-in for a network, with exact inputs, constant delay, no loss or jitter, and the ideal lead (section 4.3). Only replays are covered, not the original live prediction, which still collides with the pawn where it's drawn. Random direction changes every 10 ticks are still easier to guess than a real player may be: with long stretches of steady input, held input scored almost 0. Flat ground, Jolt, two pawns in GDScript. Re-measure with real packets at build step 10.

**Built 2026-11-04:** `TickStateComponent.replay_mode = FOLLOW_SERVER`, with `receive_server_state(tick, values)` for the snapshot code to call, `clear_server_state()` for teleports and respawns, and the settings `estimate_cap_seconds` (0.2) and `estimate_vertical` (off). During a replay the entity stands on server data, estimates past it, and gets back exactly what it had afterwards, without running its own simulation or `_on_state_loaded`. It keeps no history of its own. The position is the parent's `position` or `global_position`, and the velocity is any listed property called `velocity`, including on a part such as `Motor:velocity`. If it can only hold still and that looks like a mistake, it warns once. Nothing calls `receive_server_state` outside the tests until snapshots exist, and the setting isn't connected to `is_predicted` yet (build step 6).

---

## 7. Prediction policy

Prediction is a choice, not a given. MOBAs and RTS games often **don't** predict movement: you click, the server moves you, and the delay you feel is your ping. That's part of their feel, and fair to everyone. A shooter predicts so controls feel instant.

- **Project setting `default_prediction`:** `PREDICTED` (shooter, action) or `NONE` (MOBA-style felt delay). Default: `PREDICTED`.
- **Per-ability override** on `AbilityBase.prediction`: `INHERIT` (default), `PREDICTED`, `NONE`. Locomotion is an ability, so movement follows the same rule.
- **`NONE` still gives instant cosmetic feedback** (click marker, voice line, cursor), just no simulated result until the server says so.
- **Optional fixed input delay** (a few ticks): some genres (fighting games) prefer a small constant delay plus rollback to big corrections. It's a setting on the tick driver, default 0.

**Entity flags** *(decided 2026-11-04)*. Whether something is networked and whether this machine simulates it ahead are separate settings. This is what lets one engine serve both Rocket League-style and shooter-style games.

| `is_replicated` | `is_predicted` | Behaviour | Example |
|---|---|---|---|
| No | n/a | Local only | Particles, ragdoll debris |
| Yes | No (**default**) | Follows the server, drawn in the past, estimated during replays (section 6.5) | Other players in a shooter |
| Yes | Yes | Simulated ahead with its last known input, and re-simulated on correction | Rocket League cars and ball |

- Your own pawn is predicted according to the ability rules above, whatever these flags say about other entities.
- **Default off is deliberate.** Predicting everything that moves costs CPU on every replay, which a large swarm couldn't afford, needs input or velocity in every snapshot, and puts enemies at their present position where aiming and lag compensation (section 9) expect them in the past. A project default and a per-entity override turn it on.
- Unreal makes a similar per-actor choice in its networked physics, between Default, Predictive Interpolation and Resimulation.

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
- **During your replay:** entities that aren't predicted use the newest server position, carried on its velocity for up to 0.2 s (section 6.5). That cap is separate from the ~250 ms above, and neither changes where they're drawn during a replay.
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
| **Snapshot** | server → client, 30 Hz default, unreliable | server tick; your last processed input tick; input timing feedback (early/late, missed); your own pawn's full state; per visible entity: id + sync fields, including velocity for moving entities (section 6.5) |
| **Event** | reliable, as needed | spawn (id, type, initial state), despawn, death, phase events that must arrive |
| **Time sync** | a few per second | ping/pong with timestamps |

An input command is ~15 bytes (quantised move direction 2, move scale 1, aim 4, held mask 4–8, presses 2), so the input stream is ~5–6 KB/s even at 60 Hz with redundancy.

### 11.4 Stages

| Stage | Adds | Rough cost |
|---|---|---|
| **v0** (tier 0) | full snapshots, **quantised** (section 5.3), every entity to every client | ~25 bytes/entity with mm positions (3 bytes per axis); 20 entities at 30 Hz ≈ 15 KB/s per client |
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
| Input arrives after the server has passed its tick | Dropped; the client is corrected. The server never rewinds for movement |
| Snapshots stop arriving | Remote entities extrapolate briefly, then hold |
| Content hash mismatch | Connection refused with a message |
| Rollback longer than history | Snap to the server state, no replay, and warn |

---

## 16. Build order

The foundation (1–3) works offline and comes before the ability system, so abilities are built on it from day one.

1. **Tick driver, offline:** loop, phases, registry, `interpolation_fraction`. Headless test: order of phases, max ticks per frame, fixed delta. **Built 2026-11-04.** The pawn pipeline moves onto it as the new ability-based pawn parts are built (the old movement code is left as it is, per CLAUDE.md); that also removes today's ~2-frame input lag.
2. **Networked state contract:** property lists, encodings, quantise-each-tick, save/load overrides, state history. **Built 2026-11-04.**
3. **Offline rollback test:** a headless test that forces `rollback(n)` and checks replay reproduces the same states, and that cosmetic effects don't refire. This proves re-runnable code without a network. **Built 2026-11-04**, including a real `CharacterBody3D` walking, jumping and pushing into a wall on flat ground, on three paths, two pawns pushing against each other, and frames that run two ticks or none. Follow-server mode added and measured (section 6.5).
4. Transport + handshake + entity ids + spawn events.
5. Input packets, server input queues, snapshots v0, reconciliation.
6. Interpolation of remote entities; extrapolation; `is_replicated` and `is_predicted`; snapshots calling `receive_server_state` (section 6.5).
7. Clock sync and fixed lead (dilation v0), then dynamic dilation (v1).
8. Lag compensation for hitscan and melee; server projectiles.
9. Delta compression (packets v1), then relevancy and priority (v2).
10. A two-client test scene with simulated latency, loss and jitter. Re-measures section 6.5 with real packets.

---

## 17. Open questions

1. **Target player counts and genres** to tune defaults (tick rate, snapshot rate, history length).
2. **Hit markers:** predicted (instant, sometimes wrong) or confirmed (late, always right)? Per-game setting; which default?
3. **Projectile prediction** beyond the tier 0 cosmetic version.
4. **Data-only mod content** pushed by the server, so a modded server accepts vanilla clients.
5. **Rigid body props:** stay server-only, or predict some later?
6. **Relevancy method** for v2: distance, line of sight, or both.
7. **Dedicated server builds:** headless export without rendering, cameras or UI.
8. **Your pawn bumping a pawn that isn't replayed.** Built: newest server position, carried on its velocity for up to 0.2 s, during replays only (section 6.5). Still open: whether the original live prediction should also collide with something other than the drawn pawn (at 200 ms and 5 m/s that's about 1.5 m from what you see), and how it holds up with real packets (build step 10).

### To do, after discussing the deeper architecture

Found in the 2026-11-04 review, or raised while discussing it. Deliberately not fixed yet.

| # | Issue | Owner's notes |
|---|---|---|
| 1 | **Distance cutoff for following entities.** Every `FOLLOW_SERVER` entity joins every replay, roughly 1.3–2.2 s per correction with 10,000 pawns. Only ones near a replaying body need placing. Client only, since the server never predicts. | Wanted. A radius setting; about 10 m is a guess to measure |
| 2 | **Floor state is refreshed before other bodies are put back**, so a pawn standing on something that moves can start its replay with the wrong floor state. | Pawns shouldn't stack; simulate their collision instead. This would still matter for moving platforms. Also consider how the lead could smooth predictions |
| 3 | **`FOLLOW_SERVER` doesn't stop live simulation.** A remote pawn registered with the driver keeps ticking on old inputs while snapshots also place it. | Not discussed yet. Belongs with remote entities (build step 6) |
| 4 | **Rigid bodies and the collision sync.** `_sync_collision` briefly makes any body static, which may disturb a rigid body's speed or sleep state. It's a side effect of the workaround for Jolt deferring moved kinematic bodies. Untested. | Discuss with the physics issues |
| 5 | **2D bodies.** `_sync_collision` does nothing for 2D physics and doesn't warn. Whether 2D defers moved bodies the same way hasn't been checked. | A 2D implementation is wanted |
| 6 | **Pointless replays.** If only `FOLLOW_SERVER` entities load, as when your pawn is dead, the driver still walks every tick, returns true and emits `after_rollback`. | Ideas: prediction for movement, or flagging some states as replay off as a last resort |
| 7 | **`is_resimulating()` is false during load and finish**, so a rollback from a load hook could nest, and guarded effects there could fire. The fix is in a comment at `NetworkTime.rollback`. | Implementation only; comment left |
| 8 | **Vocabulary.** Align names and docs with standard terms (section 2), such as "authoritative" for what the server says and "extrapolate" for the velocity estimate. Renames `receive_server_state`, `estimate_cap_seconds`, `estimate_vertical`. | Owner is open to adopting standard terms |

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
| Positions and velocities round to 1 mm, not 1 cm; 1.5 mm tolerance when comparing predictions | 2026-11-04 |
| CharacterBody3D `safe_margin` is 0.0014, between two rounding steps, so contact isn't decided by float noise | 2026-11-04 |
| Physics bodies don't rotate; facing is a plain `yaw` state value and only the model turns | 2026-11-04 |
| Bodies replaying together sync to the collision world each tick by briefly going static; a single body skips it | 2026-11-04 |
| Lag compensation rewinds for attacks only. A movement input that arrives after the server has passed its tick is dropped, and the client is corrected | 2026-11-04 |
| On the client, entities that aren't predicted follow server data during a replay, then estimate from velocity for up to 0.2 s. The client's own recording isn't used | 2026-11-04 |
| Separate `is_replicated` and `is_predicted` settings; `is_predicted` is off by default, with a project default and per-entity override | 2026-11-04 |
| A frame running several ticks syncs bodies to the collision world between them | 2026-11-04 |
| Unreal, Overwatch and netfox are studied for principles; no code is copied | 2026-11-04 |
| A correction older than the history snaps without a replay, and warns | 2026-11-04 |
| Gameplay reads its own `grounded` state, and entities refresh engine-private floor state after a load (`_on_state_loaded`) | 2026-11-04 |
| Input is saved in its own phase, after input and before simulate | 2026-11-04 |
| The tick loop runs inside `_physics_process` with its own accumulator (physics queries stay safe); default tick rate = physics rate; `physics_factor` for `move_and_slide` | 2026-11-04 |
