// Written by Claude (claude-opus-5-5), 2026-11-03: shared basic types for the nav core (spec section 4).
// Nothing in here depends on Godot, so worker threads can use all of it safely.
#pragma once

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
	int border_cells() const {
		int a = walkable_radius_cells() + 3;
		int b = int(std::ceil(max_tier_radius() / cell_size)) + 3;
		return a > b ? a : b;
	}
};

} // namespace navcore
