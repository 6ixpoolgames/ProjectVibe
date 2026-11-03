<!-- Written by Claude (claude-opus-5-5), 2026-11-02: design spec for the bespoke voxel-first dynamic navigation system. Nothing here is built yet. -->

# Navigation System Spec (draft 1)

**Status:** design only. No code exists yet. All function signatures are proposals, written as C++ headers (GDExtension, godot-cpp) and a little GDScript for the pawn side.
**Scope:** flat-plane worlds, constant gravity (−Y). Solid spans on the nav grid are the universal input; any terrain generator (heightmap, blocks, density, meshes) opts in through an optional **NavHooks** resource and is stacked with the others (section 5).
**Revisions:** 2026-11-03 (Claude): section 5 rewritten from a single voxel source to the NavHooks / provider model; pipeline, API, walkthroughs and phases updated to match.
**Performance numbers** are ballpark estimates, not measurements. Phase 0 is a benchmark spike to replace them.

How to read this:
- Sections 1–4 are the vocabulary: goals, the moving parts, the threading model, the core types.
- Sections 5–15 go module by module, bottom (voxels) to top (Godot pawns). Each lists its job, its data, and its major functions with what they do.
- Section 16 walks through six concrete scenarios end to end. **If you only read one section to understand the code flow, read 16.**
- Sections 17–19 cover performance budgets, build phases, and open questions.

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
| `TagRegistry` | Maps tag names (`"jump"`, `"door"`) to bits. Shared with the action system. |
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
  0    HeightmapTerrain         ADD      HeightmapAdapter   ground
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
    bool                       partial;    // goal unreachable -> path to closest reachable point
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
