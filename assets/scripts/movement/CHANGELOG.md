<!-- Written by Claude (claude-opus-5-5), 2026-11-17: the movement system's running changelog. History leaves the code comments and lives
here, next to the code. Newest first. -->

# Movement changelog

Movement is this folder: `CrowdMover`, a GameMode module, and its C++ batch `CrowdBatch` (`native/src/crowd_batch.h`). The pawn's own move by physics is in `pawn/Pawn.gd`. Design: [docs/pawn/PAWN_SPEC.md](../../../docs/pawn/PAWN_SPEC.md) section 8.22. Overview: [README.md](README.md).

## Refactor candidates

None found in the documentation pass. The GDScript batch (`_move_batch`) repeats what `CrowdBatch` does on purpose, as the fallback where the C++ library isn't loaded.

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
