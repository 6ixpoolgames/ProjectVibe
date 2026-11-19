<!-- Written by Claude (claude-opus-5-5), 2026-11-19: the state store's running changelog. Newest first. Add an entry with every
change; code comments say what the code does now, this says how it got here and why. -->

# State store changelog

The C++ `StateStore` (`native/src/state_store.*`) and its GDScript twin `StateStoreGD.gd`. Design: [STATE_STORE_SPEC.md](../../../docs/state_store/STATE_STORE_SPEC.md). Overview: [README.md](README.md).

## Refactor candidates

Code that works but doesn't yet fit the project's goals. Each is marked `REFACTOR:` in the code. Sizes are rough: S an hour or two, M a day, L more.

| What | Where | Why | Size |
|---|---|---|---|
| Typed columns instead of Variants | `Layout::cells` in `state_store.h`, `_Layout.cells` in the twin | Each cell is a Variant, so any value fits (today's state lists hold arrays and dictionaries). Worker jobs (sensing, snapshot encoding, replay packing) want plain typed lanes they can read without the engine. Comes with the first job that reads the store | M |

## 2026-11-19

- **Carrying rows forward** (`set_carry_forward`, `mark_changed`): an entity nothing marked since the last commit gets its previous row copied, reading no node; a rollback's re-run, a load and a missing previous row always read. `get_stats()` counts `rows_read` and `rows_carried`.
- **Pushed columns may be bound to a node**: read once at binding, written back by `load_row`, checked by `verify_nodes` (so a missed push shows), never read by a commit.
- **The store, step 1 of the refactor** (state store spec 4 to 9): layouts with gathered and pushed columns, slots that never move with generational handles and reuse once the history has moved past, a rotating buffer of `depth` frames, the commit (read, round, write back, copy) in one pass, partial commits for a rollback's re-run, `load_row` back into the nodes, `get_column`, frame checksums and the tripwire (`verify_nodes`). The C++ class replaces `TickStateRecorder`, whose reading and rounding it took over. The GDScript twin gives the same handles, rows and checksums (`state_store_selftest`).
