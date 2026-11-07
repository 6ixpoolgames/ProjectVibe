<!-- Written by Claude (claude-opus-5-5), 2026-11-02: design spec for the bespoke voxel-first dynamic navigation system. Nothing here is built yet. -->

# Navigation System Spec (draft 1)

**Status:** phases 1 and 2 of section 19 are built, along with the marker steps in section 21.10. The rest is design. Function signatures for anything not built are proposals, written as C++ headers (GDExtension, godot-cpp) and a little GDScript for the pawn side. <!-- Claude 2026-11-06: this line still said no code exists -->
**Scope:** flat-plane worlds, constant gravity (−Y). Solid spans on the nav grid are the universal input; any terrain generator (heightmap, blocks, density, meshes) opts in through an optional **NavHooks** resource and is stacked with the others (section 5).
**Revisions:** 2026-11-03 (Claude): section 5 rewritten from a single voxel source to the NavHooks / provider model; pipeline, API, walkthroughs and phases updated to match. 2026-11-06 (Claude): section 21 added, nav markers and modules.
**Performance numbers** are ballpark estimates, not measurements. Phase 0 is a benchmark spike to replace them.

How to read this:
- Sections 1–4 are the vocabulary: goals, the moving parts, the threading model, the core types.
- Sections 5–15 go module by module, bottom (voxels) to top (Godot pawns). Each lists its job, its data, and its major functions with what they do.
- Section 16 walks through six concrete scenarios end to end. **If you only read one section to understand the code flow, read 16.**
- Sections 17–20 cover the pawn side, performance budgets, build phases, and open questions.
- Section 21 covers nav markers and modules. <!-- Claude 2026-11-06: new section; also corrected the range above -->

---

## 1. Goals and non-goals

**Goals**
1. Dynamic: player-edited terrain, streamed chunks, moving obstacles, all without hitches.
2. One nav map built for the smallest pawn; bigger pawns filter by clearance tier.
3. Hierarchical: long paths are cheap; detail is only computed near where agents are.
4. Tagged links (jump, climb, door, board) that hand off to the pawn's action system by tag.
5. Crowds: physics pawns (`CharacterBody3D`) and lightweight crowd units (data rows, RTS scale).
6. Hooks for a game-specific swarm coordinator to take over groups of agents.
7. Multiple **nav domains** (ground, air, moving frames, wall-walking surface) behind one interface.
8. Multiplayer-friendly: deterministic builds from replicated voxel data, server-authoritative AI.

**Non-goals (for now)**
- Spherical planets / radial gravity.
- Orbital mechanics, vehicle physics (paths are guidance; bodies do their own movement).
- Replacing Godot's physics. We only produce paths and steering.
- The swarm coordinator itself (game-specific; we only provide hooks).

---

## 2. The moving parts

```
 Godot (GDScript)                         C++ GDExtension: NavServer
 ─────────────────                        ──────────────────────────────────────────────
 Pawn                                     ┌─ NavServer (singleton, public API, tick) ──┐
  ├─ Mind (player / AI) ─ move intent ─┐  │                                            │
  ├─ NavAgentComponent ◄───────────────┘  │  TagRegistry      AgentRegistry            │
  │     request_path / desired_velocity ─►│  RequestQueue     CrowdSystem              │
  │     ◄─ link_reached(tags) ────────────│  HierarchicalPlanner                       │
  └─ Body: actions by tag ─ link_done ───►│  ObstacleSystem   EventBus                 │
                                          │                                            │
 Terrain generators, each with NavHooks ─►│  InputStore → CompositeProvider (layers)   │
   heightmap / blocks / density / meshes  │  TileManager (lifecycle, streaming, budget)│
 Player edits (just another layer) ──────►│        ▼                                   │
 Swarm coordinator (game) ─ bulk APIs ───►│  Domains: GroundDomain │ AirDomain │       │
                                          │           FrameDomain  │ SurfaceDomain     │
                                          │  WorkerPool (builds + sliced queries)      │
                                          └────────────────────────────────────────────┘
```

| Module | One-line job |
|---|---|
| `NavHooks` | Optional resource on a terrain generator. Present = it feeds nav. Absent = nav ignores it. |
| `INavInputProvider` | Answers "what's solid here, and what is it?" for a tile, as spans. Built-in adapters cover heightmaps, blocks, density, meshes. |
| `CompositeProvider` | Stacks every input layer in order (add / carve / surface) into one set of spans. |
| `InputStore` | Immutable, versioned copies of submitted generator data, safe for worker threads. |
| `NavServer` | The only public entry point. Owns everything below and runs the per-frame tick. |
| `TagRegistry` | Maps tag names (`"jump"`, `"door"`) to bits. Shared with the action system. **Replaced for nav by `NavTags`, section 21.3.** <!-- Claude 2026-11-06 --> |
| `TileManager` | Tile lifecycle: which tiles exist, their state, versions, build scheduling, commits. |
| `INavDomain` | Interface every domain implements: build a tile, commit it, query it. |
| `GroundDomain` | Spans → clearance tiers → regions → polygons → Detour tiles. The main one. |
| `AirDomain` | Sparse voxel octree for flyers. |
| `FrameDomain` | A domain living in a moving local frame (ships, platforms). |
| `HierarchicalPlanner` | Domain graph → tile corridor → fine path. |
| `RequestQueue` | Budgeted, prioritized path requests. Shared by agents and the coordinator. |
| `AgentRegistry` | Every navigating thing: position, radius, tier, capabilities, owner. |
| `CrowdSystem` | Path following, local avoidance (ORCA), crowd unit integration. |
| `ObstacleSystem` | Non-navigating dynamic objects: carve / avoid / cost. |
| `EventBus` | Tile changed, link reached, path invalidated, etc. Read by agents and the coordinator. |
| `NavWorld` | GDScript layer over `NavServer`: stores tagged marker data (links, areas, points) and searches it. Modules hold the code for each kind. Section 21. <!-- Claude 2026-11-06 --> |
| `WorkerPool` | Background threads for tile builds and sliced path searches. |

---

## 3. Threading model

The rule that keeps this sane: **the nav mesh is only mutated in one place, on one thread, at one time.**

`NavServer::tick(delta)` is called once per physics frame from Godot (an autoload's `_physics_process`). It runs these phases in order:

| Phase | Thread | What happens |
|---|---|---|
| 1. Ingest | main | Apply queued voxel edits and obstacle changes → mark tiles dirty. |
| 2. Commit | main, exclusive | Swap in finished tile builds, up to a time budget (e.g. 1 ms). Publish `TileChanged` events. |
| 3. Schedule | main | Pick next tiles to build (by priority), grab their `InputSnapshot` (refs into the InputStore), hand to workers. |
| 4. Query | workers | Run sliced path searches against the now-stable nav data. Stop before next tick's commit. |
| 5. Crowd | main (or workers, split by agent) | Path following + avoidance → desired velocities / crowd unit positions. |
| 6. Dispatch | main | Emit Godot signals for finished paths, link events, invalidations. |

- **Builds** run on workers any time; they only read a *snapshot* of voxel data taken in phase 3, and write into a private `TileBuildResult`. They never touch live nav data.
- **Queries** only run while no commit is happening (phase 4 ends with a barrier before phase 2 of the next tick). Detour is not safe for `addTile` during queries, so this phase split replaces locks.
- **Stale builds** are thrown away at commit if the tile's version moved on while building.

---

## 4. Core types

```cpp
// ---- identity & coordinates ------------------------------------------------
using DomainId = uint16_t;          // 0 = world ground, 1 = world air, 2+ = frames...
using AgentId  = uint32_t;
using RequestId = uint32_t;
using ObstacleId = uint32_t;
using Version  = uint32_t;          // bumped on every change; stale results compare against it

struct TileKey {                    // a tile = footprint of one voxel chunk column, one vertical band
    DomainId domain;
    int32_t  x, z;                  // tile grid coords
    int16_t  band;                  // vertical band (e.g. 4 voxel chunks tall). Most worlds: one band.
};

struct NavPos {                     // positions inside the core never use big world floats
    TileKey tile;
    Vector3 local;                  // offset from tile origin, always small → no precision loss
};
// NavServer converts world Vector3 <-> NavPos at the API boundary.

// ---- tags & filtering ------------------------------------------------------
using TagMask = uint64_t;           // up to 64 tags in v1. TagRegistry maps name -> bit.
using CapabilityMask = TagMask;     // what an agent CAN do: bits for "jump", "climb", "swim"...

// Detour's 6-bit area id is split in two:
//   bits 5..4 = clearance tier (0..3)   — written by the clearance pass
//   bits 3..0 = surface type   (0..15)  — grass, road, water, mud, door...
// Detour's 16-bit poly flags = fast reject bits (WALK, SWIM, DOOR, DISABLED, ...).
inline uint8_t  areaTier(uint8_t area)    { return area >> 4; }
inline uint8_t  areaSurface(uint8_t area) { return area & 0x0F; }

struct NavFilter {                  // plain data, so the coordinator can build and share them
    uint8_t        minTier;         // agent's clearance tier: poly.tier >= minTier
    CapabilityMask capabilities;    // link tags must be a subset of this
    TagMask        forbidden;       // never use links/areas with these tags
    float          surfaceCost[16]; // per surface type multiplier (INFINITY = impassable)
    uint16_t       includeFlags, excludeFlags;
};

// ---- links -----------------------------------------------------------------
struct LinkDef {
    uint32_t linkId;                // unique per domain; stored as Detour off-mesh userId
    NavPos   start, end;
    float    radius;
    bool     bidirectional;
    TagMask  tags;                  // e.g. "jump" | "gap_2"
    float    cost;                  // extra traversal cost
    DomainId targetDomain;          // == own domain unless this is a cross-domain link
    Variant  payload;               // optional game data (door node, ladder length...)
};
```

---

## 5. Nav input: providers and NavHooks (layer 0)

<!-- Claude 2026-11-03: section rewritten. Was "voxel source" (one IVoxelSource); now any number of terrain generators opt in via NavHooks and are stacked. -->

**Job:** turn whatever terrain generators exist into the one thing the nav pipeline understands: **solid spans per column on the nav grid**, plus surface types and authored link hints.

The dividing line: **generators answer "what's solid here, and what is it?" at the nav grid's resolution. The nav system owns everything else** (slope, clearance, regions, polygons, auto links). Auto links in particular must come after merging, because a jump from a heightmap cliff onto an imported building's roof needs both sources at once.

### 5.1 Opting in: NavHooks

A terrain generator feeds nav **only if it has a `NavHooks` resource**. No resource means nav ignores it, which is right for decorative terrain, distant backdrops and skyboxes. Generators never depend on nav existing: delete the nav system and they still work.

```gdscript
## Written by Claude (claude-opus-5-5), 2026-11-03: SKETCH for the spec only. Not a real file yet.
## Attach to any terrain generator to make it feed the nav system.
class_name NavHooks extends Resource

enum LayerOp { ADD, CARVE, SURFACE }    # union solid / subtract solid / only change surface types

@export var layer_op: LayerOp = LayerOp.ADD
@export var order := 0                   # lower runs first; edits usually go last
@export var surface_map := {}            # generator material/biome id -> nav surface name ("road", "water")
@export var send_estimates := true       # generator also answers cheap "what's roughly here" questions
@export var send_link_hints := true      # ladders, doors, bridges the generator places
```

Using it in a generator. The only nav code a generator ever has is behind `if nav_hooks:`:

```gdscript
## Written by Claude (claude-opus-5-5), 2026-11-03: SKETCH for the spec only. Not a real file yet.
class_name HeightmapTerrainGenerator extends Node3D

@export var nav_hooks: NavHooks          # leave empty = this terrain is invisible to nav
var _nav_layer := -1

func _ready() -> void:
    if nav_hooks:
        _nav_layer = NavServer.add_input_layer(self, nav_hooks, NavServer.ADAPTER_HEIGHTMAP)

func _on_chunk_generated(coord: Vector2i, heights: PackedFloat32Array, surfaces: PackedByteArray) -> void:
    _build_mesh_and_collision(coord, heights)            # your existing code
    if nav_hooks:
        NavServer.submit_heightmap(_nav_layer, coord, heights, CHUNK_SIZE, CELL_SCALE, surfaces)

func _on_chunk_edited(coord: Vector2i, heights: PackedFloat32Array, surfaces: PackedByteArray, edited: AABB) -> void:
    if nav_hooks:   # dirty_bounds = only rebuild what changed, not the whole chunk
        NavServer.submit_heightmap(_nav_layer, coord, heights, CHUNK_SIZE, CELL_SCALE, surfaces, edited)

func _on_chunk_freed(coord: Vector2i) -> void:
    if nav_hooks:
        NavServer.release_chunk(_nav_layer, coord)

func _exit_tree() -> void:
    if nav_hooks:
        NavServer.remove_input_layer(_nav_layer)
```

### 5.2 The contract (C++)

```cpp
enum class LayerOp : uint8_t { ADD, CARVE, SURFACE };

class SpanWriter {                       // wraps rcHeightfield; providers never see Recast
public:
    // Solid from yMin to yMax in this nav column. Overlapping solids merge (union).
    void addSolid(int cx, int cz, float yMin, float yMax, uint8_t surface);
    // Remove solid. Recast has no span subtraction, so this is our own sorted-span-list op.
    void carve(int cx, int cz, float yMin, float yMax);
    // Change the surface type of walkable tops inside a height range. Last writer wins.
    void setSurface(int cx, int cz, float yMin, float yMax, uint8_t surface);
    const NavGridInfo& grid() const;     // cell size, cell height, tile origin, border width
};

class INavInputProvider {                // what every input layer looks like to the nav core
public:
    // Fill spans for the tile + border region. Called on a WORKER thread.
    // Must be a pure function of (region, snapshot): same input -> same spans, on every peer.
    virtual void fillSpans(const TileRegion& region, const InputSnapshot& snap, SpanWriter& out) const = 0;

    // Cheap estimate for unbuilt tiles: height range, max slope, water fraction, "blocked" ratio.
    virtual TileSummary estimate(const TileRegion& region, const InputSnapshot& snap) const = 0;

    // Semantic extras only the generator knows (authored ladders, doors, bridges).
    virtual void linkHints(const TileRegion& region, const InputSnapshot& snap,
                           std::vector<LinkHint>& out) const {}

    // Does this layer have data covering the region yet? (false -> border filled from estimate)
    virtual bool covers(const TileRegion& region, const InputSnapshot& snap) const = 0;
};
```

`InputSnapshot` is the set of immutable submitted chunks a build is allowed to read (section 5.6). Providers never read live generator state.

### 5.3 NavServer input API

```cpp
// --- layers -------------------------------------------------------------------
int  NavServer::add_input_layer(Object* owner, Ref<NavHooks> hooks, AdapterKind kind);
void NavServer::remove_input_layer(int layer);           // marks every tile it covered dirty
int  NavServer::add_native_provider(Ref<NavInputProviderGD> p, Ref<NavHooks> hooks); // C++ procedural

// --- data submission (main thread; data is copied, generator keeps its own) -----
void submit_heightmap(int layer, Vector2i chunk, PackedFloat32Array heights, Vector2i size,
                      float cellScale, PackedByteArray surfaces, AABB dirtyBounds = {});
void submit_blocks   (int layer, Vector3i chunk, PackedByteArray solidBits,
                      PackedByteArray materials, AABB dirtyBounds = {});
void submit_density  (int layer, Vector3i chunk, PackedFloat32Array density, float isoLevel,
                      PackedByteArray materials, AABB dirtyBounds = {});
void submit_mesh     (int layer, int64_t meshId, PackedVector3Array tris, Transform3D xf,
                      int surface);                      // imported levels, props, buildings
void submit_link_hints(int layer, Variant chunkOrMeshId, Array hints);
void release_chunk   (int layer, Variant chunkOrMeshId);
```

Each `submit_*` replaces that chunk's snapshot, bumps its version, and marks the tiles under `dirtyBounds` dirty (whole chunk if empty). Applied in tick phase 1 like every other change.

### 5.4 Built-in adapters

GDScript generators can't be called from worker threads, so they hand over **data** and a C++ adapter does the sampling on workers. You can write new generators entirely in GDScript.

| Adapter | Input | How spans are made | Notes |
|---|---|---|---|
| `HeightmapAdapter` | height grid per chunk | One solid per column, from world floor to sampled height. No rasterization. | First one to build. Coarser than nav grid → bilinear; finer → take max. |
| `BlockAdapter` | solid bits per voxel | Runs of solid voxels per column | Use 3×3 nav cells per voxel column, or radius erosion closes 1-wide corridors. Steps: step-edge area policy. |
| `DensityAdapter` | density samples | Zero-crossings along Y per nav column, interpolated | Must use the same interpolation as your mesher, or nav floats/sinks vs collision. Optional: v1 can feed the chunk's collision mesh to `MeshAdapter` instead. |
| `MeshAdapter` | triangles + transform | Recast rasterization (`rcRasterizeTriangles`) | Imported levels, buildings, props; also smooth terrain via its collision mesh. Slowest, exact to collision. |
| native provider | C++ code | Anything, e.g. evaluate noise directly on workers | For fast procedural generators. No data submission needed: the function *is* the data. |

```cpp
void HeightmapAdapter::fillSpans(const TileRegion& r, const InputSnapshot& snap, SpanWriter& out) const {
    for (int cz = r.minZ - r.border; cz < r.maxZ + r.border; ++cz)
    for (int cx = r.minX - r.border; cx < r.maxX + r.border; ++cx) {
        Vector2 w = out.grid().cellCentre(cx, cz);
        float   h = snap.sampleHeightBilinear(m_layer, w);       // crosses chunk edges transparently
        out.addSolid(cx, cz, m_worldFloorY, h, snap.surfaceAt(m_layer, w));
    }
}
```

### 5.5 Stacking layers: CompositeProvider

The world is usually several generators at once. The composite applies every layer, in `order`:

```cpp
class CompositeProvider {
public:
    void fillSpans(const TileRegion& r, const InputSnapshot& snap, SpanWriter& out) const {
        for (const InputLayer& layer : m_layersSortedByOrder) {
            if (!layer.provider->covers(r, snap)) continue;      // handled by provisional rule
            LayerOpWriter w(out, layer.op);                      // ADD->addSolid, CARVE->carve, SURFACE->setSurface
            layer.provider->fillSpans(r, snap, w);
        }
    }
    TileSummary estimate(const TileRegion& r, const InputSnapshot& snap) const; // combine layer estimates
    void linkHints(const TileRegion& r, const InputSnapshot& snap, std::vector<LinkHint>& out) const;
};
```

Example world:

```
order  layer                    op       adapter
  0    Terrain         ADD      HeightmapAdapter   ground
 10    CaveCarver               CARVE    BlockAdapter       tunnels cut into the ground
 20    Buildings (scene meshes) ADD      MeshAdapter        imported buildings / props
 30    RoadSplines              SURFACE  native            roads become a cheap surface type
100    PlayerEdits              ADD/CARVE BlockAdapter      diffs from digging and building
```

- Generators stay pure and never change; player edits are just a high-order layer. Only edit diffs need replicating in multiplayer.
- Each layer reports its own changes, so only tiles that layer touched rebuild.
- Removing a layer (a building is destroyed) dirties exactly the tiles it covered.

### 5.6 Rules every provider follows

1. **Pure and deterministic.** `fillSpans` reads only the `InputSnapshot`. Same snapshot → same spans, on every machine.
2. **The nav grid is the boss.** Providers sample at the nav cell size they're given; they never pick their own resolution.
3. **Borders.** Fill the tile *plus* `border` cells. If a neighbouring chunk isn't submitted yet, `covers()` returns false for that part; the core fills it from `estimate()` and marks the tile **provisional** (section 9.2). It rebuilds automatically when the chunk arrives.
4. **Surface types** go through the layer's `surface_map`; unmapped materials become the default walkable type.
5. **Slope is not the provider's job.** The pipeline's slope filter (section 8.2, step 1) handles it for every source.
6. **Edits come with bounds** when possible, so one dug hole doesn't rebuild a whole chunk's tiles.

### 5.7 Data lifetime: the InputStore

- Every `submit_*` stores an immutable, ref-counted copy keyed by `(layer, chunk)`.
- A build's `InputSnapshot` holds references to the copies it needs, so a resubmit mid-build is safe: the build finishes on the old copy, is found stale at commit (version check), and the tile rebuilds from the new one.
- `release_chunk` drops the store's reference; memory frees when the last in-flight build lets go.
- Size: a 64×64 float heightmap chunk is 16 KB, so keeping submitted copies is cheap. Meshes are the expensive input; share them by `meshId` (one copy for 200 identical props, each with its own transform).

---

## 6. NavServer: the public API

**Job:** the single door into the system. GDScript sees only this (exposed as an engine singleton). Everything is asynchronous: you submit, and results come back as signals.

```cpp
class NavServer : public godot::Object {
    GDCLASS(NavServer, Object)
public:
    // ---- setup -----------------------------------------------------------------
    void configure(const NavConfig& cfg);            // cell sizes, tile size, tiers, budgets
    // input layers: add_input_layer / submit_* / release_chunk, see section 5.3
    DomainId add_domain(Ref<NavDomainConfig> cfg);   // ground + air created by default
    void tick(double delta);                         // call once per physics frame

    // ---- streaming interest -------------------------------------------------
    // "Keep nav ready around here." Players, AI groups, cameras register these.
    int  add_interest(Vector3 pos, float load_radius, float unload_radius, int priority);
    void move_interest(int id, Vector3 pos);
    void remove_interest(int id);

    // ---- agents -------------------------------------------------------------
    AgentId register_agent(const Dictionary& params);  // radius, height, capabilities, kind
    void    unregister_agent(AgentId id);
    void    set_agent_position(AgentId id, Vector3 pos); // physics pawns report each frame
    void    set_agent_owner(AgentId id, AgentOwner o);   // SELF or COORDINATOR

    // ---- movement -----------------------------------------------------------
    RequestId move_agent_to(AgentId id, Vector3 target, int priority = 0);
    void      stop_agent(AgentId id);
    Vector3   get_desired_velocity(AgentId id) const;    // physics pawns read this
    void      link_completed(AgentId id, uint32_t link_id, bool success);

    // ---- standalone queries (no agent needed) --------------------------------
    RequestId find_path(Vector3 from, Vector3 to, Ref<NavFilterGD> filter, int priority = 0);
    Vector3   closest_point(Vector3 p, Ref<NavFilterGD> filter) const;
    bool      raycast(Vector3 from, Vector3 to, Ref<NavFilterGD> filter, Dictionary out) const;

    // ---- links & obstacles --------------------------------------------------
    uint32_t   add_link(const Dictionary& link_def);    // manual links (doors, teleporters)
    void       remove_link(uint32_t link_id);
    ObstacleId add_obstacle(Node3D* body, const Dictionary& params);
    void       remove_obstacle(ObstacleId id);

    // ---- signals (emitted in tick phase 6) ----------------------------------
    // path_ready(request_id, agent_id)          path_failed(request_id, reason)
    // link_reached(agent_id, link_id, tags, start, end, payload)
    // path_invalidated(agent_id)                tile_changed(tile_key, version)
};
```

The C++ swarm-coordinator APIs (bulk arrays, flow fields, snapshots) are in section 14; they are not exposed to GDScript by default.

---

## 7. The domain interface

**Job:** let very different navigation representations share streaming, queries, tags and events.

```cpp
class INavDomain {
public:
    virtual DomainId id() const = 0;

    // --- building (worker thread) ----------------------------------------------
    // Gather inputs on the main thread (cheap: grab voxel snapshots, obstacle list).
    virtual std::unique_ptr<TileBuildInput> gatherInput(const TileKey& key) = 0;
    // Do the heavy work on a worker. Pure function: input -> result. No shared state.
    virtual std::unique_ptr<TileBuildResult> buildTile(const TileBuildInput& in) = 0;

    // --- committing (main thread, exclusive) -------------------------------------
    virtual void commitTile(const TileKey& key, std::unique_ptr<TileBuildResult> r) = 0;
    virtual void unloadTile(const TileKey& key) = 0;

    // --- coarse graph (for the planner) ------------------------------------------
    virtual void getPortals(const TileKey& key, std::vector<Portal>& out) const = 0;
    virtual float estimateCost(const TileKey& key, const NavFilter& f) const = 0;

    // --- fine queries (worker thread, read-only) ----------------------------------
    virtual QueryStatus beginPath(PathJob& job) = 0;                 // set up sliced search
    virtual QueryStatus stepPath(PathJob& job, int maxIterations) = 0;
    virtual bool closestPoint(const NavPos& p, const NavFilter& f, NavPos& out) const = 0;
    virtual bool raycast(const NavPos& a, const NavPos& b, const NavFilter& f, RayHit& out) const = 0;

    // --- links -------------------------------------------------------------------
    virtual const LinkDef* findLink(uint32_t linkId) const = 0;
};
```

---

## 8. Ground domain (the main one)

**Job:** turn the merged input spans into a Detour nav mesh, one tile at a time, with clearance tiers, surface types, portals and auto-generated tagged links.

### 8.1 Tile data levels

Each ground tile can hold up to four levels of data. Higher levels are dropped first under memory pressure:

| Level | What | Size (rough) | Used for |
|---|---|---|---|
| 0 Summary | `TileSummary` from the voxel source / last build | bytes | coarse planning when not built |
| 1 Spans | compact heightfield after clearance pass | ~50–200 KB | fast re-carving when obstacles change |
| 2 Polys | Detour tile data + portals + tag table | ~20–100 KB | queries |
| 3 Source | the layers' submitted data | lives in the InputStore (section 5.7) | full rebuilds |

### 8.2 Build pipeline (`GroundDomain::buildTile`)

Runs on a worker. Every step is a plain function; each is a hook point you can replace or extend.

```cpp
std::unique_ptr<TileBuildResult> GroundDomain::buildTile(const TileBuildInput& in) {
    rcContext ctx;
    rcHeightfield hf;

    // 1. Inputs -> spans: every input layer, in order, through the composite provider
    //    (providers write through SpanWriter and never see Recast; section 5).
    //    Then the slope filter: directly fed spans skip Recast's per-triangle slope test,
    //    so slope is checked here from neighbour column heights, for every source alike.
    SpanWriter writer(hf, in.grid);
    in.composite->fillSpans(in.region, in.snapshot, writer);
    applySlopeFilter(in.config.maxSlopeDeg, hf);

    // 2. Stamp carved obstacles (sleeping crates etc.) as unwalkable spans.
    stampObstacles(in.carvedObstacles, hf);

    // 3. Standard Recast filters: low-hanging obstacles, ledges, low-height spans.
    applyRecastFilters(ctx, in.config, hf);

    // 4. Compact heightfield + erode by the SMALLEST pawn radius.
    rcCompactHeightfield chf;
    buildCompact(ctx, in.config, hf, chf);   // rcBuildCompactHeightfield + rcErodeWalkableArea

    // 5. Surface types were already written by providers in step 1 (area bits 3..0).
    //    This step is a hook for game-specific marking, e.g. spans next to water -> "shore".
    applyAreaHooks(in.config, chf);

    // 6. Clearance tiers: distance field -> tier, written into area bits 5..4.
    //    Must happen BEFORE regions so regions (and therefore polygons) split per tier.
    computeClearanceTiers(ctx, in.config.tierRadii, chf);

    // 7. Regions, contours, polygons, detail mesh (standard Recast).
    buildRegionsAndPolys(ctx, in.config, chf, result->pmesh, result->dmesh);

    // 8. Auto links from the merged span shape (step-ups, gaps, drops) + provider link hints.
    generateAutoLinks(chf, in.config, in.linkHints, result->links);

    // 9. Pack Detour tile (includes links as off-mesh connections, userId = linkId).
    packDetourTile(in.key, result->pmesh, result->dmesh, result->links, result->tileData);

    // 10. Portals + intra-tile portal-to-portal costs per tier (for the coarse graph).
    buildPortals(in.key, result->pmesh, in.config, result->portals);

    // 11. Keep spans (level 1) for fast obstacle re-carving later.
    result->cachedSpans = std::move(chf);
    result->builtFromVersion = in.version;
    return result;
}
```

Step details:

```cpp
// 1. (Span filling itself is section 5.) The slope filter: for each walkable span top,
//    compare its height with the 4 neighbour column tops; if rise / cellSize exceeds
//    tan(maxSlope) toward every neighbour it could step to, mark it unwalkable.
//    Border cells come from neighbour chunks so tile edges match exactly
//    (this is why tiles stitch without a stitching pass).
void applySlopeFilter(float maxSlopeDeg, rcHeightfield& hf);

// 6. rcBuildDistanceField fills chf.dist (distance to nearest wall, in ~half-cells).
//    For each walkable cell: tier = highest t where dist >= tierRadii[t].
//    area = (tier << 4) | surface.
void computeClearanceTiers(rcContext& ctx, const std::array<float,4>& tierRadii,
                           rcCompactHeightfield& chf);

// 8. Looks at neighbouring columns:
//    - neighbour floor 1 voxel higher and no step allowed   -> link tag "step_up_1"
//    - floor continues after a 1..N cell gap at same height -> "jump_gap_N"
//    - floor much lower                                      -> "drop_N" (one-way)
//    - provider link hints (ladders, doors, bridges)         -> converted to LinkDefs as given
//    Links are merged along edges so a long ledge makes a few links, not hundreds.
void generateAutoLinks(const rcCompactHeightfield& chf, const GroundConfig& c,
                       const std::vector<LinkHint>& hints, std::vector<LinkDef>& out);

// 10. A portal = a run of polygon edges on a tile border, grouped by neighbour side and tier.
//     For each tier, Dijkstra inside the tile gives cost(portalA -> portalB). That's the L2 graph.
void buildPortals(const TileKey& key, const rcPolyMesh& pm, const GroundConfig& c,
                  std::vector<Portal>& out);
```

### 8.3 Commit (`GroundDomain::commitTile`)

```cpp
void GroundDomain::commitTile(const TileKey& key, std::unique_ptr<TileBuildResult> r) {
    // Caller (TileManager) already checked r->builtFromVersion == tile.version.
    dtTileRef old = m_navMesh->getTileRefAt(key.x, key.z, key.band);
    // Claude 2026-11-05: as built, the old tile's data is copied first and put back if addTile refuses the new one.
    if (old) m_navMesh->removeTile(old, nullptr, nullptr);       // frees old tile data
    m_navMesh->addTile(r->tileData, r->tileSize, DT_TILE_FREE_DATA, 0, nullptr);
    // Detour automatically connects shared edges with already loaded neighbours,
    // and off-mesh links whose far end lands in a neighbour tile.
    m_linkTables[key]  = std::move(r->links);                    // linkId -> LinkDef
    m_portals[key]     = std::move(r->portals);
    m_cachedSpans[key] = std::move(r->cachedSpans);
}
```

Detour's tile "salt" changes on every add, so old poly refs held by agents become detectably invalid. That plus `TileChanged` events drives replanning (section 12.4).

### 8.4 Fast path for cost-only changes

Changing a surface cost (e.g. "this area is on fire") does not need a rebuild:

```cpp
// Instant: dtNavMesh::setPolyArea / setPolyFlags on every poly overlapping the shape.
// Coarse (whole polys), but zero build cost. Used by ObstacleSystem COST mode.
void GroundDomain::stampAreaOverride(const AABB& box, uint8_t surface, uint16_t flags);
```

---

## 9. Tile lifecycle and streaming (TileManager)

**Job:** decide which tiles exist, at what detail, and keep builds and commits within budget.

### 9.1 States

```
Unknown ──estimate──► Estimated ──wanted──► Queued ──picked──► Building ──commit──► Ready
                         ▲                     ▲                    │                 │
                         │                     └──── edit (Dirty) ──┴─────────────────┘
                         │                                                            │
                     Unloaded ◄── LRU evict ── Cached (spans+polys kept, no interest) ◄┘
```
- While a Ready tile is rebuilding (Dirty → Building), the **old version keeps serving queries** until the atomic swap at commit.

```cpp
struct TileRecord {
    TileKey   key;
    TileState state;
    Version   version;            // bumped on every input change (edit, obstacle, load)
    Version   committedVersion;   // version of the data currently live
    float     priority;           // recomputed each tick from interests + routes
    uint32_t  routeRefs;          // how many active corridors pass through this tile
    uint64_t  lastUsedFrame;      // for LRU
};

class TileManager {
public:
    void markDirty(const TileKey& key, DirtyReason why);   // bumps version, -> Dirty/Queued
    void addRouteRef(const TileKey& key);                  // planner: "a path needs this tile"
    void releaseRouteRef(const TileKey& key);

    // tick phase 2: commit finished builds, oldest-priority-first, until budget used.
    void commitFinished(double budgetMs, EventBus& events);
    // tick phase 3: recompute priorities, dispatch top-N builds to workers.
    void scheduleBuilds(WorkerPool& pool, int maxInFlight);
    // evict Cached tiles beyond memory budget (LRU), drop to Unloaded or Summary.
    void evict(size_t memoryBudgetBytes);

private:
    float computePriority(const TileRecord& t) const;
    // priority = interest proximity + routeRefs weight + "is dirty under an agent" boost
};
```

### 9.2 Rules
- **Load radius < unload radius** (hysteresis) so tiles near a boundary don't thrash.
- **Neighbour dependency:** a tile's border reads neighbour data, so an edit within `border` cells of a tile edge dirties the neighbour too.
- **Provisional tiles:** if a border needs a chunk no layer has submitted yet, it's filled from `estimate()` and the tile is marked provisional. It's re-queued automatically when that chunk arrives. Provisional tiles are usable; paths across their edge may be slightly off until then.
- **Stale result:** if `result.builtFromVersion != tile.version` at commit → discard, tile stays Queued.
- **Rebuild storm guard:** a tile dirtied again while Building is not re-dispatched until the current build lands (coalesces bursts of edits).
- **Offline bake** = pre-filling level 1/2 caches from disk at load; same commit path.

---

## 10. Links and tags

**Job:** connect nav to the pawn's action system. Nav never knows *how* to jump; it only says "a link tagged `jump_gap_2` starts here".

*2026-11-06: nav now has its own tags (`NavTags`), and a link names its action separately. See section 21.3, which replaces the shared registry below.* <!-- Claude 2026-11-06 -->

```cpp
class TagRegistry {
public:
    uint8_t  registerTag(const StringName& name);  // returns bit index, stable for the session
    TagMask  maskOf(const PackedStringArray& names) const;
    PackedStringArray namesOf(TagMask m) const;
};
```

- Link tags are checked during search: a link is usable if `(link.tags & ~filter.capabilities) == 0` and `(link.tags & filter.forbidden) == 0`. That is two bit operations per link.
- Per-tile `linkId → LinkDef` tables hold the rich data; Detour only stores the `userId`.
- Cross-domain links (`targetDomain != domain`) are also registered in the `DomainGraph` (section 12.1).

Link traversal flow is in section 16, scenario D.

---

## 11. Dynamic obstacles (ObstacleSystem)

**Job:** let things that don't navigate (crates, vehicles parked, fallen trees, fire) affect paths.

```cpp
enum class ObstacleMode : uint8_t { AVOID, CARVE, COST };

struct Obstacle {
    ObstacleId id;
    Node3D*    body;            // RigidBody3D / StaticBody3D / anything with a shape
    Shape      shape;           // cylinder or box, in world space
    ObstacleMode mode;
    ObstacleMode forcedMode;    // NONE = automatic
    float      settleTime;      // seconds still before AVOID -> CARVE
    uint8_t    costSurface;     // for COST mode
};

class ObstacleSystem {
public:
    ObstacleId add(Node3D* body, const ObstacleParams& p);
    void remove(ObstacleId id);
    // tick phase 1: read body transforms + sleeping state, switch modes with hysteresis,
    // and mark tiles dirty for CARVE changes.
    void update(double dt, TileManager& tiles, CrowdSystem& crowd, GroundDomain& ground);
    // used by GroundDomain::gatherInput: carved obstacles overlapping a tile
    void carvedIn(const TileKey& key, std::vector<Shape>& out) const;
};
```

| Mode | Effect | Cost | When (automatic) |
|---|---|---|---|
| AVOID | Agents steer around it locally (it's an ORCA obstacle). Paths ignore it. | ~free | Moving |
| CARVE | Cut out of the nav mesh; paths go around. Rebuild from cached spans (level 1). | ~0.5–2 ms per tile | Still for `settleTime` (or RigidBody sleeping) |
| COST | Polys get a surface type with higher cost (`stampAreaOverride`). | instant | Explicit (fire, mud, danger zones) |

Mode switching uses hysteresis: CARVE → AVOID as soon as it moves more than a threshold; AVOID → CARVE only after `settleTime` still.

---

## 12. Queries: the hierarchical planner

**Job:** turn "from A to B with this filter" into something an agent can follow, doing as little fine work as possible.

### 12.1 Graph levels

| Level | Nodes | Edges | Built by |
|---|---|---|---|
| Domain graph | domains (ground, air, each ship) | cross-domain links | link registration |
| L3 | super-chunks (8×8 tiles) | portal clusters, costs from L2 | lazily, from L2 |
| L2 | tile portals (per tier) | intra-tile portal costs (8.2 step 10) + portal adjacency | tile commit |
| L1 | Detour polygons | polygon adjacency + off-mesh links | Detour |

Tiles that are only Estimated contribute L2 edges from `estimateCost` (marked inexact).

### 12.2 Request flow

```cpp
struct PathRequest {
    RequestId id;
    AgentId   agent;            // 0 = standalone query
    NavPos    start, goal;
    NavFilter filter;
    int       priority;
    Version   issuedAtFrame;
};

class RequestQueue {            // shared by agents, standalone queries and the coordinator
public:
    RequestId push(PathRequest r);
    void cancel(RequestId id);
    // tick phase 4: workers pull from here, highest priority / oldest first.
    bool pop(PathRequest& out);
};

class HierarchicalPlanner {
public:
    // Runs as a resumable job on a worker. Returns PARTIAL if out of iteration budget;
    // the job is resumed next query phase.
    QueryStatus run(PathJob& job, int iterationBudget);

private:
    // a. Snap start/goal to nav (closestPoint). If goal tile isn't Ready, snap to its estimate.
    bool resolveEndpoints(PathJob& job);
    // b. If start/goal domains differ: A* over the domain graph -> list of (domain, entryLink, exitLink).
    bool planDomains(PathJob& job);
    // c. Per domain segment: A* over L3 then L2 -> TileCorridor (ordered tiles + portals).
    bool planTileCorridor(PathJob& job, int segment);
    // d. addRouteRef on corridor tiles -> TileManager prioritises building them.
    void requestCorridorTiles(PathJob& job);
    // e. Detour sliced findPath restricted to the first H tiles of the corridor ("horizon").
    //    The rest is refined later as the agent advances (refineAhead).
    QueryStatus refineFine(PathJob& job, int iterationBudget);
};

struct PathResult {
    std::vector<DomainSegment> segments;   // per domain
    TileCorridor               corridor;   // full coarse route
    std::vector<dtPolyRef>     finePolys;  // refined prefix only
    std::vector<uint32_t>      linksOnRoute;
    bool                       partial;    // goal not reached (unreachable, or too long to return) -> path as close as it got
};
```

### 12.3 Search-time filter

Implemented as a Detour virtual query filter (`DT_VIRTUAL_QUERYFILTER`), so it can check the tier and the corridor:

```cpp
class CorridorQueryFilter : public dtQueryFilter {
    bool passFilter(dtPolyRef ref, const dtMeshTile* tile, const dtPoly* poly) const override {
        if (areaTier(poly->getArea()) < m_f.minTier) return false;      // clearance
        if (!m_corridorTiles.contains(tile))         return false;      // stay in corridor
        if (poly->getType() == DT_POLYTYPE_OFFMESH_CONNECTION)
            return linkAllowed(tile, poly);                              // tag bit ops
        return dtQueryFilter::passFilter(ref, tile, poly);               // include/exclude flags
    }
    float getCost(...) const override; // distance * surfaceCost[areaSurface(area)] + link cost
};
```

### 12.4 Replanning

```cpp
// tick phase 2 publishes TileChanged{key, oldVersion, newVersion}.
// AgentRegistry keeps an index tile -> agents whose corridor crosses it.
void AgentRegistry::onTileChanged(const TileChanged& e) {
    for (AgentId a : m_corridorIndex[e.key])
        m_agents[a].flags |= NEEDS_REPAIR;   // repaired by CrowdSystem with a per-tick budget
}
// Repair order: (1) dtPathCorridor::fixPathStart / optimizePathTopology locally;
// (2) if that fails, re-run refineFine for the horizon; (3) if the corridor itself is
// broken (portal gone), re-run planTileCorridor. Emits path_invalidated only on (3).
```

---

## 13. Agents and crowd

### 13.1 Two kinds of agent

| | Physics pawn | Crowd unit |
|---|---|---|
| Godot side | `CharacterBody3D` + `NavAgentComponent` | none per unit (MultiMesh rendering) |
| Who moves it | Godot (`move_and_slide`) using `desired_velocity` | `CrowdSystem` directly (integrates position, clamps to nav) |
| Position source | pawn reports via `set_agent_position` | owned by nav |
| Scale | tens–low hundreds | thousands |

```cpp
enum class AgentKind  : uint8_t { PHYSICS_PAWN, CROWD_UNIT };
enum class AgentOwner : uint8_t { SELF, COORDINATOR };  // who sets preferred velocity

struct Agent {
    AgentId        id;
    AgentKind      kind;
    AgentOwner     owner;
    DomainId       domain;
    NavPos         pos;
    Vector3        velocity, preferredVelocity, desiredVelocity;
    float          radius, height, maxSpeed;
    uint8_t        tier;            // derived from radius at registration
    CapabilityMask capabilities;
    uint32_t       group;           // for coordinator / shared paths
    PathFollower   follower;        // corridor state (unused when owner == COORDINATOR)
    uint32_t       flags;           // NEEDS_REPAIR, ON_LINK, STUCK...
};

class AgentRegistry {
public:
    AgentId add(const AgentParams& p);
    void    remove(AgentId id);
    Agent&  get(AgentId id);
    // bulk access for the coordinator: contiguous arrays, no per-agent calls
    AgentSoAView view();            // positions[], velocities[], radii[], owners[]...
    void    onTileChanged(const TileChanged& e);
};
```

### 13.2 Path following

```cpp
class PathFollower {               // wraps dtPathCorridor
public:
    void setPath(const PathResult& r);
    // Per tick: move corridor start to current position, find next corners,
    // return steering target. Triggers refineAhead when within N tiles of the refined end.
    SteerResult update(const NavPos& pos, float radius, const NavFilter& f);
    // Called when the agent reaches the start of an off-mesh link.
    bool atLinkStart(uint32_t& outLinkId) const;
    void completeLink(bool success); // moveOverOffmeshConnection or replan on failure
};
```

### 13.3 Crowd tick

```cpp
void CrowdSystem::tick(double dt) {
    m_hash.rebuild(m_registry.view());                       // 1. spatial hash (uniform grid)

    for (Agent& a : m_registry.selfOwned()) {                // 2. preferred velocity
        if (a.flags & ON_LINK) continue;                     //    body is doing the link action
        SteerResult s = a.follower.update(a.pos, a.radius, filterFor(a));
        if (s.reachedLink) emitLinkReached(a, s.linkId);     //    -> link_reached signal
        a.preferredVelocity = s.direction * a.maxSpeed * s.arrivalScale;
    }
    // (coordinator-owned agents had preferredVelocity written via bulk API before tick)

    m_avoidance.solve(m_registry.view(), m_hash, m_obstacles, dt); // 3. ORCA, staggered 10–20 Hz
                                                             //    -> desiredVelocity
    for (Agent& a : m_registry.crowdUnits())                 // 4. crowd units move here
        integrateAndClamp(a, dt);                            //    moveAlongSurface keeps them on nav
    // physics pawns read desiredVelocity in their own _physics_process
}
```

---

## 14. Swarm coordinator hooks

The coordinator is game code (C++). These are the hooks it gets. Each was one of the 12 identified earlier.

| # | Hook | Function(s) |
|---|---|---|
| 1 | Agent-independent searches | `NavServer::find_path` / `RequestQueue::push` with `agent = 0` |
| 2 | Filter as data | `NavFilter` is a POD struct; build once, share across a group |
| 3 | Shared request queue | `RequestQueue` (coordinator requests get their own priority band) |
| 4 | Rough corridor access | `HierarchicalPlanner::planCorridorOnly(start, goal, filter) -> TileCorridor` |
| 5 | Read-only versioned span snapshots | `GroundDomain::snapshotSpans(TileKey) -> shared_ptr<const SpanSnapshot>` (for flow fields) |
| 6 | Change events | `EventBus::subscribe(EventType, callback)` — TileChanged, LinkAdded/Removed |
| 7 | Streaming hints | `NavServer::add_interest` / `TileManager::addRouteRef` |
| 8 | Shared agent registry | `AgentRegistry::view()` (SoA arrays) |
| 9 | Ownership flag | `set_agent_owner(id, COORDINATOR)` — crowd skips step 2 for it |
| 10 | Batch avoidance | `ObstacleAvoidance::solve(view, hash, ...)` callable on any subset |
| 11 | Link-reached event with tags | `link_reached` signal / `EventBus` LinkReached |
| 12 | Bulk array APIs | `setPreferredVelocities(span<AgentId>, span<Vector3>)`, `getPositions(...)` |

Plus a convenience service the coordinator will want:

```cpp
class FlowFieldService {
public:
    // Flow field over one tile's cached spans toward a goal (point or exit portal), per tier.
    // Cached by (tile, goal, tier, tileVersion); invalidated by TileChanged.
    std::shared_ptr<const FlowField> get(const TileKey& t, const FlowGoal& g, uint8_t tier);
};
```

---

## 15. Other domains (later phases)

### 15.1 AirDomain (sparse voxel octree)

```cpp
class AirDomain : public INavDomain {
    // build: per tile, octree from the same merged spans (solid ranges per column); air above
    //        the highest solid becomes big empty leaves for free. Dilated by smallest flyer
    //        radius. Only for tiles near flyer interest.
    std::unique_ptr<TileBuildResult> buildTile(const TileBuildInput& in) override;
    // query: A* over empty leaves (cost = distance between leaf centres),
    //        neighbours across chunk faces via TileKey neighbours; then raycast smoothing.
    QueryStatus stepPath(PathJob& job, int maxIterations) override;
};
// Ground<->air links ("take_off", "land"): generated by GroundDomain::generateAutoLinks
// where a span has open sky for >= flyer clearance above it. targetDomain = air.
```

### 15.2 FrameDomain (ships, platforms)

```cpp
class FrameDomain : public INavDomain {
    // Owns its own voxel grid and a transform provider (a Godot Node3D).
    // Internally reuses GroundDomain (and optionally AirDomain) in LOCAL coordinates.
    // NavServer converts world <-> frame-local at the API boundary using the current transform.
    // Board/disembark = cross-domain links whose world-side endpoint moves with the frame;
    // the domain graph re-evaluates those link endpoints each tick.
};
```

### 15.3 SurfaceDomain (wall walkers): graph over voxel faces filtered by face normal. Same interface. Deferred.

---

## 16. Code flow walkthroughs

### A. Startup

```
autoload NavBootstrap._ready()
  └─ NavServer.configure(cfg)                 tiers, cell size, tile size, budgets
terrain generator._ready()   (only if its nav_hooks export is set)
  └─ NavServer.add_input_layer(self, nav_hooks, ADAPTER_HEIGHTMAP) → layer id
       └─ TileManager creates Estimated tiles lazily as interests appear
world_ready (from your scene coordinator)
  └─ player camera: NavServer.add_interest(pos, 128, 160, HIGH)
pawn._ready → NavAgentComponent.activate()
  └─ NavServer.register_agent({radius, height, capabilities, kind=PHYSICS_PAWN})
first ticks: tiles around interest go Estimated → Queued → Building → Ready
```

### B. A chunk streams in

```
terrain finishes generating chunk (3,5); nav_hooks is set →
  NavServer.submit_heightmap(layer, (3,5), heights, size, scale, surfaces)
  └─ InputStore keeps an immutable copy, version++
tick phase 1: TileManager.markDirty(tile(3,5), INPUT_CHANGED)  (+ neighbours' borders;
              provisional neighbours that were waiting on this chunk are re-queued)
tick phase 3: scheduleBuilds → GroundDomain.gatherInput(tile) → InputSnapshot (refs, no copy)
              WorkerPool runs GroundDomain.buildTile(input)          ~1–3 ms, off main thread
tick phase 2 (a later tick): commitFinished → GroundDomain.commitTile
              Detour stitches edges with loaded neighbours automatically
              EventBus: TileChanged → agents waiting near that edge get NEEDS_REPAIR
```

### C. Player digs a voxel under a walking pawn

```
your terrain edit code → re-submits the chunk with dirty_bounds = the edited box
  (or, with a PlayerEdits layer, submits only the edit diff to that layer)
tick 1, phase 1: markDirty(tile) → version 7 → 8. Tile keeps serving version 7.
tick 1, phase 3: dispatched build for version 8
tick 2, phase 2: result.builtFromVersion == 8 == tile.version → commit
                 TileChanged(tile, 7→8) → pawn flagged NEEDS_REPAIR
tick 2, phase 5: CrowdSystem repairs: fixPathStart; the hole made the old poly invalid,
                 so refineFine re-runs for the horizon → new route around the hole.
(If the player had dug twice during the build: the version-8 result is stale at commit,
 discarded; version 9 builds next. No wasted commits, no flicker.)
```

### D. Pawn walks to a target across a gap (the full mind → nav → body loop)

```
Mind (AI behaviour or click): nav_agent.move_to(target)
  └─ NavServer.move_agent_to(agent, target)          → RequestQueue
tick phase 4: HierarchicalPlanner.run
  a. resolveEndpoints  b. same domain, skip  c. L2 A* → corridor of 5 tiles
  d. addRouteRef on 5 tiles   e. Detour sliced search over first 2 tiles
tick phase 6: path_ready → NavAgentComponent stores "moving"
every physics frame:
  NavAgentComponent: NavServer.set_agent_position(...)
                     v = NavServer.get_desired_velocity(agent) → MovementController → move_and_slide
CrowdSystem: follower reaches off-mesh link 41 (tags = jump_gap_2)
  → flags ON_LINK, emits link_reached(agent, 41, ["jump_gap_2"], start, end)
NavAgentComponent._on_link_reached → body.try_action_by_tags(["jump_gap_2"], {start, end})
  → body finds the jump variant whose conditions pass (e.g. actionJump), runs it
  → when the action finishes: NavServer.link_completed(agent, 41, true)
CrowdSystem: follower.completeLink(true) → continues on far side
near end of refined prefix: refineAhead → next 2 tiles refined (budgeted)
```

### E. A crate gets pushed, then settles

```
ObstacleSystem.update: crate moving → AVOID. Agents steer around it via ORCA. No rebuild.
crate still for settleTime (or RigidBody sleeps) → CARVE
  → markDirty(tile, OBSTACLE) → rebuild starts from cached spans (skips extractSpans)
  → commit → paths now route around it from far away
crate kicked again → immediately back to AVOID → markDirty again (uncarve)
```

### F. RTS: 500 units ordered to move

```
game: coordinator.order_move(selection, target)
coordinator: set_agent_owner(all 500, COORDINATOR)
             corridor = planner.planCorridorOnly(groupCentre, target, groupFilter)   (hook 4)
             addRouteRef on corridor tiles                                           (hook 7)
             per corridor tile: FlowFieldService.get(tile, exitPortal, tier)        (hook 5)
each tick, before NavServer.tick:
             coordinator samples flow fields at positions (hook 8) and writes
             setPreferredVelocities(...)                                             (hook 12)
NavServer.tick → CrowdSystem skips step 2 for them, runs ORCA, integrates crowd units
TileChanged on a corridor tile → coordinator drops that tile's flow field and re-requests
units arrive → coordinator hands them back: set_agent_owner(..., SELF)
```

---

## 17. Godot integration (pawn side)

A new pawn component, fitting the nexus / two-phase assembly design. It is the only thing a pawn needs to navigate. Sketch:

```gdscript
## Written by Claude (claude-opus-5-5), 2026-11-02: SKETCH for the spec only. Not a real file yet.
class_name NavAgentComponent extends Node

signal arrived
signal failed(reason)

@export var radius := 0.4
@export var height := 1.8
@export var capabilities : PackedStringArray = ["walk", "jump_gap_2", "step_up_1"]

var agent_id := 0
var _body : Node        # the pawn body; has try_action_by_tags(tags, ctx) -> async result

func setup(context) -> void:          # bind phase: grab references, no side effects
    _body = context.body

func activate() -> void:              # activate phase: register with the nav server
    agent_id = NavServer.register_agent({radius = radius, height = height,
        capabilities = capabilities, kind = "physics_pawn"})
    NavServer.link_reached.connect(_on_link_reached)

func move_to(target: Vector3) -> void:
    NavServer.move_agent_to(agent_id, target)

func desired_velocity() -> Vector3:   # read by the MovementController each physics frame
    NavServer.set_agent_position(agent_id, owner.global_position)
    return NavServer.get_desired_velocity(agent_id)

func _on_link_reached(id, link_id, tags, start, end, payload) -> void:
    if id != agent_id: return
    var ok = await _body.try_action_by_tags(tags, {start = start, end = end, payload = payload})
    NavServer.link_completed(agent_id, link_id, ok)
```

(Real version would route `link_reached` per agent instead of every component filtering a global signal; that's an implementation detail for phase 3.)

**Multiplayer.** AI and nav run on the server (and host). Voxel edits are already replicated by your terrain system; every peer that runs nav rebuilds deterministically from the same voxels, so nav data is never sent over the network. Clients may optionally run nav locally for click-to-move prediction.

---

## 18. Performance budgets (estimates; Phase 0 replaces these)

| Item | Target / estimate |
|---|---|
| `NavServer::tick` main-thread total | ≤ 2 ms at 60 Hz |
| Commit budget per tick | 1 ms (≈ 3–10 tile swaps) |
| Span extraction, 32×32 column tile, blocky | ~10–100 µs |
| Full ground tile build (spans → Detour tile) | ~0.5–3 ms blocky, ~2–10 ms smooth/mesh |
| Re-carve from cached spans | ~0.5–2 ms |
| Coarse L2 search across 50 tiles | ~20–100 µs |
| Detour fine refine (2-tile horizon) | ~10–100 µs |
| Flow field, one 32² tile | ~0.05–0.3 ms |
| ORCA per agent | ~1–5 µs (staggered 10–20 Hz) |
| Memory per Ready tile (polys + spans) | ~70–300 KB |

---

## 19. Build phases (each ends with something you can see in the test scene)

| Phase | Deliverable | Done when |
|---|---|---|
| 0 | Benchmark spike | Recast built as a GDExtension; one heightmap tile built from spans; numbers measured and section 18 updated |
| 1 | Ground domain, static | NavHooks + InputStore + HeightmapAdapter + MeshAdapter + composite; tiles built async; `find_path` works; debug draw of polys and tiers |
| 2 | Dynamic tiles | Edits, streaming interests, versions, atomic swap, LRU; digging under a pawn reroutes it without a hitch |
| 3 | Agents + links | `NavAgentComponent`, path following, auto links → `try_action_by_tags`; a pawn jumps a gap by itself |
| 4 | Crowd + obstacles | ORCA, crowd units, carve/avoid/cost; 1000 crowd units walking at 60 fps |
| 5 | Hierarchy + swarm hooks | L2/L3 graph, estimated tiles, corridor-only queries, flow fields, bulk APIs |
| 6 | Air domain | Flyers path through caves and around towers; take-off/land links |
| 7 | Frame domains | A pawn walks on a moving voxel ship and boards/disembarks |
| 8 | Surface domain | Wall walkers (optional) |

Phases 1–3 are the everyday core. Everything after is additive.

Markers (section 21) aren't a phase of their own, and section 21.10 gives their build order. `NavWorld`, the data classes, `NavMarkerNode`, module base, debug module and report are GDScript and don't need the library, so they can be built at any time. Each other module waits for the system it talks to, as section 21.4 lists. <!-- Claude 2026-11-06 -->

---

## 20. Open questions

1. **Blocky or smooth?** Settled for now: the first generator is a heightmap (`HeightmapAdapter`). When others are added through the same NavHooks seam:
   - **Blocky** (`BlockAdapter`): 3×3 nav cells per voxel column (1 cell per voxel + radius erosion closes 1-wide corridors); step-edge area policy for 1-voxel steps; edits are exact and usually touch 1 tile.
   - **Smooth**: start with `MeshAdapter` on the chunk's collision mesh (exact to collision); add `DensityAdapter` only if that's too slow, and match the mesher's interpolation. Edits touch 2–4 tiles.
2. **Tier radii:** which pawn size classes exist? (e.g. 0.3 / 0.6 / 1.2 / 2.5 m)
3. **Tile vertical bands:** how tall is the world? One band is simplest; bands only matter for very deep caves or tall builds.
4. **Tag budget:** is 64 tags enough for v1, or go 128 from the start?
5. **Link authority:** does the body ever refuse a link mid-way (e.g. stamina)? Then `link_completed(false)` must trigger a replan that excludes that link for a while.
6. **Terrain summary:** what can your terrain generator cheaply say about an ungenerated tile (height range, water, roughness)? Better estimates = better long paths before tiles exist. A heightmap's low-res mip is ideal.
7. **Surface conflicts:** when two layers set different surface types on the same walkable top, the higher `order` wins. Good enough, or do some surfaces need priority (e.g. water always wins)?
8. **Native providers:** should the heightmap's noise function be ported to C++ so workers can evaluate it directly (no submission, free borders), or is GDScript-generate-then-submit fast enough? Measure in phase 0.

---

<!-- Claude 2026-11-06: new section, designed with the owner. Added at the end so existing section numbers stay the same. -->
## 21. Nav markers and modules

**Status:** design agreed with the owner 2026-11-06. Steps 1 to 5 of section 21.10 are built, and step 6 is on hold. Signatures for anything not built are proposals. <!-- Claude 2026-11-06: this line still said not built -->

**Job:** let anything in a level say "this spot or thing means something to nav or AI", such as a ladder, a cover spot or a seat, without the core needing to know every kind.

The usual industry terms are off-mesh link, nav modifier volume, dynamic obstacle, tactical point, point of interest (POI) and smart object. **Not the same as `NavHooks`** (section 5.1), which makes a terrain generator feed nav. Markers are things placed on or in the world.

**Where this differs from older sections, this section wins:**
- Nav has its own tags (`NavTags`, section 21.3). It doesn't share `TagRegistry` with abilities as sections 2, 4 and 10 say.
- Generators announce their own links as markers (section 21.6). This replaces link hints in section 5. `send_link_hints` on `NavHooks` is removed at the next C++ rebuild. Nothing reads that setting today. Auto-generated links, such as step-ups and gaps, stay inside nav.

### 21.1 The parts

The split is the one an entity component system uses: plain data, with separate code acting on it.

| Part | What it is | Job |
|---|---|---|
| `NavWorld` | GDScript autoload, the nav singleton's public layer | The one door for markers, tags, terrain settings and modules. Uses `NavServer` when the library is there |
| `NavMarker` and subclasses | Data objects (`Resource`) | Say what a marker is, when it's registered and for its less-used data |
| `NavMarkerModule` and subclasses | Nodes, added to or left out of each level | All the code for specific kinds of marker |
| `NavMarkerNode` | Thin node | Places a marker by hand. Generators skip it |
| `NavTags` | Static class, like `TagRegistry` | Nav's own tag names and bits |

`NavWorld` is global and belongs to no chunk. Chunks ask it to register things, and what it stores outlives them (section 21.6).

**Without the library,** markers, search, modules and the report all still work, because they're GDScript. Paths and links need `NavServer`, and estimates need the C++ module (section 21.8).

**A marker with no module is harmless.** It's registered and can be searched, and nothing else happens to it, because no code acts on it. The debug report (section 21.7) says so.

### 21.2 Marker data

```gdscript
## SKETCH for the spec only. Not a real file yet.
class_name NavMarker extends Resource

@export var tag: StringName        ## e.g. &"link.jump". Goes through NavTags
@export var radius := 1.0          ## how close counts as "at it"
@export var starts_enabled := true ## false = registered, but not used until switched on

var position := Vector3.ZERO       ## set by NavMarkerNode or the generator before registering
var facing := Vector3.FORWARD      ## for cover direction, seats, and so on
```

A marker is **input**. Registering copies its position, tag and enabled state into `NavWorld`'s rows (section 21.5), so changing those on the object afterwards does nothing. To change one, call `NavWorld.set_enabled(id, value)`. That keeps a single source of truth and lets changes be batched.

Left out of the base on purpose:

| Not in the base | Where it goes instead |
|---|---|
| Cost, shape, link ends | The subclasses that use them |
| Slots, priority | `NavSmartObject`, `NavPoint` |
| Who may use it | The agent's `NavFilter` (capabilities and forbidden tags, section 4) |
| Nav domain | Add when a second domain exists, defaulting to ground |
| Network code | See section 21.9 |

### 21.3 Types and tags

| Class | Industry term | Data beyond the base | Example tags |
|---|---|---|---|
| `NavLink` | Off-mesh link | End point, one or two way, cost, `action_tag` | `link.jump`, `link.climb`, `link.door`, `link.teleport` |
| `NavArea` | Nav modifier volume | Box size, surface name. It names a surface instead of storing a cost, because each kind of agent holds its own cost per surface (`NavFilter`, section 4) | `area.road`, `area.hazard`, `area.water`, `area.forbidden` |
| `NavObstacle` | Dynamic obstacle | Mode: carve, avoid or cost (section 11), box size, cost surface | `obstacle.crate`, `obstacle.vehicle` |
| `NavPoint` | Tactical point, POI | None yet | `point.cover`, `point.patrol`, `point.ambush`, `point.wander` |
| `NavSmartObject` (extends `NavPoint`) | Smart object | Slot count. Who is using it changes during play, so that belongs to its module | `use.seat`, `use.work`, `use.pickup` |

**Rule: a new subclass only when the data differs; a new tag when only the meaning differs.** A ladder, a jump and a teleporter are all `NavLink`. A teleporter isn't called a "portal" here because this spec uses that word for the edge between tiles (section 7).

Types are the guard: `marker is NavLink` works on every marker, generated or hand-placed, and the tag does the finer sorting. Later: `NavPatrolRoute` (an ordered list of points). Spawn points aren't nav markers.

**`NavTags` follows `TagRegistry`'s rules with its own 64 bits and its own declarations file.** Names are dotted, a mask includes its parents' bits, and tags are declared and numbered at startup so every machine agrees. A tag nobody declared gets a one-time warning. `NetworkSession.content_hash` must include it, as it does `TagRegistry`.

**Handing off to the pawn.** A `NavLink` keeps its nav tag for pathfinding, and its `action_tag` (a `TagRegistry` name such as `movement.jump`) says which action plays when the pawn reaches it. A pawn also needs a small table from its abilities to its nav capabilities, which waits for the pawn design.

**Surface types:** 16 is accepted (15 plus the default), and allocating them is the designers' job. Stacking works today through layer `order`, where the higher one wins. Changing a region's surface rebuilds the tiles under it. A mix of two surfaces needs a surface type of its own.

### 21.4 Modules

```gdscript
## SKETCH for the spec only. Not a real file yet.
class_name NavMarkerModule extends Node

## Announces which types this module works on. Subclasses of these count too.
func handled_types() -> Array[Script]:
	return []

# Each is one call per batch, not one per marker. Use NavWorld.get_marker(id) for the data.
func _markers_added(_ids: PackedInt64Array) -> void:
	pass
func _markers_changed(_ids: PackedInt64Array) -> void:
	pass
func _markers_removed(_ids: PackedInt64Array) -> void:
	pass

# _notification runs at every level of inheritance, so a subclass with its own _enter_tree can't stop this.
func _notification(what: int) -> void:
	if what == NOTIFICATION_ENTER_TREE:
		NavWorld.add_module(self)
	elif what == NOTIFICATION_EXIT_TREE:
		NavWorld.remove_module(self)
```

Rules:
1. **Load order doesn't matter.** A module joins on the next tick, so its `_ready` has run first. It's handed every matching marker already applied, and later ones as they arrive. Leaving happens straight away, because the module may not exist by the next tick.
2. **Several modules can handle one type,** such as debug drawing and `NavLinkModule`.
3. **Cleanup covers only a module's own work.** A module tracks what it made and undoes exactly that when it leaves, through a final `_markers_removed`. Markers belong to `NavWorld`, so a module never deletes them, and removing one module can't affect another using the same type.
4. **Only one module does each job on a shared system.** Two modules both adding a marker's link to nav would make two links. Nothing enforces this in tier 0.
5. **Gameplay changes run on the tick,** like everything else (netcode spec section 3).

| Module | Depends on | When |
|---|---|---|
| `NavMarkerDebugModule` | Nothing | First |
| `NavEstimatorModule` (loaded by default, section 21.8) | The library | After the markers |
| `NavLinkModule` (calls `NavServer.add_link`, keeps a link inactive until both ends are loaded) | Agents and links | Phase 3 |
| `NavAreaModule` | Surface input (section 5) | With the first game that needs it |
| `NavObstacleModule` | `ObstacleSystem` | Phase 4 |
| `NavPointModule`, `NavSmartObjectModule` | The AI side of the pawn | With the pawn |

Markers can be placed before their module exists. They just do nothing until then.

### 21.5 NavWorld, and getting ready for C++

```gdscript
## SKETCH for the spec only. Not a real file yet.
func register_terrain(scene_path: String, settings: TerrainSettings) -> int  # returns a terrain id
func unregister_terrain(terrain: int) -> void
func get_terrain_settings(terrain: int) -> TerrainSettings
func chunk_of(terrain: int, position: Vector3) -> Vector2i
func request_markers(terrain: int, chunk: Vector2i, markers: Array[NavMarker]) -> int  # returns how many were accepted
func request_scene_marker(scene_path: String, marker: NavMarker) -> int         # returns the id, 0 if refused
func release_markers(terrain: int, chunk: Vector2i) -> void
func remove_scene_marker(id: int) -> void
func set_enabled(id: int, enabled: bool) -> void
func get_marker(id: int) -> NavMarker
func find_nearest(tag: StringName, from: Vector3, max_distance: float) -> int   # 0 if none
func find_in_radius(tag: StringName, from: Vector3, radius: float) -> PackedInt64Array
func add_module(module: NavMarkerModule) -> void
func remove_module(module: NavMarkerModule) -> void
func print_report() -> void
```

- **Doesn't:** find paths (`NavServer`), decide what a pawn does (AI), or send anything over the network.
- **Searches** skip disabled markers and use a simple grid, so only nearby cells are checked. Equal distances are settled by the lower id, so every machine picks the same marker.
- **Search isn't limited by modules.** AI searches go through the module that needs them, so code that has no module doesn't search.
- **`NavMarkerNode`** copies its marker with `duplicate()` and registers the copy when it enters the scene. **Without this, every copy of a scene shares one marker,** so opening one door would open them all. An empty node or an undeclared tag shows an inspector warning. At runtime, it registers nothing and the game runs. In tier 0, a marker doesn't follow its node if the node moves afterwards. Placement goes through `NavMarker.place_at`, which subclasses can extend, so turning a placed `NavLink` also turns where it ends. Markers can only be seen in a running game for now, because there's no editor gizmo yet.

**C++ later, for truly large games.** The GDScript layer is written so its insides can be replaced without changing anything that calls it. The project already does this with `NetCodec` in C++ and `NetPackets` as the GDScript fallback, and the same plan applies here: a C++ `NavMarkerStore` used when the library has it, with the GDScript as the fallback.

These rules apply from the first line of code:

1. **One door.** Everything outside goes through `NavWorld`'s public functions, and those stay the same when the insides move. Existing code that calls `NavServer` for tiles and paths stays as it is.
2. **Plain types through the door.** Ints, floats, vectors, `StringName`s and packed arrays. Searches return ids, not objects, and `get_marker(id)` fetches the full data only when needed.
3. **Rows, not objects, for what searches read.** Position, tag mask, enabled and type sit in packed arrays (`PackedVector3Array`, `PackedInt64Array`, `PackedByteArray`), one row per marker. Moving this to C++ is then close to retyping it. The `Resource` holds only the less-used data, such as a link's end point.
4. **Batches.** A chunk registers its whole list in one call, and modules get one call per batch. No per-marker signals, because that's the cost that hurts at scale.
5. **No script calls inside loops.** Searches filter by tag mask and distance only, with no callback filters.
6. **Requests apply on the next tick.** A marker isn't searchable until then, even though its id comes back at once. Nothing may rely on it being instant, so the work can later move to other threads without surprises. Tests can call a `flush()`.
7. **Ids come from a hash we write out ourselves** (FNV-1a, over terrain, chunk and index, or over the scene path). Godot's `hash()` could differ from a C++ version, which would change every id.
8. **Tests go through the door only,** so the same tests run on both versions, and a comparison test checks they agree, as `net_codec_selftest` does.

**When to move:** when the test at 100,000 markers or a real profile shows it's worth it. A later option for very large numbers is registering plain points by array with no `Resource` per marker.

### 21.6 Chunks announce their markers

1. A generator gives `NavWorld` a copy of its settings with `register_terrain`. These are plain values: seed, noise settings, chunk size, grid size and height scale. Changing the generator afterwards means registering again.
2. A chunk generates and builds its list of links and POIs, because it knows its own terrain. In `Terrain` this is `_make_chunk_markers(key)`, which a subclass overrides, as with `_shape_height`. By default a chunk has none and pays nothing. The list must come from the chunk's numbers, not random numbers, so every machine gets the same one. `tests/terrain_marker_example.gd` shows how.
3. It calls `request_markers`. `NavWorld` refuses duplicate ids and undeclared tags with a warning, and accepts the rest.
4. When the chunk unloads, the generator calls `release_markers` beside `release_chunk`. Modules clean up through `_markers_removed`.
5. After an edit, a changed chunk announces again, so its markers don't float or get buried. Ids stay the same as long as the list's order does, so an edit should change heights, not the list.

**Terrain ids** come from a hash of the generator's scene path, the same way hand-placed markers get theirs. They match on every machine with nobody choosing a number. Moving or renaming the generator's node changes them.

**Links crossing a chunk border** belong to the chunk holding their start. `NavLinkModule` keeps one inactive until both ends are loaded.

**`NavWorld` keeps what changed.** When a marker from an unloaded chunk had been changed, such as a door being disabled, it keeps that change by id and re-applies it when the chunk announces again. It keeps only changes, not every marker, so memory doesn't grow with the size of the world.

**Terrain settings are used for** ids, knowing which chunk a position is in, and the estimator (section 21.8).

**Chunk size.** About 128 m, as a setting, with chunks loaded around each player. `Terrain`'s defaults are `chunk_size` 128 and `chunk_resolution` 21, which keeps squares of about 6 m, at about 880 triangles a chunk. The owner lowered this from 256 m on 2026-11-06, after the stress test in `docs/streaming/STREAMING_SPEC.md`. <!-- Claude 2026-11-06 --> **Measured 2026-11-06 at 256 m,** with collision and no nav: generating takes 10.7 ms a chunk on Windows and 8.2 ms on Linux, and an edit rebuilding one chunk takes about 8.4 ms and 6.4 ms. Both are on the main thread. An edit is fine now and then, and takes a large share of a 16.7 ms frame if it happens constantly, so a game with constant digging would want smaller chunks. At 1 m squares a chunk has about 131,000 triangles, roughly 35 times the work, so that needs worker threads or smaller chunks. The physics frame's slowdown after an edit (netcode spec section 14.1) isn't included in these times. *Later on 2026-11-06, for chunk streaming:* building meshes from arrays instead of `SurfaceTool` brought these down to 6.3 ms and 4.0 ms on Windows and 5.4 ms and 3.7 ms on Linux, and 128 m chunks came out most comfortable on slower machines, so they became the default. See `docs/streaming/STREAMING_SPEC.md`, which also covers nav across chunk borders.

**Clusters.** A cluster is a group of chunks, the size of a playable area. It's a possible tier above chunks, for things like area settings or grouped saved changes, and isn't being built yet. It can be added later because a chunk's cluster is just its coordinates divided by the cluster size. **Ids and saved data must use chunk coordinates, never cluster ones,** so that adding clusters changes nothing. The name avoids "region", which Recast already uses.

### 21.7 Debug report

`NavWorld` compares each marker's type with what modules announced in `handled_types()`:

```
[NavWorld] no module handles: NavLink (12 markers), NavSmartObject (3 markers)
```

- **When:** after registrations have gone quiet for a couple of seconds, since a module may just not have arrived yet.
- **How often:** once per type. Again only if a type loses its last module or a new unclaimed type appears, so streaming doesn't repeat it.
- **How serious:** a `push_warning`, in debug builds only. It's not an error, and `print_report()` gives the same list on demand.
- **Off switch:** one setting, for games that leave a type unhandled on purpose.

A level with no AI will report `NavPoint`. That's accepted: it's one line, and it's true.

A module that only looks at markers, such as `NavMarkerDebugModule`, returns false from `counts_for_report()`. Otherwise, adding a debug drawing would hide that nothing actually acts on the markers.

### 21.8 Terrain estimates

**Job:** answer "roughly what's in this chunk?" for chunks that haven't generated, so long paths can be planned across them. This is the `estimate` in sections 5 and 9. The word "prediction" is avoided because the netcode spec uses it for something else.

- **Written in C++,** as `NavTerrainEstimator`, so it can run on worker threads.
- **`NavWorld` loads `NavEstimatorModule` onto itself by default at startup.** That thin GDScript module owns the C++ object. If the library is missing, it skips itself with one line in the report, and estimate calls return nothing. A setting turns it off, and a game can replace it.
- **It only works on demand.** It sits idle until a path's goal lies beyond the loaded chunks, then estimates only the unloaded chunks along that route and caches the results. Paths inside the loaded area never touch it, and the trigger is "this chunk isn't loaded" rather than a fixed distance, so it adjusts as the number of loaded chunks changes.
- **Same noise as the generator.** It uses Godot's `FastNoiseLite` with the settings from `register_terrain`.
- **It's only ever approximate.** It can't run a `_shape_height` override, which is GDScript, and it ignores grid jitter and terrain edits. The real chunk always replaces the estimate (provisional tiles, section 9).

```gdscript
## SKETCH for the spec only. Not a real file yet.
func estimate_heights(terrain: int, area: Rect2, samples: Vector2i) -> PackedFloat32Array  # empty if unavailable
func estimate_tile(terrain: int, area: Rect2) -> Dictionary  # height range and steepest slope, empty if unavailable
```

**What uses it:** the coarse planner in phase 5, which isn't built, so until then only its test does. Filling in provisional tile borders may be an earlier use.

**Test:** with no jitter and no override, estimated heights must match `Terrain.height_at`.

### 21.9 Multiplayer

- **Every machine holds the same markers,** from the same level scene and generator seed. A static marker costs no bandwidth.
- **Modules in the level scene mean every machine has the same set.** A mismatch is refused at the handshake, because the content hash covers `.tscn` files, unless a build id replaces the file check (netcode spec, to-do 26). A server-only module is fine for things clients don't simulate, such as AI. Anything a client predicts through, such as links, needs its module on both.
- **A marker that belongs to a networked thing follows it.** A door with a `NetworkEntity` calls `set_enabled` from the door's replicated state.

### 21.10 Build order

1. `NavTags`. **Built 2026-11-06:** `assets/scripts/navigation/NavTags.gd`, with the tier 0 tags declared in `resources/nav_tag_declarations.tres` (22 of the 64 bits). Test: `navigation/tests/nav_tags_selftest`.
2. `NavWorld` core: rows, ids, search and requests, with a test at 100,000 markers. **Built 2026-11-06:** `assets/scripts/singletons/NavWorld.gd`, `navigation/markers/NavMarker.gd`. Test: `navigation/tests/nav_world_selftest`. `register_terrain` and the type row aren't in yet, since nothing uses them until the steps below.
3. Marker subclasses, the module base and the debug report. **Built 2026-11-06:** `navigation/markers/`, `navigation/modules/NavMarkerModule.gd`, and additions to `NavWorld.gd`. Test: `navigation/tests/nav_markers_selftest`. Applying 100,000 markers takes about 48 ms with no modules and 97 ms with two. A module leaving with 100,000 registered takes about 13 ms, because it checks every row.
4. `NavMarkerNode` and `NavMarkerDebugModule`. **Built 2026-11-06:** `navigation/NavMarkerNode.gd`, `navigation/modules/NavMarkerDebugModule.gd`. Sample: `nav_marker_sample.tscn`. Test: `navigation/tests/nav_marker_node_selftest`.
5. `Terrain` registers its settings and announces and releases its chunks' markers, with the new chunk defaults. **Built 2026-11-06:** `terrain/TerrainSettings.gd`, additions to `NavWorld.gd` and `Terrain.gd`. Sample: `terrain_marker_sample.tscn`. Test: `terrain/tests/terrain_markers_selftest`. Streaming now uses this hook: `ChunkStreamer`, in `docs/streaming/STREAMING_SPEC.md`.
6. `NavTerrainEstimator` in C++, and `NavEstimatorModule`. **On hold, the owner's decision 2026-11-06:** its only real user is the coarse planner in phase 5, which isn't built. Build it when something needs it.

**Measured 2026-11-06,** 100,000 markers in 400 chunks of 250, Godot 4.7.2, GDScript:

| | Windows | Linux (WSL2) |
|---|---|---|
| Making the marker objects | 164 ms, 119 MB, about 1,250 bytes each | 158 ms, 121 MB, about 1,270 bytes each |
| Requesting them all | 981 ms, about 2.5 ms a chunk | 784 ms, about 2 ms a chunk |
| Applying them on the tick | 58 ms | 49 ms |
| `NavWorld`'s own memory | 24.8 MB | 24.8 MB |
| `find_nearest`, 500 m reach | 15 µs | 14 µs |
| `find_in_radius`, 50 m | 8 µs | 7 µs |
| `find_nearest`, 20 km reach, nothing to find | 30 ms | 30 ms |
| Releasing them all | 100 ms | 74 ms |

Each other module comes when the system it talks to exists (section 21.4).

### 21.11 Open points

1. **Sending changes to generated markers.** `NavWorld` remembers them across unloads, but a marker with no node has no `NetworkEntity` to carry a change to other machines. This needs the same answer as terrain edits (netcode spec, to-do 18).
2. **The ability-to-capability table.** Waits for the pawn design.
3. **Sharing code with `TagRegistry`.** Settled 2026-11-06: `NavTags` is a separate copy, because `TagRegistry` is working and shouldn't be put at risk for this. A fix to one may need making in the other.
4. **Reusing surface types per level** would need a reset call, because names stay registered once used. `surface_index` also numbers names in the order they first appear, so every machine has to register them in the same order.
5. **Is `FastNoiseLite` safe to call from several threads at once?** Not checked. If it isn't, each worker gets its own copy.
6. **Better estimates** could come from a generator sending a low-resolution height map, which would also cover `_shape_height` overrides (section 20, question 6).
7. **Long searches for rare tags.** A long-reach `find_nearest` for a tag few markers have ends up checking every marker, about 30 ms at 100,000. Normal searches take microseconds. Per-tag cells or a per-tag count would fix it. Wait for a real need.
8. **Memory per marker.** The `Resource` objects cost far more than the rows: about 1,250 bytes each against about 260. That's the strongest case found so far for registering plain points by array in very large games (section 21.5).
9. **Terrain ids.** Settled 2026-11-06: a hash of the generator's scene path (section 21.6).
10. **Hill size at the new chunk size.** The noise defaults (`frequency` 0.015, `height_scale` 12) weren't changed when chunks grew, so hills are small next to a 128 m chunk. That's a look decision for the owner.
