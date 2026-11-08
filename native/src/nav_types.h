// Written by Claude (claude-opus-5-5), 2026-11-03: shared basic types for the nav core (spec section 4).
// Nothing in here depends on Godot, so worker threads can use all of it safely.
#pragma once

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstddef>

namespace navcore {

using Version = uint64_t; // never repeats within a session, so a stale build can always be detected

// Grid coordinate of a tile (and of a heightmap chunk, which uses the same struct).
// The spec's TileKey also has a domain and a vertical band. v1 has one ground domain and one band,
// so those fields are left out until a second domain exists.
struct TileKey {
	int32_t x = 0;
	int32_t z = 0;
	bool operator==(const TileKey &o) const { return x == o.x && z == o.z; }
};

struct TileKeyHash {
	size_t operator()(const TileKey &k) const {
		return (size_t(uint32_t(k.x)) * 73856093u) ^ (size_t(uint32_t(k.z)) * 19349663u);
	}
};

// Axis-aligned rectangle on the XZ plane, in world units.
struct WorldRect {
	float min_x = 0, min_z = 0, max_x = 0, max_z = 0;

	bool overlaps(const WorldRect &o) const {
		return min_x < o.max_x && max_x > o.min_x && min_z < o.max_z && max_z > o.min_z;
	}
	WorldRect expanded(float d) const { return { min_x - d, min_z - d, max_x + d, max_z + d }; }
	void include(const WorldRect &o) {
		min_x = std::fmin(min_x, o.min_x);
		min_z = std::fmin(min_z, o.min_z);
		max_x = std::fmax(max_x, o.max_x);
		max_z = std::fmax(max_z, o.max_z);
	}
};

// ---- area ids (spec section 4) ---------------------------------------------------------------
// Detour gives each polygon a 6-bit area id. We split it:
//   bits 5..4 = clearance tier (0..3)
//   bits 3..0 = surface type   (0..15)
// Surface 0 means "solid but not walkable", so area 0 stays Recast's RC_NULL_AREA.
// Usable surfaces are 1..15; 1 is the default walkable surface.
constexpr uint8_t SURFACE_NONE = 0;
constexpr uint8_t SURFACE_DEFAULT = 1;
constexpr int MAX_SURFACES = 16;
constexpr int MAX_TIERS = 4;
constexpr int MAX_SPAN_CELLS = 8191; // Recast's RC_SPAN_MAX_HEIGHT: vertical cells per column

inline uint8_t make_area(int tier, uint8_t surface) { return uint8_t((tier << 4) | (surface & 0x0F)); }
inline int area_tier(uint8_t area) { return area >> 4; }
inline uint8_t area_surface(uint8_t area) { return area & 0x0F; }

// ---- polygon flags ---------------------------------------------------------------------------
// Detour's filter accepts a polygon if (poly.flags & includeFlags) != 0, i.e. "any of these bits".
// So every walkable poly gets WALK, plus one bit for each tier it satisfies (tier 2 poly = WALK|T1|T2).
// A filter for tier N then includes just the bit for tier N.
constexpr uint16_t POLYFLAG_WALK = 1 << 0;
inline uint16_t tier_flag(int tier) { return tier <= 0 ? POLYFLAG_WALK : uint16_t(1u << tier); }
// Claude 2026-11-08: every link (Detour's off-mesh connection) also has this bit, so a search can leave links out by excluding it.
// Bits 1..3 are the tiers above.
constexpr uint16_t POLYFLAG_LINK = 1 << 4;

// ---- links (spec section 10, phase 3) --------------------------------------------------------
// Claude 2026-11-08: a link joins two points nav can't walk between, such as either side of a gap. Detour stores each one in the
// tile holding its start, so a link only works while that tile is built, and only reaches its end while the end's tile is too.
//
// Each link has a 32-bit id that comes back with a path. Placed links get ids counting up from 1. Links the tile build finds by
// itself have the top bit set and their kind in the low bits, because nothing outside needs to tell two of them apart.
constexpr uint32_t LINK_ID_AUTO = 0x80000000u;
enum class AutoLinkKind : uint32_t {
	DROP = 1, // off a ledge onto lower ground close by: walk off it
	JUMP = 2, // across a gap, or up onto a ledge: jump
};
inline bool link_id_is_auto(uint32_t id) { return (id & LINK_ID_AUTO) != 0; }
inline uint32_t auto_link_id(AutoLinkKind kind) { return LINK_ID_AUTO | uint32_t(kind); }

struct LinkDef {
	float start[3] = {};
	float end[3] = {};
	bool two_way = false;
	uint32_t id = 0;
};

// ---- configuration ---------------------------------------------------------------------------
struct NavConfig {
	// The grid every input layer is sampled on. Set by the SMALLEST pawn (spec section 1, goal 2).
	float cell_size = 0.2f; // horizontal, about 1/2..1/3 of the smallest agent radius
	float cell_height = 0.1f; // vertical
	int tile_size_cells = 64; // tile edge in cells (64 * 0.2 = 12.8 m)

	// Smallest pawn.
	float agent_height = 1.8f;
	float agent_radius = 0.3f;
	float agent_max_climb = 0.4f;
	float max_slope_deg = 45.0f;

	// Clearance tiers: tier t = "at least tier_radii[t] of space around this spot".
	// tier_radii[0] is always the smallest pawn's radius.
	float tier_radii[MAX_TIERS] = { 0.3f, 0.6f, 1.0f, 1.5f };
	int tier_count = 4;

	// Vertical range of the world. (ceiling - floor) / cell_height must stay under 8191 (Recast limit).
	float world_floor_y = -200.0f;
	float world_ceiling_y = 600.0f;

	// Budgets.
	float commit_budget_ms = 1.0f;
	int max_builds_in_flight = 8;
	int worker_threads = 0; // 0 = number of CPU cores - 1
	int query_iterations_per_tick = 2000;

	// Recast polygon settings (same meaning as in the Recast demo).
	float region_min_size = 8.0f;
	float region_merge_size = 20.0f;
	float edge_max_len = 12.0f;
	float edge_max_error = 1.3f;
	float detail_sample_dist = 6.0f;
	float detail_sample_max_error = 1.0f;

	// Claude 2026-11-08: links the tile build finds by itself at ledges and gaps (spec section 8.2, step 8). The defaults suit the
	// t0 pawn: Jump's 5 m/s gives a jump about 1.27 m high, and walking at 5 m/s covers about 5 m in the air, so these leave room.
	bool auto_links = true;
	float link_jump_distance = 2.0f; // widest gap to jump, edge to edge. Each extra metre widens every tile's border by 1 m
	float link_jump_height = 1.0f; // highest ledge to jump up onto
	float link_drop_height = 4.0f; // furthest drop off a ledge
	float link_drop_reach = 1.0f; // lower ground this close to the ledge, edge to edge, is a drop (walk off); further is a jump
	float link_spacing = 1.6f; // at most one link of each kind and direction per square this wide

	// ---- derived values ----
	float tile_world() const { return tile_size_cells * cell_size; }
	int walkable_height_cells() const { return int(std::ceil(agent_height / cell_height)); }
	int walkable_climb_cells() const { return int(std::floor(agent_max_climb / cell_height)); }
	int walkable_radius_cells() const { return int(std::ceil(agent_radius / cell_size)); }
	float max_tier_radius() const { return tier_radii[tier_count - 1]; }

	// Border = cells borrowed from neighbouring tiles. It must be wide enough that:
	//  - Recast's erosion and region building see across the seam (radius + 3, as in the Recast demo)
	//  - the clearance distance field can "see" the biggest tier radius past the tile edge.
	//    Otherwise tiers would be capped at tile seams and big pawns couldn't cross them.
	//  - Claude 2026-11-08: with auto links on, a ledge at the tile's edge can see a landing a full jump away, past the edge.
	int border_cells() const {
		int a = walkable_radius_cells() + 3;
		int b = int(std::ceil(max_tier_radius() / cell_size)) + 3;
		int c = auto_links ? link_reach_cells() + link_rim_cells() : 0;
		return std::max(a, std::max(b, c));
	}
	// Claude 2026-11-08: how far past a ledge, in cells, the build looks for somewhere to land. The gap itself, plus the strip
	// on each side that isn't walkable: the ledge's own cell and the erosion by the pawn's radius.
	int link_reach_cells() const {
		return int(std::ceil(std::fmax(link_jump_distance, link_drop_reach) / cell_size)) + link_rim_cells();
	}
	int link_rim_cells() const { return walkable_radius_cells() + 3; }
};

} // namespace navcore
