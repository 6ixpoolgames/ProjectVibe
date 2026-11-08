// Written by Claude (claude-opus-5-5), 2026-11-03: ground tile build pipeline, input spans -> Detour tile (spec 8.2).
// Step numbers match the spec. Steps 3 (obstacle carving), 10 (portals) and 11 (cached spans) belong to later phases and are
// marked as such below. Claude 2026-11-08: step 8 (links, placed and found automatically) is built, for phase 3.
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
#include <unordered_set>
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

// Claude 2026-11-08: step 8, auto links. Finds where a pawn could drop off a ledge or jump a gap, from the compact heightfield
// this build already made, so it costs nothing extra to gather. The same idea as Unreal's and Unity's link generators.
//
// For each walkable span inside the tile (not the borrowed border, which belongs to the neighbour), in each of the 4 directions:
//   1. Walk outward through the strip that erosion and the ledge filter made unwalkable. If the walkable area just continues,
//      this span isn't at an edge. If the spans stop (no connection), there's an edge there.
//   2. Look further out, column by column, up to link_reach_cells, for a walkable span to land on: no higher than
//      link_jump_height above, and no lower than link_drop_height below.
//   3. Check the columns in between hold nothing solid above the higher end, where the jump has to pass.
//   4. A landing lower down and within link_drop_reach is a DROP: walk off. Anything else is a JUMP.
// Links are one way. Each side of a gap finds its own, so a level gap ends up with one each way, and a ledge gets a drop down
// from the top and a jump up from the bottom if it's low enough.
//
// Only spans the compact heightfield keeps are seen. Steep slopes and walls aren't in it, so a column with no spans counts as
// open air. That can let a link through over a steep obstacle; walls with a flat top are seen and do block.
void find_auto_links(const rcCompactHeightfield &chf, const NavConfig &cfg, std::vector<LinkDef> &out) {
	constexpr size_t MAX_AUTO_LINKS_PER_TILE = 256;
	const int w = chf.width;
	const int h = chf.height;
	const int border = cfg.border_cells();
	const float cs = chf.cs;
	const float ch = chf.ch;
	const float climb = cfg.agent_max_climb;
	const int max_inward = cfg.link_rim_cells(); // erosion, plus the ledge filter's cell, plus a little slack
	const int reach = cfg.link_reach_cells();
	const int drop_reach = int(std::ceil(cfg.link_drop_reach / cs)) + cfg.link_rim_cells(); // edge to edge, plus the landing's rim
	const int spacing = std::max(1, int(std::lround(cfg.link_spacing / cs)));
	const float clearance = 1.0f; // room needed above the higher end, for the arc of a jump

	auto top_of = [&](const rcCompactSpan &s) { return chf.bmin[1] + float(s.y) * ch; };
	// Is there anything solid between heights low and high in this column? Solid is what lies below each span's floor and above
	// the open space under the next span.
	auto blocked = [&](int x, int z, float low, float high) {
		const rcCompactCell &c = chf.cells[x + z * w];
		float open_from = -1.0e30f;
		for (unsigned int j = c.index; j < c.index + c.count; ++j) {
			const float floor_y = top_of(chf.spans[j]);
			if (open_from < high && floor_y > low) {
				return true; // solid from open_from up to floor_y overlaps low..high
			}
			open_from = floor_y + float(chf.spans[j].h) * ch;
		}
		// Above the last span: Recast stores 255 when the open space is that tall or has no ceiling at all, so anything less is
		// a real ceiling.
		if (c.count > 0 && chf.spans[c.index + c.count - 1].h < 255 && open_from < high) {
			return true;
		}
		return false;
	};

	std::unordered_set<uint64_t> taken; // one link per square, direction and kind
	for (int z = border; z < h - border; ++z) {
		for (int x = border; x < w - border; ++x) {
			const rcCompactCell &cell = chf.cells[x + z * w];
			for (unsigned int i = cell.index; i < cell.index + cell.count; ++i) {
				if (chf.areas[i] == RC_NULL_AREA) {
					continue;
				}
				const float start_top = top_of(chf.spans[i]);
				for (int dir = 0; dir < 4; ++dir) {
					// 1. Find the edge.
					int ex = x, ez = z;
					unsigned int si = i;
					bool at_edge = false;
					for (int step = 0; step <= max_inward; ++step) {
						const rcCompactSpan &cur = chf.spans[si];
						if (rcGetCon(cur, dir) == RC_NOT_CONNECTED) {
							at_edge = true;
							break;
						}
						const int nx = ex + rcGetDirOffsetX(dir);
						const int nz = ez + rcGetDirOffsetY(dir);
						const unsigned int ni = chf.cells[nx + nz * w].index + unsigned(rcGetCon(cur, dir));
						if (chf.areas[ni] != RC_NULL_AREA) {
							break; // walkable again: this span isn't the last one before an edge
						}
						ex = nx;
						ez = nz;
						si = ni;
					}
					if (!at_edge) {
						continue;
					}
					// 2. Look for a landing.
					int land_k = -1;
					float land_top = 0.0f;
					for (int k = 1; k <= reach; ++k) {
						const int lx = ex + rcGetDirOffsetX(dir) * k;
						const int lz = ez + rcGetDirOffsetY(dir) * k;
						if (lx < 0 || lz < 0 || lx >= w || lz >= h) {
							break;
						}
						const rcCompactCell &lc = chf.cells[lx + lz * w];
						float best = 0.0f;
						bool found = false;
						for (unsigned int j = lc.index; j < lc.index + lc.count; ++j) {
							const float t = top_of(chf.spans[j]);
							const float rise = t - start_top;
							if (chf.areas[j] == RC_NULL_AREA || rise > cfg.link_jump_height || rise < -cfg.link_drop_height) {
								continue;
							}
							if (!found || t > best) {
								best = t; // the highest place to land, so a bridge wins over the ground under it
								found = true;
							}
						}
						if (found) {
							land_k = k;
							land_top = best;
							break;
						}
						// Nowhere to land here. Something solid higher than a jump is a wall, and the search stops at it. Lower solid,
						// such as the unwalkable rim of a ledge it could jump onto, doesn't stop it.
						if (blocked(lx, lz, start_top + cfg.link_jump_height, start_top + cfg.link_jump_height + clearance)) {
							break;
						}
					}
					if (land_k < 0) {
						continue;
					}
					// 3. Nothing in the way. A jump clears both its ends, so only solid above the higher end, by more than a climb,
					// gets in the way. The rim of the ledge being landed on, or a pit's floor, doesn't.
					const float low = std::fmax(start_top, land_top) + climb;
					const float high = std::fmax(start_top, land_top) + clearance;
					bool clear = true;
					for (int k = 1; k < land_k && clear; ++k) {
						clear = !blocked(ex + rcGetDirOffsetX(dir) * k, ez + rcGetDirOffsetY(dir) * k, low, high);
					}
					if (!clear) {
						continue;
					}
					// 4. Which kind, and one per square.
					const bool drop = land_top < start_top - climb && land_k <= drop_reach;
					const AutoLinkKind kind = drop ? AutoLinkKind::DROP : AutoLinkKind::JUMP;
					const uint64_t key = (uint64_t(x / spacing) << 40) | (uint64_t(z / spacing) << 16) | (uint64_t(dir) << 4) | uint64_t(kind);
					if (!taken.insert(key).second) {
						continue;
					}
					const int lx = ex + rcGetDirOffsetX(dir) * land_k;
					const int lz = ez + rcGetDirOffsetY(dir) * land_k;
					LinkDef link;
					link.start[0] = chf.bmin[0] + (float(x) + 0.5f) * cs;
					link.start[1] = start_top;
					link.start[2] = chf.bmin[2] + (float(z) + 0.5f) * cs;
					link.end[0] = chf.bmin[0] + (float(lx) + 0.5f) * cs;
					link.end[1] = land_top;
					link.end[2] = chf.bmin[2] + (float(lz) + 0.5f) * cs;
					link.two_way = false;
					link.id = auto_link_id(kind);
					out.push_back(link);
					if (out.size() >= MAX_AUTO_LINKS_PER_TILE) {
						return;
					}
				}
			}
		}
	}
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

	// ---- 8. Links. Claude 2026-11-08: placed links that start in this tile, plus the ones found at ledges and gaps (phase 3).
	std::vector<LinkDef> links = in.placed_links;
	const size_t placed_count = links.size();
	if (cfg.auto_links) {
		find_auto_links(*rs.chf, cfg, links);
	}
	std::vector<float> link_verts;
	std::vector<float> link_radii;
	std::vector<unsigned short> link_flags;
	std::vector<unsigned char> link_areas;
	std::vector<unsigned char> link_dirs;
	std::vector<unsigned int> link_ids;
	// How close a link's ends must be to the nav mesh for Detour to join them to it, sideways. Up and down it allows the climb.
	const float link_radius = std::fmax(cfg.agent_radius, 2.0f * cfg.cell_size);
	for (const LinkDef &link : links) {
		link_verts.insert(link_verts.end(), link.start, link.start + 3);
		link_verts.insert(link_verts.end(), link.end, link.end + 3);
		link_radii.push_back(link_radius);
		link_flags.push_back(POLYFLAG_WALK | POLYFLAG_LINK); // tier 0 only for now, and excludable as a link
		link_areas.push_back(make_area(0, SURFACE_DEFAULT));
		link_dirs.push_back(link.two_way ? DT_OFFMESH_CON_BIDIR : 0);
		link_ids.push_back(link.id);
	}

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
	// Claude 2026-11-08: the links from step 8. Detour keeps only those whose start lies inside this tile.
	params.offMeshConCount = int(links.size());
	if (!links.empty()) {
		params.offMeshConVerts = link_verts.data();
		params.offMeshConRad = link_radii.data();
		params.offMeshConFlags = link_flags.data();
		params.offMeshConAreas = link_areas.data();
		params.offMeshConDir = link_dirs.data();
		params.offMeshConUserID = link_ids.data();
	}
	if (!dtCreateNavMeshData(&params, &result->nav_data, &result->nav_data_size)) {
		result->error = "dtCreateNavMeshData failed";
		return finish();
	}
	result->poly_count = rs.pmesh->npolys;
	result->link_count = int(links.size());
	result->auto_link_count = int(links.size() - placed_count);

	// ---- 10. (Spec step 10) Portals for the coarse graph: phase 5.
	// ---- 11. (Spec step 11) Cached spans for fast obstacle re-carving: phase 4.
	return finish();
}

} // namespace navcore
