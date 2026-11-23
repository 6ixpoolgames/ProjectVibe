<!-- Written by Claude (claude-opus-5-5), 2026-11-17: the navigation system's overview, beside its code. -->

# Navigation

How pawns find their way: a nav mesh built from the level while it streams in, paths across it (jumps and drops included), and markers that tell nav and AI what a spot means.

**Status:** built, tier 0. Not yet: nav tiers for bigger pawns, repathing when tiles change, the area and obstacle modules, and domains (air, water).

| File | What it's for |
|---|---|
| [README.md](README.md) | This overview: what's here and how to use it |
| [REFERENCE.md](REFERENCE.md) | Every class, setting and function, generated from the code's doc comments (`python tools/docs/make_reference.py navigation`) |
| [CHANGELOG.md](CHANGELOG.md) | What changed and why, newest first, and the refactor candidates |
| [NAV_SPEC.md](../../../docs/navigation/NAV_SPEC.md) | The full design, including what's planned but not built |

## The pieces

```
 the level                         the nav library (C++)                  the pawn
 ─────────                         ─────────────────────                  ────────
 TerrainGenerator ─► TerrainNavFeeder ─┐
 StaticBody3D ─────► BodyNavFeeder ────┼─► NavServer: tiles, nav mesh ◄── NavigationManager ◄── a controller
 NavMarkerNode ──► NavMarkerManager ───┘    paths, links                     (move_to, a direction a tick)
                       │
                       └─► marker modules (NavLinkModule, ...) ─► NavServer.add_link
```

- **`NavServer`** (C++, `native/src/`): builds the nav mesh in tiles on worker threads, around the places streaming asks for, and answers path searches. An engine singleton, there only when the navcore library is loaded.
- **Feeders** hand the level to nav: `world/TerrainNavFeeder` the terrain's chunks, `world/BodyNavFeeder` a static body's boxes (walls, rocks).
- **`NavigationManager`** is a part on every pawn. A controller calls `move_to(point)`, then asks `get_move_direction()` once per tick and walks that way, as a player's keys would. It never moves the pawn itself.
- **Nav markers** say what a spot means: `NavLink` (a jump, ladder or door), `NavPoint` (cover, patrol), `NavSmartObject` (a seat), `NavArea`, `NavObstacle`. They're plain data; a **module** (a `NavMarkerModule` node in the level) holds the code that acts on one kind. `NavMarkerManager` holds them all and tells modules what arrives and leaves.
- **Nav tags** such as `nav.link.jump` say what a marker is: the `nav` category of the one tag registry (`tags/TagRegistry`), which turns them into bits, the same on every machine.

## How to use it

**Make a level walkable.** Put a `WorldCoordinator` with a terrain and a `TerrainNavFeeder` in it (the arena samples show how), and give the feeder a `NavHooks`. Streaming sources decide where nav is built.

**Add a wall or a block.** A `StaticBody3D` with a `BoxShape3D` collision shape, plus a `BodyNavFeeder` child. Paths go around it, and pawns walking the nav mesh slide along it. Only boxes go into nav for now.

**Send a pawn somewhere.** From AI or game code:
```gdscript
if not pawn.navigation_manager.move_to(target):
    pass # no way there: pick another target
```
The pawn walks while its controller asks for directions; `arrived` fires at the end. `get_path_state()` says where a move stands (PENDING while nav is still being built under it).

**Place a jump or a ladder.** A `NavMarkerNode` with a `NavLink` marker (set `end_offset`, `two_way`, `press_action`), and a `NavLinkModule` somewhere in the level. Nav also finds jumps and drops at ledges by itself (`NavServer`'s `auto_links`).

**Mark a point of interest.** A `NavMarkerNode` with a `NavPoint` marker and a declared tag (`nav.point.cover`, `nav.point.patrol`...). AI finds them with `NavMarkerManager.find_nearest(tag, from, max_distance)`. Tags are declared in `resources/tag_declarations.tres`; the inspector offers them in a dropdown.

**See it.** Press **F9** in a debug build: the nav mesh coloured by room, links as arcs, markers as crosses.

**Big pawns.** Nav is built for pawns up to 0.4 m in radius (tier 0). A wider pawn still paths, but its walls are checked by physics, with a warning. Larger tiers come with tier 1.

## How a move works

`move_to(point)` ends in one of the path states (`NONE`, `FOLLOWING`, `PENDING`, `ARRIVED`, `UNREACHABLE`):

- **No nav at all** (no navcore library, or nothing under the pawn and none being built): the pawn walks a straight line to the point, so click-to-move works in a bare test level. With `straight_line_without_nav` off, `move_to` returns false (`UNREACHABLE`).
- **Nav still being built under the pawn:** `PENDING`. `move_to` returns true, the pawn stands, and it tries again every `pending_retry_ticks` until it finds a path, nav finishes with none under it (the straight line), or `pending_give_up_ticks` pass (`UNREACHABLE`).
- **Nav under the pawn but the point nowhere near nav:** `move_to` returns false and any old path is dropped, even while nav builds elsewhere. In a streaming game that is the usual case, so whatever asked (`AIGoToPointBehaviour`'s legs, say) picks a nearer point when told no.
- **A point nav can't reach** (an island): the path goes to the nearest place it can reach and the pawn arrives there. `is_partial()` says so, while following and after arriving.
- **Links:** a path may cross jumps and drops (found by nav itself) and placed `NavLink`s. At a link's start `take_link_action()` gives the action to press (a drop has none). If the pawn hasn't reached the link's far end within `link_timeout`, it finds a new path to the same place once per `move_to`; missing again, it gives up (`UNREACHABLE`).
- **Paths at scale:** `paths_now_per_tick` paths are found straight away each tick, across every pawn. Any more go to `NavServer`'s queue and those pawns wait `PENDING`, so an army given a goal in one tick doesn't stall it.
- A change of controller calls `stop()`, so the AI never walks the rest of a player's path. If the manager's parent isn't a `Pawn` it warns and `move_to` returns false.

Over the network a client follows its own path and only sends directions; the server never sees a path (pawn spec 7). Not yet: a new path when nav tiles change, size tiers per pawn, and domains (air, ships).

## Settings worth knowing

| Setting | Where | Default | What it does |
|---|---|---|---|
| `agent_radius` | `NavServer.configure` | 0.4 m | The smallest pawn's radius; nav keeps paths this far from walls |
| `auto_links` | `NavServer.configure` | on | Nav finds jumps and drops at ledges by itself |
| `use_links` | `NavigationManager` | on | Off for a pawn that can't jump |
| `straight_line_without_nav` | `NavigationManager` | on | With no nav at all, walk straight to the point |
| `paths_now_per_tick` | `NavigationManager` (shared) | 8 | Paths found at once each tick; the rest queue |
| `link_timeout` | `NavigationManager` | 3 s | How long a link may take before finding a new path |

## Tests

`navigation/tests/`: `navigation_manager_selftest` (paths, links, waiting), `nav_selftest` (the library: tiles, paths, budgets), `nav_links_selftest`, `nav_link_module_selftest`, `nav_markers_selftest`, `nav_marker_node_selftest`, `nav_marker_manager_selftest`, `tags/tests/tag_registry_selftest` (nav tags are the `nav` category). Also `world/tests/body_nav_feeder_selftest` and `diagnostics/tests/nav_debug_view_selftest`. Run them with `bash tools/run_tests.sh <name>`.
