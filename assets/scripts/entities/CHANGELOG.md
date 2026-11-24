<!-- Written by Claude (claude-opus-5-5), 2026-11-24: the entities system's running changelog. Newest first. Add an entry with every
change; code comments say what the code does now, this says how it got here and why. -->

# Entities changelog

This folder holds what every entity shares (pawn spec 16.9). Overview: [README.md](README.md).

## Refactor candidates

| What | Where | Why | Size |
|---|---|---|---|

## 2026-11-24

- **`EntityNumber`** (new, the pawn redesign's build step 1, foundations (pawn spec 16.10)): one entity number. It replaces `AIContextComponent.pawn_number` and `number_of`, `HitInfo.key_of`, the abilities' hit-order key and the pawn's stagger, which each worked it out their own way (a name hash, an instance id). Offline pawns now hash their path, not their name, so two pawns with one name under different parents no longer share a number.
