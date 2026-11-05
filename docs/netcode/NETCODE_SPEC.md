<!-- Written by Claude (claude-opus-5-5), 2026-11-04: design spec for multiplayer (tick driver, rollback state, prediction, interpolation, lag compensation, packets), from the 2026-11-04 design discussion with the owner. Nothing built yet. -->

# Netcode Spec (draft 1)

**Status:** design draft, **not locked**. Written from the design discussion of 2026-11-04. **Built:** the tick driver, rollback state, stage v0 multiplayer, dynamic time dilation and the test bench (section 16). Code: `assets/scripts/singletons/NetworkTime.gd` and `NetworkSession.gd`, and `assets/scripts/netcode/`. Tests: `singletons/tests/tick_driver_selftest`, `netcode/tests/tick_state_selftest`, `netcode/tests/net_selftest`. Playable: `net_sample.tscn`. Projectiles and packet stages v1 and v2 are still proposals.
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
| **RPC** | Remote Procedure Call: calling a function on another machine. In Godot, a function marked `@rpc` can be called on other peers with `my_func.rpc(args)`. We don't use RPCs for gameplay: see section 11.1 |
| **Peer** | One connected machine. The server is a peer too |
| **Tick** | One fixed simulation step, numbered. At 60 ticks/second, tick 600 is 10 s in |
| **Authority** | The machine whose version of something is the truth. The server, for gameplay |
| **Prediction** | A client simulating ahead on its own inputs without waiting for the server |
| **Reconciliation** | Fixing a wrong prediction: load the server's state, then replay the inputs since |
| **Rollback** | The load-and-replay mechanism itself |
| **Resimulation** | Running ticks again after a rollback. These docs also call it a replay |
| **Remote entity** | Anything on your machine that another machine controls |
| **Locally controlled** | The pawn this machine provides input for |
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

**Built 2026-11-04: dynamic dilation**, on by default, `time_dilation_enabled`. Rather than the formula above, it steers directly by what matters: the server reports how many ticks early each client's inputs are arriving, at worst, over the last half second and the last 5.
- Inputs arriving less than 1 tick early in the last half second: speed up, by up to 5%, at once.
- Inputs at least 3 ticks early through the whole of the last 5 seconds: slow down, by up to 3%.
- Otherwise: normal speed, 1.000.

The difference is deliberate: being late costs inputs, while being early only costs a little. The first version relaxed as soon as the last half second looked calm, and on Wi-Fi conditions it was worse than a fixed lead. A client more than 6 ticks behind where its clock says it should be, or 15 ahead, jumps back at once (4 either way with dilation off). It's checked every frame and goes by the fastest recent ping, so a freeze recovers immediately, and a lag spike neither looks like falling behind nor makes a jump land on an inflated lead. Catching up by speed alone cost about 2 seconds of lost inputs per 250 ms freeze. With no news for half a second, it runs at normal speed rather than act on an old answer. Only packets bringing new inputs count towards the timing, so duplicated or reordered packets don't look late. The 5-second check only counts once it covers the full 5 seconds.

**Measured, two clients in contact, 20 s, one run each, each client's conditions applied both ways (`net_measure --dilation`).** Bursts and spikes are random, so runs vary, and error figures can differ by half between identical runs:

| Conditions | Lead | Missed inputs | Resyncs | Inputs early, average / lowest | Speed | Own error, average / worst | Jump per s |
|---|---|---|---|---|---|---|---|
| Steady 100 ms | fixed | 0 | 0 | 2.8 / 2 | 1.000 | 2.0 / 115 cm | 23 cm |
| Steady 100 ms | dilation | 0 | 0 | 1.5 / 1 | 1.000 | 2.1 / 99 cm | 28 cm |
| Wi-Fi preset | fixed | 75 | 0 | 2.3 / -3 | 1.000 | 6.2 / 114 cm | 61 cm |
| Wi-Fi preset | dilation | 84 | 0 | 2.6 / -4 | 0.97–1.05 | 6.3 / 118 cm | 66 cm |
| Mobile preset | fixed | 113 | 0 | 2.4 / -13 | 1.000 | 11.0 / 231 cm | 62 cm |
| Mobile preset | dilation | 116 | 0 | 0.7 / -14 | 1.00–1.05 | 12.3 / 336 cm | 74 cm |
| Worst preset | fixed | 1031 | 3 | -3.5 / -27 | 1.000 | 103 / 779 cm | 373 cm |
| Worst preset | dilation | 742 | 1 | -2.3 / -31 | 0.97–1.05 | 69 / 643 cm | 283 cm |
| Ramp, 10 to 200 ms and back | fixed | 319 | 3 | 2.2 / -3 | 1.000 | 7.5 / 168 cm | 83 cm |
| Ramp, 10 to 200 ms and back | dilation | 1 | 0 | 2.7 / -1 | 0.97–1.04 | 5.1 / 190 cm | 45 cm |

**Reading it:**
- **Dilation clearly helps when conditions change and stay changed:** the ramp goes from 319 missed inputs to 1, with half the corrections.
- **Against short sudden spikes it's a tie,** as the Wi-Fi and mobile rows show. Inputs are already late before any feedback can get back, and the spike has often ended by the time the client has reacted. No dilation scheme can predict one. An earlier measurement showing mobile at 174 to 0 was wrong: it used spikes half the stated size.
- **The worst preset stays bad either way,** with about a third of inputs missed and errors near a metre, because 1-second bursts lose everything regardless of timing. It's a stress test, not a target.
- **A steady connection is left alone,** at speed 1.000.
- **When ping drops,** inputs arrive about 3 ticks early with dilation against about 5 with a fixed lead, closing slowly because it waits for 5 safe seconds.

Rendering to video makes a client look far worse, with resyncs and missed inputs, because movie mode ties its clock to how fast it can render rather than real time.

**Frames with more than one tick** *(found and fixed 2026-11-04)*. A speed-up makes some frames run two ticks, and catching up after a hitch or a `tick_rate` above the physics rate do the same, while the server runs one per frame. A moved body only reaches the collision world at the next physics step, so the second tick collided with positions from before the first. Two pawns touching diverged from a one-tick-per-frame run by 0.8 cm with two ticks every 50 frames (about a 2% speed-up), and 20.9 cm with two ticks every 10 frames. The driver now calls each participant's `_sync_collision()` between ticks in such a frame, and both cases come out at 0.000 m. Frames with one tick pay nothing, and frames with no tick needed no fix. Only entities with a `TickStateComponent` get this. Tested on Godot's physics and on Jolt, on flat ground.

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
- **Override:** a component with unusual state implements `save_state() -> Dictionary` / `load_state(Dictionary)` instead. *(2026-11-05:)* the Dictionary goes in every snapshot and gets corrected like list entries, so two rules apply. Its values must come out exactly equal on server and client: use ints, bools, ticks, or floats you've rounded yourself. And keep it small, since there are no encodings to shrink it. Entities drawn from snapshots ignore it: use sync properties for what they need to show.
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

**Bodies replaying together must see each other** *(found 2026-11-04)*. In Godot's physics (the project's engine until 2026-11-05), a moved kinematic body reaches the collision world only at the next physics step; `force_update_transform()` doesn't help. A replay happens within one frame, so bodies collided with where the others were at the *end* of the replay, giving up to 2 m of error. `TickStateComponent._sync_collision()` makes the body static for that one call, because a static body's position applies at once, then restores its mode. Two pawns pushing against each other then replay with 0 mm of error. About 1.3 microseconds per call in a small test scene, and a replay of just one body skips it. The tests pass on Godot's physics and on Jolt.

**A body replaying against one that isn't:** measured in section 6.5, with the open part in section 17, question 8.

**Measured replay accuracy, flat floor and a wall, one machine:** with both rules, most paths replay with 0 mm of error, across 7 different paths tested. One path showed about 2 mm for one tick, so it isn't always zero: contact can still come out slightly differently, for reasons not fully traced. The self-test requires at most 1 cm, gone within a few ticks. Rounding helps rather than hurts: with rounding off, the same runs were clearly worse. Slopes are fine (section 16, stress test). Moving platforms are not tested yet.

**Rule: authoritative state is quantised at the end of every tick, on server and client alike.** Both sides then simulate from exactly the values the wire can carry, so quantisation alone never causes a misprediction. (Quantising only when sending would make every prediction differ by a rounding error.)

### 5.4 Schema and hash

At startup each networked entity type's property lists become an ordered **schema**. Server and client run the same code, so schemas match. The default list that `FOLLOW_SERVER` uses when nothing is listed isn't part of the schema, because that mode can differ between machines. A **hash** of all schemas, the tag registry and the protocol version is compared at connect (section 11.2). *(2026-11-05:)* same-looking schemas don't prove two machines simulate the same, so it now also covers the engine build, every physics setting, the tick rate, and the game's files, or a named build (section 11.2).

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

**Queries of outside systems** *(2026-11-05)*: anything that can give a different answer later, such as a nav path while tiles are changing, must not be asked during a replay. Ask once in the input phase, and either save the result as state or let it become inputs, which a replay reuses. The test walkers do this: they path in the input phase and send plain directions. The nav server's answers aren't tied to a tick, so one asked during a replay gets today's mesh for an old tick. Section 4.2 of the pawn spec reads as if Walk asks each update, which would break this if it ran during a replay, so that's one to settle when the pawn is designed.

### 6.5 Bodies that don't replay

**The mismatch can't be removed.** A replay needs the other pawn's positions on ticks your machine hasn't received (section 4.3), and some of them don't exist yet, because that player hasn't pressed those inputs. So the goal is to make the error small, let the server's correction settle it, and fade what's left on the visible model (section 6.2).

**What the client does (standard, the default):** during a replay, an entity that isn't predicted stays where it's drawn. The server's correction settles what's left.

**Optional, off by default:** `follows_during_rollback` makes it take its position from server data as far as that goes, and extrapolate past it. It doesn't affect what the server decides. It was built and tested, then turned off because the numbers below don't justify it:

| Replayed tick | Other entity's position | Source |
|---|---|---|
| Up to the newest server data | Where it really was | Server data |
| Past the newest server data | Newest position, carried forward on its velocity, up to a cap | Estimate |

Your correction and the other pawn's data normally arrive in the same packet, so nearly the whole replay is past the newest data. Server data mostly sets the starting point, and the estimate does the rest. Only the replay uses this. The pawn is still **drawn** at interpolation time.

**Velocity-only and full prediction.** Both guess the other pawn's movement past the newest server data, but differently:

| | Velocity-only (`follows_during_rollback`, off by default) | Full prediction (`is_predicted`, off by default) |
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
| Velocity-only, cap 0.2 s | 1.1 (13.5) | 4.2 (22.9) | 10.3 (38.9) | 60.9 (216.0) |
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
- Offline, velocity-only looked much better than holding the pawn where it's drawn: at 200 ms, 4.2 cm against 14.9 cm. Real connections didn't bear that out (below).
- 0.2 s is that setting's default because it's the best up to 20 ticks and the highest cap tested that isn't worse than just holding at any length. 0.1 s does better only on replays over 20 ticks, a round trip above about 330 ms, and worse on normal ones.
- Full prediction is still the most accurate up to 20 ticks, which is why it stays available (section 7).
- **CPU, small scene, GDScript:** velocity-only added about 11–18 µs per pawn per replayed tick, and full prediction about 37 µs. These came from separate runs, and the order options ran in affected them, so treat them as rough.

**Replaying the client's own recording doesn't work.** That was the first version tried: the other pawn followed what this client had recorded for it. Since that record is late, it's even further from the truth than holding still. At 100 ms ping (1–6 tick replay, 12 ticks late) it averaged 4.5 cm against 4.2 cm held still, and at 200 ms (7–12 ticks, 18 late) 15.1 cm against 13.9 cm. Shifting that record forward by the lag can't help, because the drawn position is always older than the start of the replay.

**Limits of these measurements:** a stand-in for a network, with exact inputs, constant delay, no loss or jitter, and the ideal lead (section 4.3). Only replays are covered, not the original live prediction, which still collides with the pawn where it's drawn. Random direction changes every 10 ticks are still easier to guess than a real player may be: with long stretches of steady input, held input scored almost 0. Flat ground, two pawns in GDScript.

**Built 2026-11-04:** `TickStateComponent.rollback_mode = FOLLOW_SERVER`, with `receive_authoritative_state(tick, values)` for the snapshot code to call, `clear_authoritative_state()` for teleports and respawns, and the settings `extrapolation_cap_seconds` (0.2) and `extrapolate_vertical` (off). During a replay the entity stands on server data, estimates past it, and gets back exactly what it had afterwards, without running its own simulation or `_on_state_loaded`. It keeps no history of its own. The position is the parent's `position` or `global_position`, and the velocity is any listed property called `velocity`, including on a part such as `Motor:velocity`. If it can only hold still and that looks like a mistake, it warns once. `NetworkSession` calls `receive_authoritative_state` from snapshots, and `NetworkEntity` sets the mode from `is_predicted` when an entity spawns. During a rollback, a following entity only joins if it's within `follow_server_radius` of something being resimulated (10 m by default, a guess to tune), and a rollback with nothing to resimulate does nothing, so a large swarm stays affordable.

**Measured over real connections, 2026-11-04.** A server and two clients as separate processes, 5 ms jitter and 1% loss, about 20 s per row, one run each. The pawns seek each other and change direction at random, touching about 4–9% of the time, which is far more contact than normal play. "Own" is your pawn against the server on the same tick, as first predicted. "Jump" is how far the body moved per correction, which the model hides over about 100 ms. Columns are in cm, worst case in brackets.

| Round trip, what other pawns do during a rollback | Engine | Own | Corrections per s | Jump | Total jump per s |
|---|---|---|---|---|---|
| 0 ms, follow server | Godot | 1.2 (55) | 1.4 | 13.5 (64) | 19 |
| 0 ms, follow server | Jolt | 1.6 (61) | 1.6 | 16.4 (68) | 26 |
| 50 ms, follow server | Godot | 1.9 (131) | 0.7 | 28.9 (131) | 20 |
| 50 ms, follow server | Jolt | 3.8 (88) | 1.5 | 27.7 (88) | 42 |
| 100 ms, follow server | Godot | 5.6 (147) | 1.4 | 34.2 (147) | 48 |
| 100 ms, follow server | Jolt | 5.1 (138) | 1.0 | 43.3 (138) | 43 |
| 100 ms, held where drawn | Godot | 5.6 (159) | 2.3 | 21.0 (157) | 48 |
| 100 ms, held where drawn | Jolt | 8.1 (173) | 2.9 | 24.2 (161) | 70 |
| 100 ms, predicted | Godot | 0.3 (20) | 27.8 | 15.7 (110) | see below |
| 100 ms, predicted | Jolt | 0.4 (28) | 28.1 | 16.9 (130) | see below |
| 200 ms, follow server | Godot | 7.0 (237) | 1.1 | 41.3 (237) | 45 |
| 200 ms, follow server | Jolt | 7.0 (170) | 1.0 | 42.8 (170) | 43 |
| 200 ms, held where drawn | Godot | 6.6 (194) | 1.4 | 28.7 (190) | 40 |
| 200 ms, held where drawn | Jolt | 6.6 (178) | 1.4 | 31.8 (191) | 45 |
| 200 ms, predicted | Godot | 2.6 (101) | 27.5 | 35.2 (262) | see below |
| 200 ms, predicted | Jolt | 3.8 (158) | 28.6 | 32.6 (254) | see below |

**Reading it:**
- **With nobody nearby, prediction is exact:** 0.00 cm over 474 ticks, at 80 ms with jitter and 5% loss (`net_selftest`). All the error above comes from contact with the other pawn.
- **Follow server against held still:** in this first set, corrections are rarer but larger, and total movement and first-prediction error come out about the same. The offline test (4.2 cm against 14.9 cm) suggested a clear gain, and that doesn't show up here. These rows ran with following on by default, and 5 input repeats.
- **Repeated comparison, Godot's physics, three runs each, averaged:**

| Round trip, other pawns during a rollback | Own error | Worst | Corrections per s | Jump per s | Touching |
|---|---|---|---|---|---|
| 100 ms, stay where drawn | 5.8 cm | 148 cm | 2.15 | 50 cm | 6% |
| 100 ms, follow server | 5.5 cm | 142 cm | 1.77 | 50 cm | 9% |
| 200 ms, stay where drawn | 5.4 cm | 160 cm | 1.04 | 34 cm | 4% |
| 200 ms, follow server | 8.2 cm | 167 cm | 1.03 | 51 cm | 5% |

  A tie at 100 ms, and worse at 200 ms, though runs vary a lot and the follow rows had more contact. **So it's off by default**, which is also the standard behaviour and the simpler path.
- **Predicting other pawns** gets by far the lowest first-prediction error at 100 ms. Its correction count is high because nearly every snapshot differs slightly, by about 0.7 cm on average, and "total" isn't comparable because the count includes the other pawn's corrections. It costs more download (4.1 against 2.4 KB/s) and a resimulation on most snapshots, and puts enemies at their present position, so it stays off by default.
- **Remote pawns are drawn accurately:** within 0.3 cm of where they really were, about a round trip plus 10 ticks behind your own tick. No inputs were missed in any row.

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
| Yes | No (**default**) | Follows the server, drawn in the past, stays where it's drawn during replays (section 6.5) | Other players in a shooter |
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
- **The rewind is capped** (default 350 ms, changed from 200 on 2026-11-04). A shooter sees others about a round trip, plus margin, plus interpolation behind its own tick, which is about 217 ms at 100 ms ping and 350 ms at 200 ms ping. A 200 ms cap would have cut off normal players. High-ping players can't hit people long since behind cover; past the cap, they have to lead their shots. Per-game setting.
- **The claim is limited** *(added 2026-11-04)*. A client can't be drawing anything newer than the snapshot it last acknowledged in its inputs, or further behind that than `max_interpolation_seconds`, so the server caps what it claims to that. Acknowledgements can only move forward, and one older than the cap gets no rewind. So a low-ping client that's honest about its acknowledgements gets about 200 ms plus its real delay, instead of 350 ms. It doesn't stop everything: a client can deliberately keep acknowledging late, and that's indistinguishable from really having high ping, the classic lag-switch problem. The standard answer is the same: a cap, limits from what the server can measure, and accepting the rest, with statistical anti-cheat on top. Favoring the shooter itself is a known, accepted trade-off.
- **Built 2026-11-04** (`LagCompensation`). Measured with a target strafing at 5 m/s and the shooter aiming where it's drawn: at 100 ms ping, 22 of 23 shots hit, against 0 of 23 with it off; at 400 ms ping, past the cap, 0 of 22. Same on both physics engines.
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

- **Interpolation:** each remote entity keeps ~4 snapshots and is drawn at interpolation time, blended between the two snapshots around it. *(Built 2026-11-04)* The delay adapts: more jitter draws further back, from `interpolation_seconds` up to `max_interpolation_seconds` (0.1 to 0.2 s), so there are still two snapshots to blend. Measured at 150 ms of jitter: it ran out of snapshots 0 times against 5, at the cost of drawing about 4 ticks further back. At 60 ms, 100 ms is already enough, and it makes no difference.
- **Extrapolation:** if snapshots stop, continue along the last velocity for up to ~250 ms, then hold.
- **During your replay:** entities that aren't predicted stay where they're drawn. The optional `follows_during_rollback` is in section 6.5.
- **Built 2026-11-04** with one setting for both: `extrapolation_cap_seconds`, 0.2 s, rather than a separate ~250 ms.
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
- Our data is packed into `PackedByteArray` with `StreamPeerBuffer` and sent with `SceneMultiplayer.send_bytes`, which skips RPC setup. No per-property Variant messages. Every value starts with a one-byte tag, so a broken packet can be spotted and dropped (`NetPackets`).
- **Unreliable** channel for inputs and snapshots (disposable: the next one replaces them). **Reliable** channel for events that must arrive.

### 11.2 Handshake

The **handshake** is the connection setup, not gameplay:
1. Client connects and sends its protocol version and **content hash**: schemas, tag registry, engine build, every `physics/` project setting, tick rate, and the name and contents of every script, scene and resource. *(2026-11-05)* It's worked out once, when hosting or joining, and takes about 100 ms. Setting `project_base/network/build_id` replaces the file part with that name, which is the usual way for a release: stamp a build number when exporting. It's also the way out if the same project on two operating systems refuses itself because of line endings.
2. **Hashes match:** server assigns a player id and entity ids, starts time sync, sends the initial world (spawn events).
3. **Hashes differ:** the server **rejects** the connection with a clear message ("version mismatch: server runs X"). It can't impose code on a client, and a mismatched client would desync silently. Later (section 17): data-only content (stat blocks, ability settings, which are resources, not code) could be pushed by the server so modded servers work with vanilla clients.

Damage, deaths and one entity affecting another aren't handshakes. A client never affects a non-local entity directly: it sends inputs, the server resolves the result, and the result reaches everyone as **sync state** (health) or a **reliable event** (death).

### 11.3 Packet types

| Packet | Direction, rate, channel | Contents |
|---|---|---|
| **Input** | client → server, every tick, unreliable | last snapshot received (ack); first tick number; the last ~4–6 input commands (redundancy against loss) |
| **Snapshot** | server → client, 30 Hz default, unreliable | server tick; for this client: how early its inputs have been arriving, at worst, over half a second and over 5, and how many were missed; which server-decided features are on; per entity: id, state, sync fields, and input if it's predicted by others |
| **Event** | reliable, as needed | spawn (id, type, initial state), despawn, death, phase events that must arrive |
| **Time sync** | a few per second | ping/pong with timestamps |

An input command is ~15 bytes (quantised move direction 2, move scale 1, aim 4, held mask 4–8, presses 2), so the input stream is ~5–6 KB/s even at 60 Hz with redundancy. **Measured with the sample pawn:** 29 bytes per command, carried 3 times per packet, so 5.9 KB/s upload, with no missed inputs at 1% loss (reduced from 5 times and 9.3 KB/s). Two pawns take 2.4 KB/s download at 30 snapshots per second. A pawn's state is 25 bytes, as estimated.

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
- *(2026-11-05)* It limits what each client may send, before reading any of it: 2000 packets a second, 256 KB a second, 64 KB a packet (`max_packets_per_second`, `max_bytes_per_second`, `max_packet_bytes`; 0 means no limit). A client gets 2000 packets a second only because a client controlling 30 pawns sends about that. Before the handshake, only the packet that starts it gets through. Anything over is dropped and counted in `stats["packets_over_limit"]`. An offender isn't disconnected yet (section 17).
- *(2026-11-05)* An input packet is read whole before its timing counts, so a broken one can't feed time dilation or the rewind limit.

---

## 13. Authority and local-only things

- **`context.is_authority()` / `NetworkTime.is_server()`**, defaulting to true offline (the escape clause). AI, state changes, ability resolution, damage and stat writes run only where it's true. Non-authoritative copies display.
- **Entity ids:** the nexus gives each entity an id at spawn, the same on every peer. Anything that refers to another entity over the network (intent targets, memory facts, ability targets) uses the id, never a node reference.
- **Tag registry bits are assigned in a fixed order** (declared categories, sorted) at startup, so bitmasks agree across peers.
- **Local-only, never networked:** camera, cursor, UI, debug drawing, the player controller's raw device reading. Only the owning client has a player controller for its pawn; the server reconstructs intent from input commands.

---

## 14. Godot notes and C++

- Godot's high-level multiplayer (ENet peer, `send_bytes`) handles transport. `MultiplayerSpawner` / `MultiplayerSynchronizer` are not used for gameplay entities: relevancy needs per-client spawning, and they have no tick history.
- `move_and_slide` can run several times in one frame for replay. Other bodies stay where they are during the replay, the standard accepted inaccuracy.
- Godot physics isn't deterministic across machines. Fine here, because the server corrects clients; it only rules out lockstep.
- **Physics engine** *(decided 2026-11-05)*: the project runs on **Jolt**, for the measurements in section 14.1. Godot's own physics still passes the multiplayer tests, using a temporary `override.cfg`, for a game that prefers it. Notes before 2026-11-05 saying "tested with Jolt" were wrong, because the setting was still `DEFAULT` and they were written from the tuning values in `project.godot`. The real pawn in `test scene.tscn` has only had a headless smoke check on Jolt: how it feels can only be judged by playing it.
- **Tests need separate processes.** `NetworkTime` is a single autoload, so one process can't hold both a server clock and a client clock.
- **New scripts need registering.** A script with a new `class_name` needs an editor open or `--headless --import` once before headless runs can see it.
- **RigidBody props** are server-authoritative and interpolated at tier 0 (Godot can't step them on demand for replay).
- **C++:** see the profile below. New code would go into a GDExtension like navcore, behind the same interfaces.

### 14.1 Profile, and the plan for C++ *(measured 2026-11-05)*

`netcode/tests/net_profile`: a real server with AI pawns walking nav paths on hills, one client with 4 pawns of its own at 100 ms. One computer, both processes on it, one run per count. Costs grow in a straight line with pawn count from 25 to 400 pawns.

**Server, microseconds per pawn per tick.** All of it has to fit in 16.7 ms at 60 ticks/s.

| Part | Godot physics | Jolt | Jolt, after step 2 below | What it is |
|---|---|---|---|---|
| Simulate | 122 | 37 | 33 to 39 | Almost all `move_and_slide`, already C++. Alone in open ground, the script around it is about 2 µs |
| Physics engine's own step, and the rest of the frame | 63 | 21 | 17 to 26 | Already C++ |
| Save input | 17 | 16 | 0.3 | GDScript. The server has stopped doing this, since it never rolls back |
| Save state | 13 | 14 | 13 to 15 | GDScript. Still needed: the rounding, and the slot snapshots read from |
| Build snapshots | 9 | 9 | 9 to 10 | GDScript |
| Input and nav paths | 4 | 3 | 3 | Mostly GDScript |
| **Total** | **about 232** | **about 105** | **83 to 92** | From the rows with 100, 200 and 400 pawns |
| **Pawns that fit in 16.7 ms** | **about 70** | **about 160** | **about 190** | With 204 pawns, the frame averages 17.6 ms |

So now **about 70% of the server's time is already C++**, and about 30% is GDScript. Porting all the GDScript to C++ can't save more than that 30%, on the server.

**Client, for each remote pawn, per tick:** about 14 µs decoding snapshots and 11 µs placing it, about 25 µs in all, nearly all GDScript, and the same on both engines. Correcting your own pawn costs about 59 µs per pawn per replayed tick on Jolt and 150 on Godot's physics, so 2.4 ms per correction for 4 pawns at 100 ms. Client rows at 200 pawns and up are unreliable, because the overloaded server on the same computer makes replays much longer.

**One pawn, one call at a time, on Jolt:** `move_and_slide` 12 µs in open ground (105 on Godot's physics). Save input 14, save state 9, encode 8, decode 8, place a remote pawn 8, rewind 6, floor refresh 9, collision sync 2.

**Navigation isn't a bottleneck.** With 104 pawns, on Jolt:
- Paths average 14 to 23 µs each, even at 9,000 in a run. In one-at-a-time timing, a 91 m path takes 8 µs, and one with no route takes under 1 µs.
- The nav tick takes 0.01 ms per frame. Tile rebuilds take about 2.7 ms on worker threads, with under 0.1 ms on the main thread to commit them.
- Prediction isn't affected by how often pawns path: walkers send plain directions.

**Terrain edits are where systems interact:**
- An edit takes about 8.5 ms on the main thread, in the test terrain's GDScript: heights, mesh and collision.
- The physics frame runs up to about 10 ms slower for a second or two after each edit, and recovers fully when edits stop. Cause not pinned down.
- **Pawns can fall through the world:** raising the ground above a pawn leaves it under a one-sided surface. Up to 6 fell in a run, and there's nothing to catch them.
- These tests apply edits on every machine by tick number. Real edits have to be sent over the network, and that isn't built.

**The plan, in order:**

| Step | What | Expected gain | Certainty |
|---|---|---|---|
| 1 | **Jolt** as the project's physics engine | **Done 2026-11-05.** About 2.2 times the pawns | Measured |
| 2 | **Server saves no input history** | **Done 2026-11-05.** Saved about 16 µs per pawn, as estimated. The state history stayed: its rounding and current slot are still needed, so it saved nothing there | Measured |
| 3 | **C++ for the data path:** state rounding and history, packet encoding and decoding, placing remote pawns | Server from about 190 pawns to perhaps 250. Client cost per remote pawn perhaps a fifth | Estimate. **Snapshot encoding done 2026-11-05**, measured below. State rounding and history, and placing remote pawns, are still GDScript |
| 4 | **Delta compression and relevancy** | About 0.9 KB/s per pawn per client today. Needed well before any swarm | Bandwidth measured, savings not |
| 5 | **Swarms: crowd units with no `CharacterBody3D`** (nav spec) | 10,000 pawns at today's engine cost alone would take about 580 ms per tick, so C++ on its own can't do it. Needs bulk movement, and steps 3 and 4 | Arithmetic from measurements |

**C++ on principle:** the data path in step 3 is a good fit anyway: plain data, tight loops, no engine calls. Gameplay logic such as abilities and the pawn's steering stays in GDScript, since the script around `move_and_slide` costs very little, and modders and designers need to read and change it.

**Step 3's first piece: snapshot encoding** *(2026-11-05, `tests/net_codec_selftest`, `tests/net_profile`)*. Snapshots now go through `NetCodec` in `native/`, one call per snapshot. `NetPackets` stays as the fallback, used when the C++ library is missing, when its protocol version doesn't match, or when `NetworkSession.use_native_encoding` is off. Input packets and the other packets still use `NetPackets`.

The format now lives in two places, `NetPackets.gd` and `net_codec.cpp`, so a change has to go in both. `net_codec_selftest` fails if they differ. It compares them on 20,000 random lists, every cut-short length of 300 packets, and 3,500 broken packets. The `mixed_encoding` scenario in `net_selftest` plays a C++ server with a GDScript client, and the reverse.

Encoding alone, in microseconds per pawn for each snapshot, with a 37-byte pawn:

| Version | Write | Read |
|---|---|---|
| GDScript (`NetPackets`, the fallback) | 9.8 | 11.2 |
| GDScript written for speed (four value types only, so slightly flattered) | 1.7 | 2.0 |
| C++, one call per list | 0.6 | 1.0 |
| C++, one call for the whole world (what the game uses) | 0.7 | 0.6 |

Two other versions were measured and removed. Encodings passed as compiled numbers instead of names saved almost nothing. Flat arrays with no Variants took 0.07 to write and 0.05 to read, but need a fixed list of properties and state living in C++, and nothing in the game could use them.

In the running game, in ms per tick, averaged over two runs of each, taking turns on one computer. "200 pawns" is 200 AI pawns plus a client's 4:

| | 100 pawns, GDScript | 100 pawns, C++ | 200 pawns, GDScript | 200 pawns, C++ |
|---|---|---|---|---|
| Server: `send_snapshots` | 1.00 | 0.46 | 1.83 | 0.81 |
| Server: all tick work | 7.0 | 6.6 | 13.5 | 12.3 |
| Server: whole physics frame | 9.5 | 8.8 | 17.8 | 15.4 |
| Server: frames over 16.7 ms | 0 | 0 | 1555 and 1829, of about 2020 | 285 and 89, of about 2150 |
| Client: `flush` | 1.40 | 0.84 | 2.89 | 1.57 |
| Client: all tick work | 3.7 | 3.2 | 6.6 | 5.6 |
| Client: whole physics frame | 8.4 | 7.3 | 15.0 | 11.8 |
| Client: frames over 16.7 ms | 0 | 0 | 578 and 202, of about 1735 | 0 and 0, of about 1738 |

What this shows:

- The measured saving matches the estimate from the encoding test. The server saves about 5 µs per pawn per tick (4.3 estimated). A client saves about 5.5 to 6.5 µs (5.3 estimated).
- **At 200 pawns the whole frame improved by two to three times what tick work did,** in both runs, so it isn't one lucky run. At 100 pawns it's less clear, because client frames varied more from run to run. The cause isn't known. Server and client share one computer in this test, so one using less might help the other, but that's a guess. Check it on separate machines before relying on the larger number.
- So the server's limit goes from about 190 pawns to somewhere between 200 (counting only the tick work saved) and about 225 (going by whole-frame times). The over-budget counts make the gain look bigger than it is, because frames at 200 pawns sit close to the 16.7 ms limit, and a small saving tips many of them under it.
- Rollbacks and corrections show no difference. Rollbacks ranged from 78 to 218 with C++ and from 99 to 189 with GDScript, and those ranges overlap.
- Most of the old cost wasn't the language: GDScript written for speed is already over 5 times faster than `NetPackets`, and C++ is about 3 times that. Speed-tuned GDScript would have got most of the saving, but it handles only four value types, and C++ is a better fit for this job anyway.
- With no GDScript at all, the server tops out at about 270 pawns, because physics is already C++.
- What's left on a client, per remote pawn per tick: placing it, about 8.1 µs; storing server state, about 3.5; building the dictionary, about 1.4. On a server: saving state, about 9.5; gathering lists for snapshots, about 2.5.

All of this ran in the editor build of Godot with a debug C++ library, because no export templates are installed. A release build may be kinder to GDScript, so the gaps could narrow.

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

Revised 2026-11-04 while building: clock sync moved before input packets, because a client can't stamp its inputs with the right tick until it knows the server's. The fake bad network moved to the start, so every step gets tested under bad conditions.

**Foundation, built 2026-11-04:**
1. Tick driver, offline.
2. Networked state: property lists, encodings, rounding each tick, history.
3. Offline rollback test, including real bodies, walls, two pawns pushing against each other, and frames that run two ticks or none.

**Stage v0, built 2026-11-04.** Tests: `netcode/tests/net_selftest`, which runs real connections between separate Godot processes. Measurements: `netcode/tests/net_measure`, section 6.5.
4. Connection, handshake with hash check, entity ids, spawning (`NetworkSession`, `NetworkEntity`).
5. Fake network: latency, jitter and loss (`NetFakeConditions`).
6. Clock sync with fixed lead (`NetClock`).
7. Input packets and server input queue.
8. Snapshots and reconciliation.
9. Interpolation of remote entities, extrapolation, `is_replicated`, `is_predicted`.
10. Lag compensation for hitscan and melee (`LagCompensation`).
11. Measured at set pings.

**Built 2026-11-04, after v0:**
12. Test bench: feature switches and a worst-case fake network, below.
13. Dynamic time dilation (section 4.2) and adaptive interpolation (section 10).

**Next:**
14. Server projectiles (section 9.2).
15. Delta compression (packets v1), then relevancy and priority (v2).

### Stress test

`netcode/tests/net_stress`: a server and up to 7 client processes on one computer, on hills with collision and nav, 44 to 52 pawns walking random nav paths for 30 s. Each client owns 4 walkers, works out their paths itself and sends directions as input. The server adds 20 AI walkers. Measured 2026-11-05 on Godot's physics, one run per row:

| Row | Good clients' own error, average | Bad client's own error, average / worst | Server frame | Server sends |
|---|---|---|---|---|
| Within limits: 20 to 200 ms | 2.3 to 7.0 cm | | 8.8 ms | 199 KB/s |
| One bad: plus 400 ms | 2.6 to 7.6 cm | 8 cm / 3.6 m | 10.1 ms | 265 KB/s |
| Two bad: plus 400 ms and worst preset | 1.6 to 5.8 cm | 15 cm / 4.4 m and 55 cm / 8.6 m | 11.0 ms | 338 KB/s |
| Client freezing 250 ms every 4 s | 0.9 to 4.5 cm | 11.6 cm / 3.1 m | 8.6 ms | 200 KB/s |
| Server freezing 150 ms every 4 s | 2.5 to 8.0 cm | | 8.7 ms | 200 KB/s |

**Reading it:**
- **A bad connection doesn't hurt anyone else.** Good clients' numbers don't get worse as others go out of bounds, within the noise between runs. Others just see that one pawn behave badly, as designed. They pay for it only in bandwidth, and the rise in the server's load comes with the extra pawns as well.
- **Slopes and nav work.** One pawn alone on hills, walking 155 m over 6.6 m of height, was within 0.20 cm of the server, on both physics engines. With other pawns about but none within 2 m, the average stays under 2 cm within limits. The worst cases there, up to about 2 m, are probably corrections still settling after contact.
- **Within limits, single errors of 1 to 3 m still happen** during pawn contact (To do, section 17).
- **Freezes recover quickly.** A client freezing 250 ms loses about 11 inputs per pawn per freeze, close to what the freeze itself costs, against about 90 before the jump-back. A server freeze costs each client a few ticks of input. No pawns fell through the world, and the server never dropped a tick.
- **Jolt:** the within-limits row looks the same for clients, and the server frame is 5.7 ms against 8.8 ms.

The first runs found two real bugs: a per-client packet limit too small for a client with 4 pawns during a server freeze, and the slow recovery from a freeze. All of this ran on one computer, so some stalls may be the computer's.

### Test bench

Debug builds only. `NetTestBench` puts these on keys in `net_sample.tscn`, and the headless tests use the same code with fixed seeds, so a worst case can stay a permanent test.

**Fake network** (`NetFakeConditions`). `NetworkSession.fake` handles sending and `fake_in` receiving, so one window sets its whole ping. Latency, jitter, jitter that wanders over time, random loss, bursts of total loss, lag spikes, reordering and duplicates can all change while running. Reliable packets are never lost. Presets, as round trips:

| Preset | Ping | Jitter | Wander | Loss | Spikes | Bursts |
|---|---|---|---|---|---|---|
| good | 30 ms | 2 ms | | | | |
| wifi | 60 ms | 20 ms | 50% | 1% | 100 ms, 1 per 20 s | 0.15 s, 1 per 33 s |
| mobile | 120 ms | 40 ms | 70% | 3% | 250 ms for 1 s, 1 per 10 s | 0.4 s, 1 per 20 s |
| worst | 250 ms | 80 ms | 100% | 8% | 500 ms for 1.5 s, 1 per 4 s | 1 s, 1 per 7 s |

A spike hits one direction at a time, so it adds its full size to the round trip. These figures are chosen to be recognisably bad, not measured from real networks. Worst also adds 5% reordering and 2% duplicates, and mobile 2% reordering.

**Feature switches.** `NetworkSession.set_feature(name, on)`, all live:

| Key | Feature | Off means |
|---|---|---|
| 1 | `prediction_enabled` | Your own pawn waits for the server, so what you do shows up after your ping |
| 2 | `reconciliation_enabled` | Your own pawn is never corrected, so it drifts |
| 3 | `interpolation_enabled` | Remote pawns jump to each newest snapshot |
| 4 | `extrapolation_enabled` | Remote pawns hold when nothing newer has arrived |
| 5 | `correction_smoothing_enabled` | You see the jump when corrected |
| 6 | `lag_compensation_enabled` | Shots are checked against where targets are now |
| 7 | `default_predicted` | On, other pawns are predicted too. Off by default |
| 8 | `follow_during_rollback` | On, other pawns stand on server data during a rollback. Off by default |
| 9 | `time_dilation_enabled` | Fixed lead, jumping back when it drifts |
| 0 | `adaptive_interpolation_enabled` | Interpolation delay stays at `interpolation_seconds` |

Hitches are part of the tests too: a machine can be made to freeze on a schedule.

The server-side ones (6 and 7) only ask the server, which only obeys a client that passed the handshake, in a debug build with `allow_debug_commands` on. Each snapshot says what the server's are, so every client's panel shows what's really in effect. Key 7 therefore affects everyone.

---

## 17. Open questions

1. **Target player counts and genres** to tune defaults (tick rate, snapshot rate, history length).
2. **Hit markers:** predicted (instant, sometimes wrong) or confirmed (late, always right)? Per-game setting; which default?
3. **Projectile prediction** beyond the tier 0 cosmetic version.
4. **Data-only mod content** pushed by the server, so a modded server accepts vanilla clients.
5. **Rigid body props:** stay server-only, or predict some later?
6. **Relevancy method** for v2: distance, line of sight, or both.
7. **Dedicated server builds:** headless export without rendering, cameras or UI.
8. **Your pawn bumping a pawn that isn't replayed.** It stays where it's drawn, the standard behaviour, and the server corrects the difference (section 6.5). Still open: whether a real network or real players change that, and how to keep the large one-off corrections down (To do, below).

### To do

| # | Issue | Notes |
|---|---|---|
| 1 | **Faked lag.** The rewind claim is limited by a client's snapshot acknowledgements (section 9.1), but a client can deliberately acknowledge late, which looks like real high ping. Tighter limits would also cut off real players. The standard answer adds statistical anti-cheat on top | Accepted, a known industry problem. Statistical anti-cheat **deferred 2026-11-05** |
| 2 | **Large one-off corrections.** Worst cases of 1.4–2.4 m at 100–200 ms during pawn contact. Probably a pawn blocked on the server that wasn't blocked on the client, whose view of the other pawn is 300 ms old. Cause not confirmed. The visible model fades a jump over about 100 ms, which may look bad at that size | Investigate; options include softer pawn collisions |
| 3 | **Pawn stacking.** Owner: pawns shouldn't stack, and should collide instead. Nothing stops one standing on another yet | Belongs with the motor |
| 4 | **Spending the lead.** The standard way is an optional input delay (section 7): shorter replays, less responsive feel | Not built; a per-game setting, off by default |
| 5 | **Rigid bodies and the collision sync.** `_sync_collision` briefly makes any body static, which may disturb a rigid body's speed or sleep state. Untested | **Deferred 2026-11-05.** Server-simulated rigid bodies are moderate work: record without writing back, a rotation encoding, frozen on clients, skipped by lag compensation and the sync. Predicted rigid bodies, such as a Rocket League ball, are much harder, because as far as we know Godot can't step one body on demand |
| 6 | **2D.** `_sync_collision` does nothing for 2D physics and doesn't warn. Whether 2D physics defers moved bodies the same way hasn't been checked. Lag compensation is 3D only | Wanted, **deferred 2026-11-05**. Moderate work. It needs a coarser position encoding first, because 0.001-unit steps limit positions to about 8,300 pixels |
| 7 | **Physics engine.** Settled 2026-11-05: Jolt. Godot's own physics still passes the multiplayer tests | Done. The real pawn still has to be played on Jolt by hand |
| 8 | **Upload size.** Inputs take 5.9 KB/s, about what section 11.3 estimated, though each command is about twice the estimated size | Could shrink with packed fields |
| 9 | **Vocabulary in docs.** Code now uses standard names. These docs still often say "replay" for resimulation | Tidy as sections get rewritten |
| 10 | **Lag compensation once per attack.** Section 9.1 wants one rewind per tick for all attacks. Tier 0 rewinds per attack | Costs more only if many fire on one tick |
| 11 | **Not tested:** real internet connections, more than about 50 pawns, moving platforms, or playing by hand | |
| 12 | **Server cost.** About 70 pawns fit on Godot's physics and 190 on Jolt; 200 to 225 on Jolt with C++ snapshots | Profiled, with a plan: section 14.1 |
| 13 | **No crowd control.** Pawns follow paths and physically bump, with no avoidance. `CrowdSystem` is planned in the nav spec, not built. It would normally run on the server, and a predicted pawn can't predict it, which adds to the mismatch | Wanted eventually |
| 14 | **Bandwidth at scale.** 44 pawns take about 44 KB/s down per client and 200 KB/s up from the server, and each pawn's input is its own packet | Delta compression and relevancy (section 16); bundle a client's inputs |
| 15 | **Who paths a player's pawn?** The stress test has clients path their own walkers and send directions, to test prediction. Whether a click sends a target for the server to path is part of the intent question in the pawn spec | Owner is thinking about the pawn architecture |
| 17 | **Pawns can fall through the world** when ground is raised above them, and nothing catches them. Needs a rule in the motor or terrain, and a safety net for anything falling forever | With the motor; found in section 14.1 |
| 18 | **Terrain edits aren't sent over the network.** The tests apply them everywhere by tick number | With the real terrain system |
| 19 | **A client over the packet limits only gets dropped, not disconnected.** It still costs the server a little per packet | Disconnect after a sustained flood; pick the numbers from real play |
| 20 | **Custom state goes to every client,** including those who only draw that entity and ignore it | With relevancy (section 14.1, step 4) |
| 21 | **Entities spawned or removed during a replay** aren't tested | From the 2026-11-05 audit. Matters once abilities spawn things |
| 22 | **Hit history is position only.** A rewind moves the whole body back, not its pose | From the 2026-11-05 audit. Matters once hitboxes follow animation |
| 23 | **`NetworkSession` is over 1,000 lines,** and does connecting, spawning, inputs, snapshots and clock control | From the 2026-11-05 audit. Split it when something else needs to change in there |
| 24 | **Two timing checks in `net_selftest` fail now and then:** "settles with inputs 1 to 2 ticks early", and "no more missed inputs than a fixed lead". The second compares two noisy numbers: a fixed lead missed 0 inputs in one run and 177 in the next. Seen once in two runs on 2026-11-05, in a change the game doesn't run. Cause not confirmed | Make them hold over several runs, or compare against a margin |
| 16 | **Occasional stalls of several seconds on one client.** A healthy client sometimes runs about 10% fewer frames in a run, with late drawing or lost inputs. Probably the one test machine being overloaded, since nothing about that client stands out. Not confirmed | Check on a machine that isn't running 7 processes |

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
| Entities that aren't predicted stay where they're drawn during a replay. Following server data with velocity is optional and off, because it measured no better over real connections | 2026-11-04 |
| When on, following entities only join a rollback within a radius of something being resimulated. A rollback with nothing to resimulate does nothing | 2026-11-04 |
| Each input packet carries 3 inputs, which saved about 40% of upload with no missed inputs at 1% loss | 2026-11-04 |
| Lag compensation's rewind cap is 350 ms, because 200 ms would cut off normal players | 2026-11-04 |
| Stage v0 keeps a jump-back resync if a client drifts more than 4 ticks; 15 with dilation on | 2026-11-04 |
| Dilation steers by how early inputs really arrive: speeds up on the last half second, slows down only if the last 5 seconds were safe | 2026-11-04 |
| Test switches and client-sent server switches exist only in debug builds | 2026-11-04 |
| Multiplayer tests use real connections between separate processes, plus a fake bad network in our own code | 2026-11-04 |
| Separate `is_replicated` and `is_predicted` settings; `is_predicted` is off by default, with a project default and per-entity override | 2026-11-04 |
| A frame running several ticks syncs bodies to the collision world between them | 2026-11-04 |
| Unreal, Overwatch and netfox are studied for principles; no code is copied | 2026-11-04 |
| A correction older than the history snaps without a replay, and warns | 2026-11-04 |
| The project runs on Jolt; tests can still run on Godot's own physics | 2026-11-05 |
| `save_state` data goes in snapshots and is corrected; its values must compare exactly | 2026-11-05 |
| The handshake compares the engine build, physics settings, tick rate and game files, or a named build | 2026-11-05 |
| The server limits packets and bytes per client, before reading them | 2026-11-05 |
| Queries of outside systems, such as nav, are never made during a replay | 2026-11-05 |
| Snapshots are encoded in C++ with `NetPackets` as the fallback; both write the same bytes, so machines using either can play together | 2026-11-05 |
| Gameplay reads its own `grounded` state, and entities refresh engine-private floor state after a load (`_on_state_loaded`) | 2026-11-04 |
| Input is saved in its own phase, after input and before simulate | 2026-11-04 |
| The tick loop runs inside `_physics_process` with its own accumulator (physics queries stay safe); default tick rate = physics rate; `physics_factor` for `move_and_slide` | 2026-11-04 |
