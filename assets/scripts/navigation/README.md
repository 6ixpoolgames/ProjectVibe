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
- **`NavTags`** turns marker tags such as `link.jump` into bits, the same on every machine.

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

**Mark a point of interest.** A `NavMarkerNode` with a `NavPoint` marker and a declared tag (`point.cover`, `point.patrol`...). AI finds them with `NavMarkerManager.find_nearest(tag, from, max_distance)`. Tags are declared in `resources/nav_tag_declarations.tres`.

**See it.** Press **F9** in a debug build: the nav mesh coloured by room, links as arcs, markers as crosses.

**Big pawns.** Nav is built for pawns up to 0.4 m in radius (tier 0). A wider pawn still paths, but its walls are checked by physics, with a warning. Larger tiers come with tier 1.

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

`navigation/tests/`: `navigation_manager_selftest` (paths, links, waiting), `nav_selftest` (the library: tiles, paths, budgets), `nav_links_selftest`, `nav_link_module_selftest`, `nav_markers_selftest`, `nav_marker_node_selftest`, `nav_marker_manager_selftest`, `nav_tags_selftest`. Also `world/tests/body_nav_feeder_selftest` and `diagnostics/tests/nav_debug_view_selftest`. Run them with `bash tools/run_tests.sh <name>`.
