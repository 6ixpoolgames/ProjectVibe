<!-- Written by Claude (claude-opus-5-5), 2026-11-19: the state store's overview, beside its code. -->

# State store

The central record of play: every gameplay entity's state at the end of every tick, in plain rows, with a history of recent ticks. Rollback, snapshots and corrections read it; replay, lag compensation, AI sensing and diagnostics move onto it in later steps of the refactor.

**Status:** step 1 of the refactor (the store and the tick driver's commit), on the `refactor/tick-core` branch. Today's `TickStateComponent` feeds it; the systems that keep their own copies today fold in later (state store spec 12.1, `docs/ARCHITECTURE.md`).

| File | What it's for |
|---|---|
| [README.md](README.md) | This overview |
| [REFERENCE.md](REFERENCE.md) | Every class, setting and function, generated from the code's doc comments (`python tools/docs/make_reference.py state_store`) |
| [CHANGELOG.md](CHANGELOG.md) | What changed and why, newest first, and the refactor candidates |
| [STATE_STORE_SPEC.md](../../../docs/state_store/STATE_STORE_SPEC.md) | The design |
| `native/src/state_store.h` | The C++ store, the main path |
| `StateStoreGD.gd` | Its GDScript twin: the same calls and the same results |

## How it fits

```
 tick T:  before_tick  input  capture  simulate  after_simulate  record  COMMIT  after_tick
                                                                           │
          TickDriver.store.commit(T): one pass over every active entity ───┘
            bound:    read each gathered column from its node, round it, write back what rounding changed, copy into frame T
            pushed:   the value its holder last pushed
            unbound:  handed back to its owner (TickStateComponent._store_gather), which writes the row itself
```

- **`TickDriver.store`** is the one store. It's the C++ `StateStore` when the library is there, else `StateStoreGD` (`-- --gdscript-store` forces the twin). `TickDriver.history_depth` (64) is how many frames it keeps.
- **Layouts.** Entities with the same columns share a table (an archetype). A `TickStateComponent` makes one layout per state list, so every goblin with the same parts shares one.
- **Slots and handles.** A slot never moves. A freed slot waits until the history has moved past its old occupant, then comes back with a new generation. A handle is `(generation << 32) | (layout << 20) | slot`, so a stale handle matches nothing.
- **Gathered and pushed columns.** Gathered columns are read from nodes at every commit. Pushed columns hold what a holder last pushed (`push(handle, column, value)`). Today every column a `TickStateComponent` lists is gathered; holders that push come with the later steps.
- **Binding.** `bind(handle, nodes, properties, encodings, round)` gives the store one node, one property path and one settled encoding per gathered column. A layout column declared `auto` takes each entity's encoding from its binding. Until an entity is bound (an entry's node is missing, or an `auto` encoding isn't settled yet), and whenever a bound node is freed, the store hands it to its owner each commit.
- **Rollback.** The driver loads each predicted entity's row (`load_row`, which writes the nodes), re-runs the ticks, and rewrites their rows with `commit_entities`.
- **The tripwire.** `TickDriver.verify_store_each_tick` checks, at the start of each tick, that every bound entity's nodes still hold what the last commit recorded. A mismatch is a write that went around the store (state store spec 4). Off by default.
- **Checksums.** `frame_checksum(tick)` hashes every row held for a tick; the C++ store and the twin give the same number.

## Using it

```gdscript
var store: Object = TickDriver.store
var layout: int = store.define_layout(PackedStringArray(["position", "target"]), [&"vector3_mm", &"raw"], PackedByteArray([0, 1]))
var handle: int = store.add_entity(layout, self)
store.bind(handle, [body, null], [^"position", ^""], [&"vector3_mm", &""], true)
store.push(handle, 1, target_id)          # recorded every commit until the next push
var row: Array = store.get_row(handle, TickDriver.tick)
```

## Tests

`state_store/tests/state_store_selftest`: layouts, handles and slot reuse, the commit with its rounding, history depth, pushed columns, partial commits, loading rows back, the tripwire, and the C++ store against the twin, row by row and checksum by checksum. `netcode/tests/tick_state_selftest` covers rollback through the store.
