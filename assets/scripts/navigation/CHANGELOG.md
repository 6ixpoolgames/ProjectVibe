<!-- Written by Claude (claude-opus-5-5), 2026-11-17: the navigation system's running changelog (the owner's call: history leaves the
code comments and lives here, next to the code). Newest first. Add an entry with every change; code comments say what the code does
now, this says how it got here and why. -->

# Navigation changelog

Navigation is this folder (`NavigationManager`, nav markers and their modules, `NavTags`), the nav library in C++ (`native/src/`, `NavServer`), `NavMarkerManager` (`singletons/`), and the feeders that hand it the world (`world/TerrainNavFeeder`, `world/BodyNavFeeder`). Design: [docs/navigation/NAV_SPEC.md](../../../docs/navigation/NAV_SPEC.md). Overview: [README.md](README.md).

## Refactor candidates

Code that works but doesn't yet fit the project's goals (reusable, extensible, efficient, designer friendly). Each is marked `REFACTOR:` in the code. Sizes are rough: S an hour or two, M a day, L more.

| What | Where | Why | Size |
|---|---|---|---|
| One shared way to reach `NavServer` | `_nav_server()` in `NavigationManager`, `NavLinkModule`; `_get_nav()` in `world/BodyNavFeeder`; `diagnostics/NavDebugView`; three places in `world/TerrainNavFeeder` | The same "is the C++ library loaded" lookup is written out several times. One static helper (on a small `Nav` class, say) is one place to change and to read | S |
| One tag-set class for abilities and nav | `NavTags`, `tags/TagRegistry` | The same rules, copied on purpose when NavTags was written. A single class used twice halves the code and the tests, and a third tag set (a game's own) would come free | M |
| Move `TerrainSettings` out of navigation | `TerrainSettings.gd` | It describes a terrain (where it is, its chunk size), so it belongs in `terrain/` or `world/`; names and folders should say what things are | S |
| Move `NavMarkerDebugModule` to `diagnostics/` | `modules/NavMarkerDebugModule.gd` | A debug tool in a production folder. `diagnostics/NavDebugView` already uses it; the two sample scenes that place it would follow | S |

## 2026-11-17

- **`NavigationManager.path_ended(reached)`** (scaling spec 6.2's wake-ups): sent once when a path ends, arrived (after `arrived`) or given up (no way after all, waited too long for nav, a link that couldn't be crossed); not for `stop()`. The AI's behaviours wait for it instead of checking every few ticks whether a walk is still under way.
- **Navmesh walking on by default.** Nav's default pawn radius (`agent_radius`, tier 0) is 0.4 m, the default pawn's (was 0.3), so `CrowdMover`'s C++ batch walks pawns along the nav mesh and slides them along walls. A pawn crossing a link (`is_crossing_link()`) is moved by physics until it's across: walking along the mesh stopped it at a ledge's edge.
- **Walls in nav.** `world/BodyNavFeeder`: a child of a StaticBody3D feeds its box shapes to nav (one shared input layer, a mesh per body), so paths go around walls.
- **Debug view.** F9 shows the nav mesh, links and markers (`diagnostics/NavDebugView`).
- **Paths at scale.** `NavigationManager.paths_now_per_tick` (8) paths are found straight away each tick; the rest go to `NavServer`'s queue (`find_path`, `take_path_result`, with links) and their pawns wait, PENDING. `stop()` cancels a queued path, and `pending_give_up_ticks` covers the wait. Before, an army given a new goal searched every path at once on the main thread.
- **Partial paths without links.** `NavServer.find_path_now_result` gives points, link ids and a partial flag with links on or off; before, a path found with `use_links` off had no partial flag.
- **The C++ bundle's nav fixes.** A stale tile build no longer clears a remade tile's newer build (it was built twice); a terrain edit rebuilds only the tiles under it (`submit_mesh`'s `dirty_bounds`); an empty `tier_radii` list is ignored; nav height columns are edited in place.
- **Comments cleaned up** for the documentation pass: dated notes moved here, doc comments in Godot's markup so the editor's help and `REFERENCE.md` show them properly.
- **`NavMarkerManager`'s comments** too (`singletons/NavMarkerManager.gd`): its header called it "the nav singleton's GDScript layer" (it holds markers; `NavServer` is the nav singleton), and `request_scene_marker` said NavMarkerNode "will call" it (it does).

## 2026-11-16

- **Path states.** `PathState` (NONE, FOLLOWING, PENDING, ARRIVED, UNREACHABLE) and `get_path_state()` replace a has-arrived flag. Every odd case ends in a state rather than a silent straight line.
- **Waiting for nav.** With nav still being built and none under the pawn, `move_to` returns true and the pawn waits (PENDING), retrying every `pending_retry_ticks` and giving up after `pending_give_up_ticks`.
- **`straight_line_without_nav`**, on by default: with no nav at all, a move goes in a straight line; off, it's UNREACHABLE.
- **`is_under_way()`**: following or waiting, which controllers use to keep asking for a direction.
- **The partial flag** comes from the nav library's own answer; it was dropped before.
- **Stepped pawns** (pawn spec 8.21): waits and link timers count `pawn.ticks_elapsed`, since a distant pawn runs every 2nd or 4th tick.
- **Fix:** a new path that was PENDING after a missed link had no corners, and counted as arrived.

## 2026-11-12

- A whole-number division in `NavMarkerDebugModule` is marked as meant, so it doesn't warn.

## 2026-11-08

- **Links** (nav phase 3): a path may cross jumps, drops and placed links. `take_link_action()` gives the action to press at a link's start; `is_crossing_link()`; `use_links`; `link_timeout`, after which the pawn finds one new path, then gives up. `NavLink.press_action` (a named action, jump by default) replaced an ability tag, since pawns start abilities by pressing named actions. `NavLinkModule` hands placed links to nav.
- **`NavigationManager`** (pawn spec section 7, step 7): the pawn's only contact with navigation, for click-to-move and AI `move_to`.

## 2026-11-07

- `TerrainSettings` lost its noise settings: they were for a terrain estimator that was never built, and only a test read them.
- Terrain and nav split apart: `world/TerrainNavFeeder` feeds nav from a terrain, so neither knows the other. Systems renamed so each name says what it does.
- `NavWorld` renamed `NavMarkerManager`: it manages markers and doesn't find paths.

## 2026-11-06

- **Nav markers** (nav spec section 21): `NavMarker` and its types (`NavLink`, `NavArea`, `NavObstacle`, `NavPoint`, `NavSmartObject`), `NavMarkerNode` to place one in a scene, `NavMarkerModule` for the code that acts on them, `NavMarkerDebugModule` to draw them, `NavTags` for their tags, and `NavMarkerManager` to hold them.

## 2026-11-03 to 2026-11-05

- **The nav library** (`native/`, NavServer): a C++ GDExtension building a Recast/Detour nav mesh from streamed input, in tiles on worker threads (nav spec phases 1 and 2). A networked stress test on terrain, and four defects from an audit, fixed.
