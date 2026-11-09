<!-- Written by Claude (claude-opus-5-5), 2026-11-09: the tier 1 plan for running many more pawns on a server: plain data, worker threads and the owner's scheduler. From the 2026-11-09 discussion with the owner. A draft to agree, nothing built. -->

# Scaling Spec v0.5 (tier 1, being built)

**Status:** agreed by the owner on 2026-11-09 ("Ok. Proceed") and being built, step by step (section 10). **Built:** step 1, the pawn table (3.1). The groundwork it stands on is pawn spec 15.
**Scope:** how a server runs many more pawns: a shared table of plain pawn data, worker threads with the owner's scheduler, the AI on workers, simulating far-away pawns less often, crowd movement for AI units, and per-client network work. Clients change little.
**Why:** on the owner's PC, which is above average, about 235 fighting pawns fit in a 60 Hz tick today (pawn spec 15.6), so about **145 on the target machine** (section 0). The owner's words: "My machine is above average and 250ish units networked is far from ideal."
**Numbers** marked "guess" are estimates until a step is built and measured.

**Revisions:**
- v0.1 (2026-11-09): first draft.
- v0.2 (2026-11-09): the owner's corrections: spec for a low-end machine with 4 cores at most, not the owner's PC (section 0), and share the work out according to the machine it runs on (4.1).
- v0.3 (2026-11-09): the owner's answers. Tier 1 goes ahead. No crowd movement yet (8 moves after tier 1). Props block sight (6). Decisions one tick later is fine. The numbers are for a **dedicated server** on the target machine, aiming at **500 fighting units** (0.1).
- v0.4 (2026-11-09): the owner's calls: the tick rate is **chosen before a match starts**, so every machine agrees; changing it during a match, and per-pawn rates for distant units, are for later rounds (7). Settings counted in ticks keep ticks, at a reference rate of 60 (7).
- v0.5 (2026-11-09): agreed; step 1 built (3.1). The table is read at the first use in a tick, not in the record phase (3).

---

## 0. The target machine

**The owner's call (2026-11-09): spec for a lower-end machine with 4 cores at most, not the owner's PC.**

What the Steam Hardware Survey shows (October 2026, from Valve's page and press coverage of it; the survey is voluntary, so it describes the people who answer it):

| Physical cores | Share of Steam machines | Running total from the bottom |
|---|---|---|
| 2 | about 1 to 2% | about 2% |
| 4 | about 12 to 13% | about 14% |
| 6 | about 27 to 28% | about 42% |
| 8 | about 28 to 29% | about 71% |
| 12, 16, 24 and more | the rest | 100% |

- **4 cores is roughly the bottom 14%:** a stricter bar than the bottom fifth (20%) or third (33%) asked about. The bottom fifth to third falls inside the 6-core machines, mostly older ones such as an Intel i5-8400 or i5-9400F (6 cores, 6 threads) or a Ryzen 5 2600 (6 cores, 12 threads).
- So **designing for 4 cores covers the bottom fifth to third with room to spare.** The streaming spec's target ("about 4 to 6 older cores", `docs/streaming/STREAMING_SPEC.md` section 2) is the same range; this spec takes its lower end.
- **Speed per core matters as much as the count,** because the main thread runs on one core. Older budget chips manage roughly 60 to 65% of the owner's Ryzen 9 5900X on one core (a guess from public single-thread benchmarks). So **anything measured on the owner's PC is multiplied by about 1.6** for the target here.
- **The rest of the target machine,** from the same survey: 16 GB of memory (the most common size) and an entry-level graphics card. Graphics matter for a player hosting a game, who renders too; a dedicated server doesn't.

**The target machine for this spec:**
- 4 cores, possibly without hyper-threading, so up to 3 worker threads besides the main thread, and fewer if the machine also renders the game (4.1)
- about 1.6 times slower per core than the owner's PC
- 16 GB of memory

**A dedicated server** *(v0.3, the owner's call)*: the numbers in this spec are for a dedicated server on the target machine, which renders nothing. So it has 3 worker threads besides the main thread, and nearly the whole tick for the simulation.

**How it's measured** without such a machine: `pawn_stress` and `net_stress` get the same trick `chunk_stress` uses (a pretend slower CPU, `streaming/tests/SlowChunkStreamer.gd`): the main thread's work is stretched by a factor (1.6), and the workers are capped at 3. Checked against a real low-end machine when one is available.

How to read this:
- Sections 1 and 2: where the time goes, and the rules every tier 1 piece follows.
- Sections 3 to 9: the pieces, in the order they'd be built.
- Sections 10 and 11: the build order with what each step must show, and the open questions.

### 0.1 The target: 500 fighting units *(v0.3)*

The owner asked whether 500 fighting units on a 4-core dedicated server is reachable. Claude's working, all guesses until measured, in microseconds of main-thread time per fighting unit on the target machine (the owner's PC's numbers × 1.6):

| Part | Today | After tier 1 steps 1 to 7, no crowd movement |
|---|---|---|
| AI | ~37 | ~6: gathering and applying; the rest on workers (6) |
| Abilities, GDScript | ~13 | ~13 |
| `move_and_slide`, gravity | ~22 | ~22 |
| Recording | ~8 | ~8 |
| Physics engine step | ~8 | ~8 |
| Network and the rest, on a dedicated server | ~5 | ~5 |
| **Total** | **~93** | **~62** |
| **Units in a 60 Hz tick** (about 15 ms usable) | **~160** | **~240 to 270** |

**So at 60 ticks a second, without crowd movement, 500 isn't reachable on this machine.** With everything below added at 60 Hz, the estimate tops out at about 350 to 400. What stays on the main thread is moving every unit through `move_and_slide` and its abilities, every tick. Ways to close the gap, which can be combined:

| Lever | What it does | Guess |
|---|---|---|
| **A. A tick rate chosen per match, such as 30** (7) | Twice the time per tick at 30. Drawing stays smooth, because pawns are drawn between ticks already. Many large online games simulate at 20 to 30 a second | ~62 µs fits about 480 to 530 units at 30: about 500 on its own, with little margin |
| **B. Built-in abilities as data, in C++** | Walk, Sprint, Jump, Dash, MeleeAttack, Knockback and Death as a fast path, like the recorder; a designer's GDScript ability still works, on the main thread, and a test checks both paths agree | abilities ~13 → ~2: about 300 at 60 Hz, about 600 at 30 Hz |
| **C. A cheaper `move_and_slide`** | Fewer slide iterations and collision checks, measured first; no behaviour change allowed | perhaps −20% of ~22 |
| D. Per-pawn rates for distant units | A later round of optimisation (the owner's call, v0.4; 7.1) | depends on the map |
| E. Crowd movement | Not in tier 1 (the owner's call) | the largest, later |

**Claude's suggestion: A and B together** reach about 500 with a margin; C adds headroom. **A has a cost to weigh:**
- A possessed pawn answers input up to about 17 ms later on average, and hits are judged on a coarser clock.
- **Settings counted in ticks would change meaning** if nothing were done: MeleeAttack's 8-tick wind-up would become 0.27 s instead of 0.13 s. Section 7 keeps them meaning the same time.
- The network tests haven't been run at 30 yet.

Open question 7.

---

## 1. Where the time goes now

A fighting pawn on the server, microseconds per tick, from `pawn_stress` at 400 pawns on the owner's PC (pawn spec 12.1, 15.6), and the same times 1.6 for the target machine (section 0, a guess):

| Part | Owner's PC, µs | Target machine, µs (guess) | Runs on | Tier 1 answer |
|---|---|---|---|---|
| AI: sensing, decisions, behaviours | ~23 | ~37 | main thread; memory and sight in C++ | AI on workers (6) |
| Simulate: `move_and_slide`, gravity | ~14 | ~22 | main thread, engine C++ | crowd movement (8), simulation level of detail (7) |
| Simulate: abilities | ~8 | ~13 | main thread, GDScript | stays; crowd units use a small fixed set (8) |
| Other phases: inputs, snapshots | ~14 in `pawn_stress`, less on a real server | ~22 | main thread | per-client network work on workers (9) |
| Physics engine step | ~5 | ~8 | engine | fewer bodies with crowd movement (8) |
| Recording | ~5 | ~8 | main thread, C++ | stays |
| **Total** | **~69** | **~110** | | |
| **Fighting pawns per 60 Hz tick** | **~235** | **~145** | | |

**Standing pawns** already cost about 28 µs, mostly outside simulate, since they rest.

**Amdahl's law** (the gain is limited by what must stay on one thread) is the reason for the order below: threads only help once the work is plain data, and the biggest main-thread costs are the AI and `move_and_slide`.

**On 4 cores, cutting main-thread work matters more than spreading it.** With at most 3 workers, and fewer when the machine also renders, threads can take maybe two to three times the main thread's own share of work, not ten. So every step below is judged first by what it takes off the main thread.

---

## 2. The rules

These extend the per-tick contract (pawn spec 15.1).

1. **Server-centred.** Plain data and worker threads are for work the server (or an offline game) does: AI, AI movement, hits, snapshots. A client predicts only its own pawn or two, at full detail on real nodes, and draws the rest from snapshots. Its path doesn't change.
2. **Gather, compute, apply.**
   - *Gather*, on the main thread: copy what jobs need into the pawn table (3).
   - *Compute*, on any thread: each job reads only the frozen table and writes only its own pawns' result slots. No locks, no node access.
   - *Apply*, on the main thread: results go back to nodes in entity-id order.
3. **Results land on a fixed tick.** A job started on tick T is applied on tick T + its due delay (usually 1). If it isn't done in time, the main thread waits for it or finishes it itself. Results never depend on how fast a machine is, so tests and replays repeat exactly, and an overloaded machine slows down rather than doing something different.
4. **Built-ins fast, custom code slow, same answer.** Standard behaviours, considerations and movement run as data. A designer's GDScript (an overridden score, a custom ability) still works, on the main thread. Like `AIMemoryStore` and `TickStateRecorder`, a test compares the fast and slow paths and they must agree exactly.
5. **Graceful overload.** When there's more work than time, the scheduler defers what can wait (AI decisions, far-away pawns) by count, not by milliseconds, before it lets the tick run long.
6. **Measure every step.** Each step in section 10 says what it must show in `pawn_stress`, `ai_stress` or `net_stress` before the next starts.

---

## 3. The pawn table

One shared table of plain pawn data on the server, in C++ (`PawnTable`): **one array per field, one slot per pawn**, so slot 7 in every array is the same pawn.

- **Fields, first version:** entity id, team, position, velocity, yaw, grounded, Health, detectability, and flags (dead, resting, possessed, relevant to a player).
- **Slots:** an entity id to slot map. A despawned pawn's slot is filled by the last one, so the arrays stay packed, then the slots are put back into entity-id order once a tick, so jobs and results walk pawns in a fixed order.
- **Filled once a tick,** read from the pawns at the first use in a tick (`refresh(tick)`), before anything reads it. *(v0.5: this said "in the record phase", by the recorder's pass. Reading at the start of the tick instead means a pawn moved by code between ticks, a teleport or a test placing it, is seen at once, as the grid always saw it; reading in the record phase would show it a tick late. Tier 1's jobs gather at the start of a tick anyway.)*
- **Read-only for jobs.** Jobs read the copy from the end of the previous tick (rule 3 of pawn spec 15.1).
- **`AIPawnGrid`** is built from the table instead of from nodes.

### 3.1 Step 1, as built *(Claude 2026-11-09)*

- **`PawnTable`** (`native/src/pawn_table.*`): one array per field (position, velocity, yaw, team, grounded, detectability), slots kept sorted by key. `add(pawn, key)`, `remove(pawn)`, `refresh(tick)` (reads once a tick; freed pawns are dropped), `version()` for readers, and `get_keys()`, `get_slot()`, `get_row()` for GDScript tests and readouts.
- **Pawns join and leave it themselves,** in `Pawn._enter_tree` and `_exit_tree`, with their entity id as the key (`Pawn.get_table()`). Pawns no network session configured, as in most tests, get keys from `Pawn.TABLE_KEYS_WITHOUT_ID` (2^40) up, in the order they joined, after every networked pawn.
- **`AIPawnGrid`** now reads the table (`set_table`), rebuilding its cells when the table's version changes; `track` and `untrack` are gone, and `AISensingManager` makes the shared grid from the table. Equally distant pawns now come back in entity-id order; before, they came in hash order, which could differ between runs.
- **Test:** `pawn/tests/pawn_table_selftest`: slot order and keys, reading once a tick, leaving and coming back, and the grid against a brute-force search (1,920 queries, nearest first, ties by entity id, all equal).
- **Cost:** a refresh reads a pawn in about 0.3 µs on the owner's PC, against the step's budget of 1. `pawn_stress` at 400 fighting pawns: input and AI 9.05 ms, the same as before (9.06). Every other suite passes unchanged.

---

## 4. Jobs and the scheduler

The owner's design: the main thread runs ticks, and work that doesn't fit overflows to worker threads, with the scheduler learning how long each kind of task takes and spacing tasks so they finish in time. With the adjustments agreed in discussion:

- **Every job declares where it may run:** *main only* (touches nodes or GDScript) or *any thread* (plain data only). Only any-thread jobs ever leave the main thread.
- **A shared queue,** not tasks placed on particular threads. Idle workers take the next job ("work stealing"), which balances itself. Jobs are batches of pawn slots (say 32 to 64 pawns each), so there are enough to spread.
- **Cost estimates** per job kind: a running average in microseconds per pawn, kept by the scheduler. They decide what to defer when over budget (rule 5), and roughly how many batches to make.
- **Due ticks:** each job has a due tick (rule 3). The main thread checks completions at the start of the apply step; a late job is waited for or finished on the main thread, and counted, so overload shows in the numbers.
- **The main thread's budget:** milliseconds per tick for main-only work, measured from the machine (4.1). Main-only work beyond it is deferred by count where it can be: AI decisions wait their turn (a queue in pawn-id order), far-away pawns simulate less often (7).
- **Threads:** the existing `navcore` worker pool (`native/src/worker_pool.*`), grown to take a batch of jobs and wait for them. How many: 4.1.
- **Determinism:** the thread count never changes a result: jobs write only their own slots, and results are applied in entity-id order.

### 4.1 Sharing the work out by machine *(the owner's request, v0.2)*

The same game runs on 4 cores and on 24, as a dedicated server or as a player hosting while playing. So the scheduler sizes itself to the machine, at start and while running:

- **How many workers.** From `OS.get_processor_count()` (logical cores): that minus one for the main thread, minus one more when this machine also renders the game (a player hosting, or a client), at least 1, and capped by a setting. On the target machine that's 2 workers when hosting while playing, 3 on a dedicated server. On the owner's PC, 22.
- **The main thread's budget, measured.** The tick's length (16.7 ms at 60 Hz), minus what rendering and the physics engine are measured to take on this machine, minus a safety margin. A fast machine gets more room for main-only work; a slow one less. A setting can fix it instead.
- **Cost estimates, measured live.** Each job kind's running average, per pawn, on this machine (4). So a slow machine knows it's slow without being told, and the scheduler plans with real numbers.
- **What gives way first, in order,** when the measured work doesn't fit: far pawns simulate less often (7), then AI decisions wait their turn, by count, in pawn-id order (rule 5), then far pawns' AI thinks less often. Only after all of that does the tick run long, and the game slows down instead of freezing (pawn spec 12.1's overload notes).
- **Shown in a debug readout:** workers, budget, each job kind's cost, and what's being deferred, so a designer can see what a machine is doing.

**What this does and doesn't change:**
- **Timing adapts; results don't, except where the server decides on purpose.** The thread count and the speed of the machine never change a result (rules 2 and 3). What a slower server defers, such as a decision a few ticks later or a far pawn simulated less often, does change what happens, but only on the server, which is the authority. Clients still match the server exactly, because they receive its results.
- **Tests pin the settings** (worker count, budget, deferral off), so they repeat exactly on any machine.
- **Clients size themselves too,** for their own work: rendering, placing remote pawns, predicting their own pawn. They never defer anything the server needs.

---

## 5. Tidying the contract's exceptions

Before AI work moves to threads, the two exceptions in pawn spec 15.1 go:
- `AITargetSelector.force_target` (a taunt) writing into another pawn's AI at once becomes a queued request, applied in the input phase.
- Sensing reads other pawns through the pawn table (3) instead of the nodes.

---

## 6. The AI on worker threads

Today the AI is about a third of a fighting pawn's cost.

- **Sensing as a job:** candidates from the grid, then the sight check, writing into the pawn's memory slots.
  - **Line of sight in C++, against the terrain heightmap and props,** instead of physics rays, which can't safely run off the main thread.
    - The terrain is a heightmap already, and a ray against one is cheap.
    - **Props block sight** *(v0.3, the owner's call)*. Each prop that blocks sight gives the sight system simple shapes (boxes, spheres, capsules), kept in C++ in a grid like the pawn grid. By default they come from the prop's collision shapes on a "blocks sight" physics layer, so a designer only ticks a layer; a prop can also list its own shapes. A prop that moves updates its shapes when it moves, applied between ticks like everything else.
    - A ray first walks the heightmap, then tests the shapes in the grid cells it passes. A comparison test checks it agrees with physics rays on a map with props.
    - Collision shapes that aren't simple (a triangle mesh, say) are stood in for by their bounding box, with a warning, unless the prop lists its own shapes.
- **Thinking as data ("considerations"):** a behaviour's score as a list of inputs (distance to target, awareness, health, time in state...), each through a `Curve` and a weight, multiplied together. Computed in jobs.
  - This is how the AI spec already treats scores, written down as data instead of code. Jitter, persistence and interrupts stay as they are (pawn spec 10.7).
  - A behaviour that overrides `score()` in GDScript runs on the main thread, and a test checks both paths agree for the built-ins.
- **Behaviours' ticks** (Chase re-aiming, Attack pressing) stay main-thread GDScript for now: they run every 5 ticks and cost little.
- **Decisions apply one tick later** than today (due delay 1): about 17 ms more reaction time. *(v0.3: agreed by the owner.)*
- Guess: the main thread's AI cost per fighting pawn from about 23 µs to about 3 to 5 (gathering and applying).

---

## 7. The tick rate, chosen per match *(v0.4)*

**The owner's call:** for tier 1, the tick rate is decided before a match starts, so every machine is in step from the first tick. It doesn't change during the match.

- **Who decides:** the game, through the existing project setting (`project_base/network/tick_rate`), or a dedicated server at start-up. A server can pick from the machine it's on, measured as in 4.1: say 60 where the work fits, 30 where it doesn't. Clients learn the rate in the handshake and use it.
- **Settings counted in ticks keep ticks,** as the owner prefers for AI timings, at a **reference rate of 60**. Each one is converted once when the match starts: ticks used = round(setting × rate ÷ 60), at least 1 where the setting is above 0. So an 8-tick wind-up is 8 ticks at 60 and 4 at 30, the same 0.13 s either way, and a designer tunes in the same numbers whatever a game's rate.
  - There are 38 such settings today, across the AI, abilities, resting and the netcode. Each gets its conversion in the one place it's read, through one helper on `TickDriver`.
  - Rounding: a setting that doesn't divide evenly is up to half a tick off at 30 (8 ms). Settings that must stay exact can be chosen as even numbers.
- **Things sized in ticks become sized in time:** the rollback history (64 ticks at 60 is about 1 s, so 32 at 30), lag compensation's history, the snapshot interval, which already comes from the rate.
- **Ability durations and cooldowns** are already in seconds, converted to ticks, so they need nothing.
- **Tests:** the network tests and `pawn_stress` run at 30 as well as 60; a check that a sample of converted settings last the same time at both.

### 7.1 Later: rates that change during play

**Not tier 1** (the owner's call, v0.4). Kept here so tier 1 doesn't get in their way.

- **The whole game changing rate mid-match** needs every running timer and setting rescaled on the same tick on every machine, announced ahead, and a rollback history that can hold ticks of two lengths.
- **Per-pawn rates for distant units** (simulation level of detail): pawns far from every player simulate every 2nd or 4th tick with a longer step, and past a cutoff they pause, which `NetworkEntity.set_paused` and `AIActivationManager` already do. Safe for the netcode, because only the server simulates them.
- **Levels of abstraction** beyond that, such as resolving a distant fight by numbers instead of simulating it, depend on the game.

**They overlap where it counts.** Both rates that change and per-pawn rates need **timers that can advance by more than one tick at a time**: a pawn simulated every 2nd tick moves its timers on by 2, and a game switching from 60 to 30 rescales them. Tier 1's conversion at match start (7) is the first half of that, done once: every tick-counted setting already passes through one helper that knows the rate. So the later work changes how often that helper is used, not every system that uses it.

---

## 8. Crowd movement for AI units *(after tier 1)*

*(v0.3: the owner's call, "no crowds yet". Kept here as the plan for later; nothing in tier 1 depends on it.)*

This is the step that takes `move_and_slide` off the main thread for AI units, and the largest lever past 500.

- **AI units in big fights move as plain data:** steering along the nav mesh, separation from neighbours through the grid, and ground height from the terrain heightmap, in C++ jobs. No `CharacterBody3D` while in crowd mode.
- **Two ways to build it:**
  - **Detour's crowd module** (`DetourCrowd`, already in `native/thirdparty/recastnavigation`, not yet compiled): proven local steering and avoidance on the nav mesh, made for hundreds of agents. It isn't built to give identical results on two machines, which only matters if clients predicted crowd units. They don't (rule 1).
  - **Our own steering:** simpler, fully ours to make repeatable, more work. Flowfields fit here later, for many units heading to one place. The owner placed flowfields after t0.
- **Players and possessed units keep full pawns.** Possessing a crowd unit swaps it to a full pawn at the same position and velocity, and letting go swaps it back.
- **Abilities in crowd mode:** a small fixed set as data (walk, attack, knockback, death). Custom abilities need a full pawn. Open question 1.
- **Collisions with players:** crowd units treat players as agents to avoid. The player's body bumps into crowd units through a light physics shape each unit keeps, moved with it.
- **The network doesn't change:** crowd units still send position, velocity and yaw in snapshots.
- Guess: simulate for an AI unit from about 22 µs to 2 to 3 on the main thread (gather and apply), with the rest spread across workers.

---

## 9. Network work per client

- **Interest management** (relevancy): each client gets only the pawns near it, or that matter to it. That cuts bandwidth, about 0.9 KB/s per pawn per client today (netcode spec 14.1), and makes each client's snapshot its own job.
- **Per-client snapshots on workers:** gathering and encoding (`NetCodec`) per client, in parallel.
- **Delta compression** (sending only what changed) after that, from netcode spec step 4.
- **Clients:** placing remote pawns in one C++ batch call, like the recorder: about 8 µs to about 1 per remote pawn (guess).

---

## 10. Build order

Each step ends with tests passing on Windows and Linux, and the measurement it names.

| # | Step | Must show |
|---|---|---|
| 1 | **Pawn table**, `AIPawnGrid` built from it (3). **Built 2026-11-09 (3.1)** | Nothing behaves differently: every suite passes; `pawn_stress` costs no more than 1 µs per pawn extra. *Measured: 0.3 µs per pawn; every suite passes* |
| 2 | **Job system and scheduler** in `navcore`: batches, due ticks, cost estimates, the main thread's budget, late-job counting, sizing to the machine (4, 4.1). One job kind to start: the sight checks. `pawn_stress` and `net_stress` get the slower-CPU stretch and worker cap (section 0) | The same results with 0, 1, 2, 3 and N worker threads, compared exactly; `ai_stress` main-thread time down |
| 3 | **Contract exceptions tidied** (5) | `ai_stealth_selftest`, taunt tests unchanged |
| 4 | **Line of sight in C++, against the heightmap and props** (6) | Agrees with physics rays on a map with props, in a comparison test; sensing fully off the main thread |
| 5 | **Considerations as data** for the built-in behaviours (6) | Scores equal to the GDScript ones on recorded situations; decisions off the main thread; ~235 → ~350 fighting pawns (guess) |
| 6 | **Tick rate chosen per match** (7): the reference-rate conversion for the 38 tick settings, history sized in time, the rate in the handshake | Every suite and network test passes at 60 and at 30; converted settings last the same time at both |
| 7 | **Interest management and per-client snapshots on workers** (9) | Bandwidth per client and server snapshot time in `net_stress` |
| 8 | **Client batch placement** (9) | Client cost per remote pawn in `net_profile` |
| 9 | **The other levers for 500** chosen in open question 7 (0.1): built-in abilities as data, a cheaper `move_and_slide` | 500 fighting units on a 4-core dedicated server at the chosen rate, measured with the slower-CPU stretch and 3 workers (section 0) |
| — | After tier 1: crowd movement (8), rates that change during play and per-pawn rates (7.1) | — |

Steps 1 to 5 are mostly independent of the crowd decision (open question 1), so they can start as soon as this is agreed.

---

## 11. Open questions

| # | Question | Claude's suggestion |
|---|---|---|
| 1 | Should AI units in big fights drop full physics for crowd movement (8)? | **Settled 2026-11-09:** not yet. No crowd movement in tier 1 |
| 2 | Line of sight from the heightmap only, ignoring props? | **Settled 2026-11-09:** no, props block sight (6) |
| 3 | AI decisions one tick later than today (about 17 ms)? | **Settled 2026-11-09:** yes |
| 4 | The target? | **Settled 2026-11-09:** a dedicated server on the target machine (section 0), aiming at 500 fighting units. How: open question 7 |
| 5 | Detour's crowd module or our own steering for crowd movement (8)? | After tier 1, with crowd movement |
| 6 | The scheduler's main-thread budget: a fixed setting, or measured from the machine? | Measured, as in 4.1, with a setting to fix it. *(v0.2: the owner asked for sharing work out by machine.)* |
| 7 | Which levers reach 500 (0.1)? | *v0.4: the tick rate per match is in (7); per-pawn rates are later.* Built-in abilities as data in C++ too, and a cheaper `move_and_slide` for headroom. Steps 1 to 8 don't depend on the answer |
| 8 | Tick settings at a reference rate of 60, converted at match start (7)? | Yes: designers keep thinking in ticks, and the numbers mean the same time at any rate |
