// Written by Claude (claude-opus-5-5), 2026-11-03: the live ground nav mesh: commit, unload, queries, debug (spec 8.3, 12).
#include "ground_domain.h"

#include <DetourCommon.h>
#include <DetourNavMesh.h>
#include <DetourNavMeshQuery.h>

#include <algorithm>

static_assert(sizeof(dtPolyRef) == 8, "build with DT_POLYREF64 (see SConstruct)");

namespace navcore {

namespace {
constexpr int MAX_PATH_POLYS = 4096;
constexpr int MAX_STRAIGHT = 1024;
constexpr int MAX_QUERY_NODES = 8192;
const float SNAP_EXTENTS[3] = { 2.0f, 4.0f, 2.0f }; // how far from the nav mesh a start/goal may be
} // namespace

GroundDomain::GroundDomain() {
	m_filters = new dtQueryFilter[MAX_TIERS];
	for (int t = 0; t < MAX_TIERS; ++t) {
		m_filters[t].setIncludeFlags(tier_flag(t));
		m_filters[t].setExcludeFlags(0);
	}
}

GroundDomain::~GroundDomain() {
	dtFreeNavMeshQuery(m_sync_query);
	dtFreeNavMeshQuery(m_sliced_query);
	dtFreeNavMesh(m_mesh);
	delete[] m_filters;
}

bool GroundDomain::init(const NavConfig &cfg) {
	dtFreeNavMeshQuery(m_sync_query);
	dtFreeNavMeshQuery(m_sliced_query);
	dtFreeNavMesh(m_mesh);
	m_sync_query = m_sliced_query = nullptr;
	m_mesh = nullptr;
	m_cfg = cfg;

	dtNavMeshParams params = {};
	params.orig[0] = params.orig[1] = params.orig[2] = 0.0f;
	params.tileWidth = cfg.tile_world();
	params.tileHeight = cfg.tile_world();
	params.maxTiles = 16384; // tiles loaded at the same time, not the world size
	params.maxPolys = 1 << 15; // per tile
	m_mesh = dtAllocNavMesh();
	if (!m_mesh || dtStatusFailed(m_mesh->init(&params))) {
		dtFreeNavMesh(m_mesh);
		m_mesh = nullptr;
		return false;
	}
	m_sync_query = dtAllocNavMeshQuery();
	m_sliced_query = dtAllocNavMeshQuery();
	if (!m_sync_query || !m_sliced_query || dtStatusFailed(m_sync_query->init(m_mesh, MAX_QUERY_NODES)) ||
			dtStatusFailed(m_sliced_query->init(m_mesh, MAX_QUERY_NODES))) {
		return false;
	}
	m_polys.resize(MAX_PATH_POLYS);
	return true;
}

bool GroundDomain::commit_tile(TileBuildResult &r) {
	if (!m_mesh) {
		return false;
	}
	// Detour stitches shared edges with already loaded neighbours automatically on add.
	const dtTileRef old = m_mesh->getTileRefAt(r.key.x, r.key.z, 0);
	if (old) {
		m_mesh->removeTile(old, nullptr, nullptr); // frees the old data (it was added with DT_TILE_FREE_DATA)
	}
	if (r.empty || !r.nav_data) {
		return true;
	}
	const dtStatus s = m_mesh->addTile(r.nav_data, r.nav_data_size, DT_TILE_FREE_DATA, 0, nullptr);
	if (dtStatusFailed(s)) {
		return false; // r keeps ownership and frees the data
	}
	r.nav_data = nullptr; // dtNavMesh owns it now
	return true;
}

void GroundDomain::remove_tile(const TileKey &key) {
	if (!m_mesh) {
		return;
	}
	const dtTileRef ref = m_mesh->getTileRefAt(key.x, key.z, 0);
	if (ref) {
		m_mesh->removeTile(ref, nullptr, nullptr);
	}
}

const dtQueryFilter &GroundDomain::filter_for(int tier) const {
	return m_filters[std::clamp(tier, 0, MAX_TIERS - 1)];
}

bool GroundDomain::snap_endpoints(dtNavMeshQuery *q, const float *from, const float *to, int tier, PathOutcome &fail) {
	const dtQueryFilter &f = filter_for(tier);
	dtPolyRef sref = 0, eref = 0;
	q->findNearestPoly(from, SNAP_EXTENTS, &f, &sref, m_start_pos);
	q->findNearestPoly(to, SNAP_EXTENTS, &f, &eref, m_end_pos);
	if (!sref) {
		fail.reason = "no nav mesh near start";
		return false;
	}
	if (!eref) {
		fail.reason = "no nav mesh near goal";
		return false;
	}
	m_start_ref = sref;
	m_end_ref = eref;
	return true;
}

void GroundDomain::straighten(dtNavMeshQuery *q, int npolys, bool partial, PathOutcome &out) {
	float end[3];
	dtVcopy(end, m_end_pos);
	if (npolys > 0 && m_polys[size_t(npolys - 1)] != m_end_ref) {
		// Goal not reached: aim for the closest point on the last polygon instead.
		q->closestPointOnPoly(m_polys[size_t(npolys - 1)], m_end_pos, end, nullptr);
		partial = true;
	}
	std::vector<float> corners(MAX_STRAIGHT * 3);
	int ncorners = 0;
	q->findStraightPath(m_start_pos, end, m_polys.data(), npolys, corners.data(), nullptr, nullptr, &ncorners, MAX_STRAIGHT, 0);
	out.ok = ncorners > 0;
	out.partial = partial;
	out.points.assign(corners.begin(), corners.begin() + ncorners * 3);
	if (!out.ok) {
		out.reason = "could not straighten path";
	}
}

bool GroundDomain::find_path_now(const float *from, const float *to, int tier, PathOutcome &out) {
	if (!m_mesh) {
		out.reason = "nav not initialised";
		return false;
	}
	if (!snap_endpoints(m_sync_query, from, to, tier, out)) {
		return false;
	}
	int npolys = 0;
	const dtStatus s = m_sync_query->findPath(m_start_ref, m_end_ref, m_start_pos, m_end_pos, &filter_for(tier),
			m_polys.data(), &npolys, MAX_PATH_POLYS);
	if (dtStatusFailed(s) || npolys == 0) {
		out.reason = "search failed";
		return false;
	}
	straighten(m_sync_query, npolys, (s & DT_PARTIAL_RESULT) != 0, out);
	return out.ok;
}

bool GroundDomain::closest_point(const float *p, int tier, float *out) const {
	if (!m_mesh) {
		return false;
	}
	const float extents[3] = { 4.0f, 8.0f, 4.0f };
	dtPolyRef ref = 0;
	m_sync_query->findNearestPoly(p, extents, &filter_for(tier), &ref, out);
	return ref != 0;
}

bool GroundDomain::begin_sliced(const float *from, const float *to, int tier, PathOutcome &fail) {
	if (!m_mesh) {
		fail.reason = "nav not initialised";
		return false;
	}
	if (!snap_endpoints(m_sliced_query, from, to, tier, fail)) {
		return false;
	}
	m_sliced_tier = tier;
	const dtStatus s = m_sliced_query->initSlicedFindPath(m_start_ref, m_end_ref, m_start_pos, m_end_pos, &filter_for(tier));
	if (dtStatusFailed(s)) {
		fail.reason = "search failed to start";
		return false;
	}
	return true;
}

int GroundDomain::step_sliced(int max_iterations, int &used) {
	used = 0;
	const dtStatus s = m_sliced_query->updateSlicedFindPath(max_iterations, &used);
	if (dtStatusFailed(s)) {
		return -1;
	}
	return dtStatusInProgress(s) ? 0 : 1;
}

void GroundDomain::finish_sliced(PathOutcome &out) {
	int npolys = 0;
	const dtStatus s = m_sliced_query->finalizeSlicedFindPath(m_polys.data(), &npolys, MAX_PATH_POLYS);
	if (dtStatusFailed(s) || npolys == 0) {
		out.ok = false;
		out.reason = "search failed";
		return;
	}
	straighten(m_sliced_query, npolys, (s & DT_PARTIAL_RESULT) != 0, out);
}

void GroundDomain::debug_triangles(const WorldRect &r, std::vector<float> &verts, std::vector<float> &colors) const {
	if (!m_mesh) {
		return;
	}
	static const float TIER_COLORS[MAX_TIERS][3] = {
		{ 0.20f, 0.45f, 0.95f }, // tier 0: smallest pawns only
		{ 0.20f, 0.80f, 0.40f }, // tier 1
		{ 0.95f, 0.85f, 0.20f }, // tier 2
		{ 0.95f, 0.45f, 0.15f }, // tier 3: room for the biggest pawns
	};
	const dtNavMesh *mesh = m_mesh;
	for (int i = 0; i < mesh->getMaxTiles(); ++i) {
		const dtMeshTile *tile = mesh->getTile(i);
		if (!tile || !tile->header) {
			continue;
		}
		const WorldRect tr{ tile->header->bmin[0], tile->header->bmin[2], tile->header->bmax[0], tile->header->bmax[2] };
		if (!tr.overlaps(r)) {
			continue;
		}
		for (int p = 0; p < tile->header->polyCount; ++p) {
			const dtPoly &poly = tile->polys[p];
			if (poly.getType() == DT_POLYTYPE_OFFMESH_CONNECTION) {
				continue;
			}
			const float *col = TIER_COLORS[area_tier(poly.getArea()) % MAX_TIERS];
			const float shade = 0.75f + 0.25f * float((p * 7) % 5) / 4.0f; // tell neighbouring polys apart
			const dtPolyDetail &pd = tile->detailMeshes[p];
			for (int j = 0; j < pd.triCount; ++j) {
				const unsigned char *t = &tile->detailTris[(pd.triBase + unsigned(j)) * 4];
				const int order[3] = { 0, 2, 1 }; // Detour is counter-clockwise; Godot front faces are clockwise
				for (int k : order) {
					const float *v = t[k] < poly.vertCount
							? &tile->verts[poly.verts[t[k]] * 3]
							: &tile->detailVerts[(pd.vertBase + (t[k] - poly.vertCount)) * 3];
					verts.push_back(v[0]);
					verts.push_back(v[1]);
					verts.push_back(v[2]);
					colors.push_back(col[0] * shade);
					colors.push_back(col[1] * shade);
					colors.push_back(col[2] * shade);
				}
			}
		}
	}
}

int GroundDomain::tile_count() const {
	if (!m_mesh) {
		return 0;
	}
	int n = 0;
	const dtNavMesh *mesh = m_mesh;
	for (int i = 0; i < mesh->getMaxTiles(); ++i) {
		const dtMeshTile *tile = mesh->getTile(i);
		if (tile && tile->header) {
			++n;
		}
	}
	return n;
}

} // namespace navcore
