<!-- Written by Claude (claude-opus-5-5), 2026-11-19: the state store's running changelog. Newest first. Add an entry with every
change; code comments say what the code does now, this says how it got here and why. -->

# State store changelog

The C++ `StateStore` (`native/src/state_store.*`) and its GDScript twin `StateStoreGD.gd`. Design: [STATE_STORE_SPEC.md](../../../docs/state_store/STATE_STORE_SPEC.md). Overview: [README.md](README.md).

## Refactor candidates

Code that works but doesn't yet fit the project's goals. Each is marked `REFACTOR:` in the code. Sizes are rough: S an hour or two, M a day, L more.

| What | Where | Why | Size |
|---|---|---|---|
| Typed columns instead of Variants | `Layout::cells` in `state_store.h`, `_Layout.cells` in the twin | Each cell is a Variant, so any value fits (today's state lists hold arrays and dictionaries). Worker jobs (sensing, snapshot encoding, replay packing) want plain typed lanes they can read without the engine. Comes with the first job that reads the store | M |

## 2026-11-23

- **Documentation pass:** `StateStoreGD`'s long member docs trimmed to the reference style; the README's status covers steps 1 to 5 (pushed columns, carried rows, writing through).
- **Determinism across platforms** (the owner's request; state store spec 13.11): Windows against Linux, the fingerprints split at tick 18 over a nearest-polygon tie that Detour settles in a platform-dependent order. Fixed in the nav library (native changelog: our own nearest-polygon lookup, then Recast and Detour sorting stably), after which a 603-pawn, 7200-tick match agrees on both platforms on every value.
- **Tools for comparing machines:** `run_determinism_check.py --compare A B` compares two fingerprint files made elsewhere, without running. New run options: `--terrain-seed=N` (another floor), `--nav-dump=TICK` (every nav triangle, link and tile state, bit for bit), `--paths-to=TICK` (every pawn's path state, and the nav server's path search log), and a fuller `--trace` (the move input, the path state and every AI decision; the static decision listener is cleared on exit, since left set it crashed Godot as it quit).
- **Under contention:** 4 copies of the check run at once on one machine, on the default floor and on another, each match the run made alone.
- **Playing from orders:** the check's `--record-orders` and `--replay-orders` (netcode spec 19.10): with the AI off and its recorded orders played back, up to 1000 pawns match the original on every value. The mass battle sample is now four factions spawning 40 m out, a quarter archers (`ranged_share`), with melee and archer scene variants; `net_cost_measure` prices snapshots, commands and orders.

## 2026-11-22

- **The determinism check traces one pawn:** `--trace=NAME --trace-from=T --trace-to=T` writes its unrounded position and velocity before the tick, after simulate and after the commit, beside the fingerprints (`PATH.trace`), to find which stage of a tick went apart.
- **The landing schedule** (state store spec 13.12, agreed with the owner: a fixed delay and a record): work done off the tick lands on a tick fixed when it's asked for. Terrain chunks (`ChunkStreamer`, `TerrainGenerator`) and nav tiles (`NavServer`, `TerrainNavFeeder`) do; `LandingLog` (new) records every landing, and the determinism check adds each tick's landings to its fingerprint. After it, the check's two cases (streaming at 300 m, nav at 40 m) agree over 4 runs of 1200 ticks.
- **The determinism check** (state store spec 13.11, the owner's request): `tools/determinism/run_determinism_check.py` and the test bed `samples/tests/determinism_check.tscn`. It plays the mass battle several times from the same start and compares the store after every tick (frame checksum, a hash per entity row and per column), naming the entities and columns at the first difference. First findings: terrain streaming and nav tiles land at timing-dependent ticks (both under time budgets).

## 2026-11-21

- **`find_long_moves(tick, dt, allowance, slack)`** (new, both twins): every entity with position and velocity columns whose move into that tick is longer than its velocity explains, with the move's length and speed, and how many were compared. The MoveSanityCheck's first pass.

- **`mark_changed` drops values written through** for that entity earlier in the tick (both twins), so the commit reads its nodes. Before, a teleport after the crowd mover wrote a pawn's move was recorded at the crowd's position.

## 2026-11-20

- **`write_through(handles, column, values, tick)`** (new, both twins): one column for many entities, into their nodes and the row the commit for that tick records, which then skips reading them. Measured with the crowd mover: the commit is no faster, since a pawn's cost is its 42 ability, stat and effect columns (state store spec 13.8).

- **`get_vector3s(handles, column, tick)`** (new, both twins): one Vector3 column, by name, for a list of entities in one call; NaN x where there's no row, no such column, or not a Vector3. For readers that want a whole crowd's positions, such as the crowd mover (state store spec 13.7).

## 2026-11-19

- **Carrying rows forward** (`set_carry_forward`, `mark_changed`): an entity nothing marked since the last commit gets its previous row copied, reading no node; a rollback's re-run, a load and a missing previous row always read. `get_stats()` counts `rows_read` and `rows_carried`.
- **Pushed columns may be bound to a node**: read once at binding, written back by `load_row`, checked by `verify_nodes` (so a missed push shows), never read by a commit.
- **The store, step 1 of the refactor** (state store spec 4 to 9): layouts with gathered and pushed columns, slots that never move with generational handles and reuse once the history has moved past, a rotating buffer of `depth` frames, the commit (read, round, write back, copy) in one pass, partial commits for a rollback's re-run, `load_row` back into the nodes, `get_column`, frame checksums and the tripwire (`verify_nodes`). The C++ class replaces `TickStateRecorder`, whose reading and rounding it took over. The GDScript twin gives the same handles, rows and checksums (`state_store_selftest`).
