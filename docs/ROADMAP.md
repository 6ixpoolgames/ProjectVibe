# Roadmap

*Written by Claude (claude-opus-5-5), 2026-11-16, from the owner's decisions. Kept up to date as plans change; each item's detail lives in its own spec.*

## Now

**Diagnostics v0** *(the owner's call, 2026-11-16: "make a v0 diagnostic suite next", before the roadmap below, so that work is measured as it goes)*. **Built** (docs/diagnostics/DIAGNOSTICS_SPEC.md), with replay safeguards (replay spec 3.1). Next: the owner's run at their workstation, with the editor and 3 instances, to read the session logs. It comes first because the mass battle's frame rate in play (under 30 fps from the editor, with 3 instances) couldn't be reproduced outside the editor, and a proper set of tools is needed to see where the time goes wherever the game runs.

Owner's decisions, 2026-11-16:
- **Diagnostics hook into replay v0.** The replay's recorder and writer thread also store the diagnostics, so one recording holds the game and its performance, side by side.
- **Recordings and session logs are always on** in debug builds.
- **One key per panel,** for readability, in a smaller font that doesn't overlap.
- **Switched on through a project setting** with a release override, so release builds leave diagnostics out.
- **The performance baseline check runs on request.** Claude suggests a run when one is warranted.

## Next: the agreed roadmap, in order

1. **Abilities made of steps, and hits through the AbilityManager** (pawn spec 13 #3, and the 2026-11-15 discussions):
   - Unreal's stepwise ability-task pattern: each ability tracks its current step, with cancel windows per step
   - a TurnToFace step that uses a TurnSpeed stat, with a default in each ability
   - combo follow-ups gated by a tag the basic attack's timed effect switches on
   - a slightly longer basic attack cooldown
   - hit interceptors replacing the parry and dash special cases (pawn spec 14, "Shortcuts to redo")
2. **Slimming the pawn** (M1 to M6). The pawn keeps the body and its tick order, its part references and its general flags:
   - **M1** *(built 2026-11-16)*: a TeamRegistry module; the sleeping and frozen renames; the AI's ordered step moved into AIContextComponent. Each part cleaning up on `died` itself moved to M3, which moves the signal
   - **M2** *(built 2026-11-16)*: a `keeps_world_loaded` flag on the pawn, with distances from the GameMode (`PawnDefaultsRes`), and the chunk streamer, nav feeder and replay reading pawns through the source contract
   - **M3** *(built 2026-11-16)*: hits, death and their signals on the AbilityManager, each part cleaning up on `died` itself (pawn spec 8.16). Parry and dash as hit interceptors stay with the ability-steps work
   - **M4** *(built 2026-11-16)*: input and possession on the ControllerManager, which stays optional and is added by default; abilities read input through helpers (pawn spec 8.17)
   - **M5** *(built 2026-11-16)*: one camera per player, on the PlayerController, attaching to a CameraMount on the pawn (pawn spec 8.18)
   - **M6:** a VisualSmoother (folded into animation v0's visuals manager); detectability as a stat, mirrored into the pawn table (C++)
   - **Optional C++ bundle with M6:** stat columns in the pawn table, the per-pawn tick step from distance in whole chunks, and replay motion packing in C++
   - **Also in the C++ bundle** *(the owner's call, 2026-11-16: everything that needs a rebuild goes in one batch)*:
     - updating godot-cpp from the 4.4 bindings to 4.7 (10.0.0-stable, already fetched; `api_version=4.7`, then `compatibility_minimum = "4.7"` in `bin/navcore.gdextension`)
     - the tile commit fix (navigation and terrain track below)
     - a partial flag for paths found without links: `find_path_now` gives only points, so `NavigationManager.is_partial()` is false with `use_links` off. One method giving `{points, link_ids, partial}` either way.
     - *(Claude 2026-11-16, the owner's call)* the delta snapshots' change check in C++: `NetworkSession._delta_entity_bytes` compares each entity's state list with its baseline and builds the masks in GDScript, which raised the host's snapshot sending from 1.9 to 2.3 ms a tick at 154 pawns (netcode spec 11.4.1). A `NetCodec` method taking both lists and returning the encoded delta, with `net_codec_selftest` comparing it to the GDScript one
     - *(Claude 2026-11-16, the owner's call in the code audit: walls belong in navigation)* the crowd mover's wall check against the navmesh, Detour's `moveAlongSurface`, so nav walking stays on the navmesh like Unreal's NavWalking and works for any pawn, shaped or not (today: a sweep of its collision shape, and a pawn with none moves by physics)
     - *(Claude 2026-11-16, the owner's call)* the crowd mover's batch in C++ (pawn spec 8.22): `CrowdMover._move_batch` takes plain lists already, so a C++ version takes the same, with its rays against `SightGeometry`'s copy of the ground instead of the physics world, on the job scheduler's worker threads. The GDScript batch costs about 10 microseconds a pawn (0.9 ms of 1.35 at 130 pawns is GDScript)
     - *(Claude 2026-11-16)* swing hit checks through the pawn grid (`AIPawnGrid`) in C++ instead of physics sphere queries
     - *(Claude 2026-11-17, from the wider code audit; the owner kept C++ out of that round)* pawn paths through the budgeted queue across links (`PathQueue` with `use_links`), so a mass repath is spread over ticks instead of all on the main thread at once; bounds and null checks on `AIMemoryStore`'s `*_at` functions, `NavServer` with no tier radii and `TileManager`'s dirty rectangles; fewer engine calls per sensed candidate after the sensing job; one `state_encoding.h` for the encoding rules the codec and the recorder each copy; one connection per shape in `SightGeometry` (Godot counts a function as connected whatever is bound to it, checked in 4.7, so a second body sharing a shape isn't watched today); the sensing job's mutation guard on the table, grid and geometry themselves; `SightGeometry.sync` skipping static bodies; tile builds editing span columns in place; a terrain edit dirtying only the nav tiles it touches
     - rebuild on Windows and Linux, then the nav, codec and tick_state tests
3. **Tick driver update** (variable tick rate):
   - fine ticks counting at 120, with 60 by default *(left for later, with networking T1.1: not needed for dropping to 30)*
   - per-pawn steps of 2 or 4 by distance, in multiples of the chunk size *(built 2026-11-16, pawn spec 8.21: the AIActivationManager picks them)*
   - the whole game dropping to 30 under load, announced ahead *(built 2026-11-16 as the load ladder: every AI pawn at most every 2nd or 4th tick; players' pawns every tick, so no announcement is needed)*
   - *(Done 2026-11-16, after the owner's 6 fps playtest.)* Catch-up is capped at 3 ticks a frame, and Godot's own physics-step limit follows TickDriver's, which was the real cap (8) before, with nothing dropped. Dropped time shows in diagnostics.
   - timers that advance by a step *(built 2026-11-16: `Pawn.ticks_elapsed`, and `fired_since_last_run` for the AI's schedules)*
   - **A batched mover** *(the owner's call, 2026-11-16)*. Every pawn runs its abilities first, then one central step moves them all, still with Godot's move_and_slide. The gains:
     - every swing and query sees the same moment
     - one place to swap in the C++ mover from the wishlist
     - one place for per-pawn steps and skipping sleeping pawns
     - one place to measure
   - **The fallback:** the path is chosen once, when a pawn starts. Without TickDriver and the mover, the pawn moves itself, as today. A pawn in the batch that reaches the end of a tick unmoved moves itself and warns once (session log, F8), so a break is never silent.
4. **Performance.** Start from the findings of 2026-11-16 (the owner's memory notes and the replay spec's measurements):
   - hosting costs about 1.4 ms a tick with no clients connected
   - the tick spikes at the first clash
   - a late frame triggers catch-up ticks that make the next frame late too
   - irregular stalls in "rest" (drawing, waiting for the screen, deferred frees), where the frame's other parts are normal
   - **Recording on worker threads first** *(the owner's call, 2026-11-16)*: replay packing, snapshot encoding and the rollback record, from the pawn table, sent off without waiting for a result. It's the easiest fit for workers.
   - **More work on worker threads** *(the owner's question, 2026-11-16)*. Today only nav (tile building and path searches), AI sensing (search and visibility) and replay writing run off the main thread. At 153 pawns on the main thread:
     - `move_and_slide`: about 3.6 ms a frame. It can't run on workers as it is; it would need a C++ mover for AI pawns.
     - the AI's decisions and behaviours: about 1 ms. This is scaling step 5, set aside 2026-11-09.
     - the per-frame visuals: about 1.9 ms. Animation v0's single loop and level of detail address these, rather than workers.
     - recording and snapshots: about 1–2 ms. Encoding could move to workers, from the pawn table.
5. **Docs, class by class,** once the code has stopped moving.
6. **Animation v0 and the design studio:**
   - one visuals manager instead of three scripts per pawn
   - visuals driven by ability events and steps
   - level of detail and other performance settings hooked in here
   - cheaper drawing
   - waddle and held-item profiles as data
   - built to accept other ways of animating later: keyframe tools, IK, data-driven animation, particles and other effects
7. **Effects handler v0.**
8. **UI v0** *(the owner's call, 2026-11-16)*: readable on-screen text and panels, without the overlaps and overruns of today's debug overlays.

## Done recently

- Pawn spec 8.15 (`65792c8`): parry, heroes, Go To Point, the mass battle, and the fix for a hero falling through unloaded ground.
- Replay v0 (`60d6bc9`): recorder, reader and viewer, with motion version 2 at 2.7 MB a minute for 153 pawns.

## Networking track *(the networking assessment, 2026-11-16; the owner adopted it as the networking sub-roadmap, without reordering the plan above)*

- **T1.0** *(N1 to N3 built 2026-11-16)*:
  - **N1:** no snapshot is gathered or encoded when no client can receive it. This was the 1.4 ms a tick a host spent alone.
  - **N2:** input packets are validated (a count of 0, an impossible tick, a wrong field count) before their timing counts.
  - **N3:** entities with only sync properties replicate.
  - **N4, minimal** *(built 2026-11-16)*: a snapshot list of the wrong size for an entity is refused, counted (`stats.schema_mismatches`) and warned about once per entity type, rather than read as empty (`NetworkSession._snapshot_lists_fit`, `TickStateComponent.get_list_sizes`).
  - **Still to do:** the rest of N4 (an explicit effective schema, agreed in the handshake) and diagnostics for networking.
- **T1.1:** the time contract, designed with the tick driver update:
  - the 120-unit fine clock, with snapshot IDs separate from simulation time
  - step schedules decided by the server and announced ahead
  - each entity's state time, and presses kept within slower steps
- **T1.2:** capturing an unchanging copy of state, then encoding it on workers, with an overload rule for each consumer. This is the performance phase's "recording on workers first".
- **T1.3:** deltas against acknowledged baselines, with full-state recovery (netcode v1). *(Claude 2026-11-16: built in GDScript, with snapshots cut into parts under ENet's packet size and cheaper placing of remote pawns, after the networked mass battle lagged and dropped its client: netcode spec 11.4.1. Acknowledgements from a client that controls nothing: built the same day, an `ACK` packet. Still to do: the change check in C++, in the C++ bundle.)*
- **T1.4:** input batching, and making lifecycle, teleport and late join wait on the world state they need.
- **T1.5:** a soak test and validation across machines.
- **Later, if it's needed:** relevance and priority (netcode v2).

## Navigation and terrain track *(the navigation and terrain assessment, 2026-11-16; adopted by the owner. Each claim was checked against the code and confirmed)*

- **Small fixes** *(built 2026-11-16)*:
  - **Path states** instead of a silent straight line: `NavigationManager.get_path_state()` is NONE, FOLLOWING, PENDING (nav still being built and none under the pawn yet; it retries every `pending_retry_ticks` and gives up after `pending_give_up_ticks`), ARRIVED or UNREACHABLE, and `is_partial()` says a path ends at the closest reachable point. The straight line is a choice, `straight_line_without_nav`, on by default. Controllers follow `is_under_way()`. The partial flag for paths without links waits for the C++ bundle.
  - **A generator version in the terrain's compatibility hash.** `TerrainGenerator.generator_version`, in `ground_settings_hash()`: raise it when a subclass's `_shape_height` changes the ground.
- **With the C++ bundle (M6):** fix `TileManager::commit_finished` clearing a tile's in-flight marker before its version check. A stale result can clear a recreated tile's newer build, so the tile gets built twice. Add a regression test.
- **With the tick driver update:**
  - link completion that checks height, not just horizontal distance (corner checks drop y)
  - grounded or airborne state where it matters
  - link timeouts in simulation time rather than a count of calls at the engine's physics rate
- **Performance phase:** queued path requests.
  - **Today:** every `move_to` searches synchronously (`find_path_now…`), so a mass re-plan bunches into one tick. That likely explains much of the 5–7 ms outside the ticks after the mass battle's first clash.
  - **First:** time it (a `nav.find_path` scope).
  - **Then, on the budgeted queue:** one request per pawn, newer requests replacing older ones, and request IDs so late results can't overwrite a newer goal.
- **T1 terrain, when a game edits terrain heavily:**
  - builds that know which terrain revision they started from, instead of finishing every half-built chunk before an edit
  - collision published at a defined point in the tick
  - paths re-planned after edits, with a watchdog for progress
- **Later:** checkpoints of the edit log per chunk, catch-up for late joiners in bounded batches, and shared or hierarchical routes, where profiling justifies them. Replacing Recast/Detour, flow fields and threaded pawn movement are not planned.

## Wishlist

- **A C++ mover replacing move_and_slide** *(the owner asked 2026-11-16, then put it here: a bigger job than expected, with more knock-on effects than the rest of the performance work)*. A batched, deterministic collide-and-slide:
  - terrain on a fast height-and-slope path
  - swept spheres against static geometry shared with SightGeometry
  - soft separation between pawns
  - run once per tick after every pawn's abilities, from the pawn table, on workers, with a GDScript fallback
  
  It would save about 3.6 ms of a 9.6 ms tick at 153 pawns. Roughly 2 to 3 weeks of work. Movement would feel slightly different, and Godot's rigid bodies wouldn't block pawns unless they're fed in.

## Open, older items

- The tuning panel
- A networked test of combos and over-time effects
- Delta compression for snapshots (netcode v1)
- The deferred effect items
- The Tag Picker UI, not yet checked in the editor
- Updating godot-cpp from the 4.4 bindings to 4.7: moved into the C++ bundle with M6 (2026-11-16)
- Deterministic physics: deferred until a game truly depends on physics; replays use keyframe correction
