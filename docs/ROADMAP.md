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
   - **M1:** each part cleans up on `died` itself; a TeamRegistry module; the sleeping and frozen renames; the AI's ordered step moved into AIContextComponent
   - **M2:** a `keeps_world_loaded` flag on the pawn, with distances from the GameMode, and the chunk streamer reading pawns through a small contract
   - **M3:** hits and gameplay signals on the AbilityManager
   - **M4:** input and possession on the ControllerManager, which stays optional and is added by default; abilities read input through helpers
   - **M5:** one camera per player, on the PlayerController, attaching to a CameraMount on the pawn
   - **M6:** a VisualSmoother (folded into animation v0's visuals manager); detectability as a stat, mirrored into the pawn table (C++)
   - **Optional C++ bundle with M6:** stat columns in the pawn table, the per-pawn tick step from distance in whole chunks, and replay motion packing in C++
3. **Tick driver update** (variable tick rate):
   - fine ticks counting at 120, with 60 by default
   - per-pawn steps of 2 or 4 by distance, in multiples of the chunk size
   - the whole game dropping to 30 under load, announced ahead
   - timers that advance by a step
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

## Open, older items

- The tuning panel
- A networked test of combos and over-time effects
- Delta compression for snapshots (netcode v1)
- The deferred effect items
- The Tag Picker UI, not yet checked in the editor
- Updating godot-cpp from the 4.4 bindings to 4.7
- Deterministic physics: deferred until a game truly depends on physics; replays use keyframe correction
