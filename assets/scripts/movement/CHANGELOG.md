<!-- Written by Claude (claude-opus-5-5), 2026-11-17: the movement system's running changelog. History leaves the code comments and lives
here, next to the code. Newest first. -->

# Movement changelog

Movement is this folder: `CrowdMover`, a GameMode module, and its C++ batch `CrowdBatch` (`native/src/crowd_batch.h`). The pawn's own move by physics is in `pawn/Pawn.gd`. Design: [docs/pawn/PAWN_SPEC.md](../../../docs/pawn/PAWN_SPEC.md) section 8.22. Overview: [README.md](README.md).

## Refactor candidates

The GDScript batch (`_move_batch`) repeats what `CrowdBatch` does on purpose, as the fallback where the C++ library isn't loaded; the twins' refactor row is in [native/CHANGELOG.md](../../../native/CHANGELOG.md).

| What | Where | Why | Size |
|---|---|---|---|
| The nav tier on the body | `CrowdMover._move_batch_cpp` | The tier comes from the path the controller in charge follows (`PathFollower.nav_tier`), so a pawn with no path gets tier 0; a tier is the body's, by its radius. Fine while t0 builds only tier 0 | S |

## 2026-11-25

- CrowdMover reads the nav tier from the follower's settings (`follower.settings.nav_tier`).

- **Links and nav tier from the path in charge** (pawn spec 16.10 step 5c): CrowdMover asks `pawn.controller_manager.get_path_follower()` whether a pawn is crossing a link, and for its nav tier, now that the pawn has no `NavigationManager`. Tagged `REFACTOR:`: the tier belongs to the body.


## 2026-11-23

- **`CrowdMover`'s early return** (nothing to move) now clears the moved-this-tick list and closes its `movement.crowd_gather` and `movement.crowd` timing scopes, so a quiet tick doesn't leave last tick's pawns marked or a scope open.

## 2026-11-21

- **Calls no pawn back after a crowd move**: the written pawns' Visuals are told in one `VisualPlacer.note_runs` call (each member's slot is kept with its other numbers), and their input bookkeeping happens in their own simulate. Finishing went from 0.36 to 0.22 ms a tick, the crowd from 0.85 to 0.70, at 300 pawns (state store spec 13.9).

## 2026-11-20

- **Writes its moved pawns through the state store** (`write_moves_through`, on): position, velocity and grounded in three `StateStore.write_through` calls instead of one `Pawn.finish_move` each; the pawn only ends its run (`Pawn.finish_written_move`). Finishing went from 0.43 to 0.34 ms a tick at 300 pawns (state store spec 13.8).
- **`note_moved_by_physics` is now `note_moved`**: `Pawn.teleport` calls it too.

- **Reads the other pawns from the state store** (state store spec 13.7): the pawns it keeps clear of stand where the store's last frame has them, in one `get_vector3s` call, instead of a read of each node. The few that moved by physics this tick tell it (`note_moved`, from `Pawn._move_with_physics`) and are read from their nodes, since the store has them a tick behind. A pawn moved by code since the last commit counts at its old place for one tick, which collision corrects (the owner's call: accept it rather than build for it).
- **Members** (`add_pawn`, `remove_pawn`, `refresh_pawn`): every pawn joins as it enters the tree and leaves as it leaves, with its width, slope and shape found once, so neither the moving pawns nor the others are asked each tick. It no longer looks through the pawns' group. At 300 pawns marching, against step 3 run back to back: the crowd mover 1.07 to 0.87 ms a tick (gathering the moving pawns 0.18 to 0.11, the others 0.24 to 0.12).

## 2026-11-19

- **Finer timings** (diagnostics): `movement.crowd_gather` (reading the moving pawns), `movement.crowd_others` (their nav tiers and every other pawn) and `movement.crowd_finish` (calling each pawn back). At 300 pawns, of 1.1 ms a tick: gathering 0.18, the others 0.25, finishing 0.45, the C++ batch and queries about 0.25 (state store spec 13.6).

- **The crowd mover is the pawn's `mover`** (state store spec 12.8): `try_take_move` is now `take_move`, and it calls the pawn's `finish_move` and `move_by_physics_now`. It adopts the pawns already in the tree when it's added and lets them go when removed; the PawnInitializer gives it new ones.

## 2026-11-18

- **Comments rewritten to the reference style** (the documentation pass): moved to the README's new "How it works" section: the batch's steps, separation, the C++ and physics wall and ground checks and who `CrowdMover` moves. "The owner's call" wording removed; `_move_batch` now says it is a twin of the C++ `CrowdBatch`. No stale comments found.

## 2026-11-17

- **The batch in C++** (the C++ bundle stage 3): `CrowdBatch` on the job scheduler's worker threads (`use_cpp_batch`). Walls come from the nav mesh (the owner's call, "walls belong in navigation"): a pawn on it walks along it with Detour's moveAlongSurface (NavWalking) and slides along its edge, with the ground from `SightGeometry`. Pawns it can't walk that way are handed back for the physics checks, now in `_walls_and_ground`, shared by both batches.
- **Crossing a link moves by physics**: a pawn crossing a nav link goes to the batch with tier -1, so a jump or a drop isn't stopped at the mesh's edge.
- **Comments cleaned up** for the documentation pass: dated notes moved here, doc comments in Godot's markup. The description no longer calls the nav mesh wall check "long-term": it's built.

## 2026-11-16

- **`CrowdMover`** (pawn spec 8.22, the owner's call after the mass battle showed move_and_slide, about 24 microseconds a pawn, as one of a tick's biggest costs): AI pawns walking on the ground hand their move over, and it moves them all at once with separation instead of colliding, then finishes their ticks.
- **Walls by collision** (the owner's call, rather than a wall ray): the pawn's own shape swept along the move, lifted by `max_step`, then a ray down for the ground. A wall, no ground, too steep or no shape hands the pawn back to physics in the same tick.
- **The audit:** the rule for who it moves moved here from the pawn (`try_take_move`); `blocked_last_tick` renamed `fallbacks_last_tick`; all pawns found through `Pawn.GROUP`.
