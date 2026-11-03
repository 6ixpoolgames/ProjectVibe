// Written by Claude (claude-opus-5-5), 2026-11-03: ground tile build pipeline, input spans -> Detour tile (spec 8.2).
// Step numbers match the spec. Steps 3 (obstacle carving), 8 (auto links), 10 (portals) and
// 11 (cached spans) belong to later phases and are marked as such below.
#include "ground_builder.h"

#include "providers.h"
#include "span_field.h"

#include <DetourAlloc.h>
#include <DetourNavMesh.h>
#include <DetourNavMeshBuilder.h>
#include <Recast.h>

#include <algorithm>
#include <chrono>
#include <cmath>
#include <vector>

namespace navcore {

TileBuildResult::~TileBuildResult() {
	if (nav_data) {
		dtFree(nav_data);
	}
}

WorldRect tile_world_rect(const NavConfig &cfg, const TileKey &key) {
	const float tw = cfg.tile_world();
	return { key.x * tw, key.z * tw, (key.x + 1) * tw, (key.z + 1) * tw };
}

WorldRect tile_build_rect(const NavConfig &cfg, const TileKey &key) {
	return tile_world_rect(cfg, key).expanded(cfg.border_cells() * cfg.cell_size);
}

namespace {

// Owns the Recast intermediates so every early return frees them.
struct RecastScratch {
	rcHeightfield *hf = nullptr;
	rcCompactHeightfield *chf = nullptr;
	rcContourSet *cset = nullptr;
	rcPolyMesh *pmesh = nullptr;
	rcPolyMeshDetail *dmesh = nullptr;
	~RecastScratch() {
		rcFreeHeightField(hf);
		rcFreeCompactHeightfield(chf);
		rcFreeContourSet(cset);
		rcFreePolyMesh(pmesh);
		rcFreePolyMeshDetail(dmesh);
	}
};

// Step 1b: slope filter. Spans fed in directly (heightmaps) skip Recast's per-triangle slope test,
// so slope is measured here from neighbouring column tops, the same way for every input type.
// A neighbour only counts if its top is within climb height: a bigger jump is a cliff/wall, and
// cliffs are Recast's ledge filter's job, not this one's.
void apply_slope_filter(SpanField &field, const NavConfig &cfg) {
	const float max_grad = std::tan(cfg.max_slope_deg * 3.14159265f / 180.0f);
	const float cliff = cfg.agent_max_climb;
	const float cs = field.cell_size();

	auto neighbour_top = [&](int nx, int nz, float top, float &out) -> bool {
		if (nx < 0 || nz < 0 || nx >= field.width() || nz >= field.depth()) {
			return false;
		}
		bool found = false;
		float best = 0.0f;
		for (const Span &s : field.column(nx, nz)) {
			if (!found || std::fabs(s.y1 - top) < std::fabs(best - top)) {
				best = s.y1;
				found = true;
			}
		}
		if (!found || std::fabs(best - top) > cliff) {
			return false;
		}
		out = best;
		return true;
	};
	auto gradient = [&](bool has_lo, float lo, bool has_hi, float hi, float top) -> float {
		if (has_lo && has_hi) {
			return (hi - lo) / (2.0f * cs);
		}
		if (has_hi) {
			return (hi - top) / cs;
		}
		if (has_lo) {
			return (top - lo) / cs;
		}
		return 0.0f;
	};

	// Decide first, then apply, so the result doesn't depend on scan order.
	std::vector<std::pair<int, size_t>> too_steep; // (column index, span index)
	for (int cz = 0; cz < field.depth(); ++cz) {
		for (int cx = 0; cx < field.width(); ++cx) {
			const std::vector<Span> &col = field.column(cx, cz);
			for (size_t i = 0; i < col.size(); ++i) {
				if (col[i].surface == SURFACE_NONE) {
					continue;
				}
				const float top = col[i].y1;
				float l = 0, r = 0, d = 0, u = 0;
				const bool hl = neighbour_top(cx - 1, cz, top, l);
				const bool hr = neighbour_top(cx + 1, cz, top, r);
				const bool hd = neighbour_top(cx, cz - 1, top, d);
				const bool hu = neighbour_top(cx, cz + 1, top, u);
				const float gx = gradient(hl, l, hr, r, top);
				const float gz = gradient(hd, d, hu, u, top);
				if (std::sqrt(gx * gx + gz * gz) > max_grad) {
					too_steep.emplace_back(cx + cz * field.width(), i);
				}
			}
		}
	}
	for (const auto &p : too_steep) {
		field.column(p.first % field.width(), p.first / field.width())[p.second].surface = SURFACE_NONE;
	}
}

// Step 6: clearance tiers. Writes the tier into area bits 5..4 before regions are built, so
// regions (and therefore polygons) split along tier boundaries.
//
// Recast's distance field treats a change of area id as a wall (road next to grass would look
// like an obstacle). So: temporarily make every walkable span the same area, build the distance
// field, compute tiers from it, then put the real surface types back with the tier bits added.
// The distance field stays in chf for rcBuildRegions, which wants it anyway.
bool compute_clearance_tiers(rcContext &ctx, const NavConfig &cfg, rcCompactHeightfield &chf) {
	std::vector<unsigned char> saved(chf.areas, chf.areas + chf.spanCount);
	for (int i = 0; i < chf.spanCount; ++i) {
		if (chf.areas[i] != RC_NULL_AREA) {
			chf.areas[i] = 1;
		}
	}
	if (!rcBuildDistanceField(&ctx, chf)) {
		return false;
	}
	// chf.dist is in half-cells (orthogonal step = 2), measured from the eroded edge. The erosion
	// already removed walkable_radius_cells of space, so add that back to get real clearance.
	const float eroded = cfg.walkable_radius_cells() * cfg.cell_size;
	for (int i = 0; i < chf.spanCount; ++i) {
		if (saved[size_t(i)] == RC_NULL_AREA) {
			chf.areas[i] = RC_NULL_AREA;
			continue;
		}
		const float clearance = chf.dist[i] * 0.5f * cfg.cell_size + eroded;
		int tier = 0;
		for (int t = 1; t < cfg.tier_count; ++t) {
			if (clearance >= cfg.tier_radii[t]) {
				tier = t;
			}
		}
		chf.areas[i] = make_area(tier, area_surface(saved[size_t(i)]));
	}
	return true;
}

} // namespace

std::unique_ptr<TileBuildResult> build_ground_tile(const TileBuildInput &in) {
	using Clock = std::chrono::steady_clock;
	const auto t0 = Clock::now();

	auto result = std::make_unique<TileBuildResult>();
	result->key = in.key;
	result->version = in.version;
	result->generation = in.generation;

	const NavConfig &cfg = in.cfg;
	const int border = cfg.border_cells();
	const int size = cfg.tile_size_cells + 2 * border;
	const WorldRect build = tile_build_rect(cfg, in.key);
	auto finish = [&]() {
		result->build_ms = std::chrono::duration<double, std::milli>(Clock::now() - t0).count();
		return std::move(result);
	};

	rcContext ctx(false);
	RecastScratch rs;

	// ---- 1. Inputs -> spans, every layer in order through the composite. Then the slope filter.
	SpanField field;
	field.reset(size, size, build.min_x, build.min_z, cfg.cell_size);
	CompositeProvider composite;
	result->provisional = !composite.fill_spans(in.snapshot, field, FillContext{ cfg, &ctx });
	apply_slope_filter(field, cfg);

	// Hand the composited spans to Recast.
	rs.hf = rcAllocHeightfield();
	const float bmin[3] = { build.min_x, cfg.world_floor_y, build.min_z };
	const float bmax[3] = { build.max_x, cfg.world_ceiling_y, build.max_z };
	if (!rs.hf || !rcCreateHeightfield(&ctx, *rs.hf, size, size, bmin, bmax, cfg.cell_size, cfg.cell_height)) {
		result->error = "rcCreateHeightfield failed";
		return finish();
	}
	const int climb = cfg.walkable_climb_cells();
	bool any_span = false;
	for (int cz = 0; cz < size; ++cz) {
		for (int cx = 0; cx < size; ++cx) {
			for (const Span &s : field.column(cx, cz)) {
				int smin = int(std::floor((s.y0 - cfg.world_floor_y) / cfg.cell_height));
				int smax = int(std::ceil((s.y1 - cfg.world_floor_y) / cfg.cell_height));
				smin = std::clamp(smin, 0, RC_SPAN_MAX_HEIGHT - 1);
				smax = std::clamp(smax, smin + 1, RC_SPAN_MAX_HEIGHT);
				rcAddSpan(&ctx, *rs.hf, cx, cz, (unsigned short)smin, (unsigned short)smax, s.surface, climb);
				any_span = true;
			}
		}
	}
	if (!any_span) {
		result->empty = true;
		return finish();
	}

	// ---- 2. (Spec step 3) Carved obstacles: phase 4.

	// ---- 3. Standard Recast filters.
	const int walkable_height = cfg.walkable_height_cells();
	rcFilterLowHangingWalkableObstacles(&ctx, climb, *rs.hf);
	rcFilterLedgeSpans(&ctx, walkable_height, climb, *rs.hf);
	rcFilterWalkableLowHeightSpans(&ctx, walkable_height, *rs.hf);

	// ---- 4. Compact heightfield, eroded by the SMALLEST pawn's radius.
	rs.chf = rcAllocCompactHeightfield();
	if (!rs.chf || !rcBuildCompactHeightfield(&ctx, walkable_height, climb, *rs.hf, *rs.chf)) {
		result->error = "rcBuildCompactHeightfield failed";
		return finish();
	}
	rcFreeHeightField(rs.hf);
	rs.hf = nullptr;
	if (!rcErodeWalkableArea(&ctx, cfg.walkable_radius_cells(), *rs.chf)) {
		result->error = "rcErodeWalkableArea failed";
		return finish();
	}

	// ---- 5. Surface types were written by the providers in step 1 (area bits 3..0).

	// ---- 6. Clearance tiers -> area bits 5..4.
	if (!compute_clearance_tiers(ctx, cfg, *rs.chf)) {
		result->error = "rcBuildDistanceField failed";
		return finish();
	}

	// ---- 7. Regions, contours, polygons, detail mesh (standard Recast).
	const int min_area = int(cfg.region_min_size * cfg.region_min_size);
	const int merge_area = int(cfg.region_merge_size * cfg.region_merge_size);
	if (!rcBuildRegions(&ctx, *rs.chf, border, min_area, merge_area)) {
		result->error = "rcBuildRegions failed";
		return finish();
	}
	rs.cset = rcAllocContourSet();
	if (!rs.cset || !rcBuildContours(&ctx, *rs.chf, cfg.edge_max_error, int(cfg.edge_max_len / cfg.cell_size), *rs.cset)) {
		result->error = "rcBuildContours failed";
		return finish();
	}
	rs.pmesh = rcAllocPolyMesh();
	if (!rs.pmesh || !rcBuildPolyMesh(&ctx, *rs.cset, DT_VERTS_PER_POLYGON, *rs.pmesh)) {
		result->error = "rcBuildPolyMesh failed";
		return finish();
	}
	if (rs.pmesh->npolys == 0) {
		result->empty = true;
		return finish();
	}
	rs.dmesh = rcAllocPolyMeshDetail();
	const float sample_dist = cfg.detail_sample_dist < 0.9f ? 0.0f : cfg.cell_size * cfg.detail_sample_dist;
	const float sample_err = cfg.cell_height * cfg.detail_sample_max_error;
	if (!rs.dmesh || !rcBuildPolyMeshDetail(&ctx, *rs.pmesh, *rs.chf, sample_dist, sample_err, *rs.dmesh)) {
		result->error = "rcBuildPolyMeshDetail failed";
		return finish();
	}

	// Poly flags from the tier in each poly's area (see tier_flag in nav_types.h).
	for (int i = 0; i < rs.pmesh->npolys; ++i) {
		const unsigned char area = rs.pmesh->areas[i];
		unsigned short flags = 0;
		if (area != RC_NULL_AREA) {
			flags = POLYFLAG_WALK;
			for (int t = 1; t <= area_tier(area); ++t) {
				flags |= tier_flag(t);
			}
		}
		rs.pmesh->flags[i] = flags;
	}

	// ---- 8. (Spec step 8) Auto links: phase 3.

	// ---- 9. Pack the Detour tile.
	dtNavMeshCreateParams params = {};
	params.verts = rs.pmesh->verts;
	params.vertCount = rs.pmesh->nverts;
	params.polys = rs.pmesh->polys;
	params.polyAreas = rs.pmesh->areas;
	params.polyFlags = rs.pmesh->flags;
	params.polyCount = rs.pmesh->npolys;
	params.nvp = rs.pmesh->nvp;
	params.detailMeshes = rs.dmesh->meshes;
	params.detailVerts = rs.dmesh->verts;
	params.detailVertsCount = rs.dmesh->nverts;
	params.detailTris = rs.dmesh->tris;
	params.detailTriCount = rs.dmesh->ntris;
	params.walkableHeight = cfg.agent_height;
	params.walkableRadius = cfg.agent_radius;
	params.walkableClimb = cfg.agent_max_climb;
	params.tileX = in.key.x;
	params.tileY = in.key.z;
	params.tileLayer = 0;
	rcVcopy(params.bmin, rs.pmesh->bmin);
	rcVcopy(params.bmax, rs.pmesh->bmax);
	params.cs = cfg.cell_size;
	params.ch = cfg.cell_height;
	params.buildBvTree = true;
	if (!dtCreateNavMeshData(&params, &result->nav_data, &result->nav_data_size)) {
		result->error = "dtCreateNavMeshData failed";
		return finish();
	}
	result->poly_count = rs.pmesh->npolys;

	// ---- 10. (Spec step 10) Portals for the coarse graph: phase 5.
	// ---- 11. (Spec step 11) Cached spans for fast obstacle re-carving: phase 4.
	return finish();
}

} // namespace navcore
