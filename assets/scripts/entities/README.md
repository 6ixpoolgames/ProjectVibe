<!-- Written by Claude (claude-opus-5-5), 2026-11-24: the entities system's overview. -->

# Entities

What every entity shares, whatever it is (pawn spec 16.9).

**Status:** built, tier 0 (pawn redesign step 1): the entity number. Next: the entity registry and the entity table (step 9).

- **`EntityNumber`**: one number for every entity, the same on every machine and in every replay. Its network entity id when it has one, else a hash of its path in the scene tree (a level's own pawns, offline). `Pawn.entity_number()` keeps a pawn's own; `EntityNumber.of(node)` works it out for anything, -1 (`EntityNumber.NONE`) for none.

## How to use it

**Name an entity across machines.** `pawn.entity_number()`, or `EntityNumber.of(thing)`. Use it for anything another machine or a replay must agree on: random rolls (`DeterministicRandom`), stagger, hit lists, hit order, ties. Instance ids differ between runs, so keep them for bookkeeping that stays on one machine.

## How it works

- A path hash is from 0 to 2^31 - 1, and network ids count up from 0, so the two rarely meet; two pawns in one scene never share a path, as they can share a name.
- A pawn's path hash is kept until it enters the tree again. A pawn that gains a network id later (spawned and then registered) switches to it.
