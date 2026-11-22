// Written by Claude (claude-opus-5-5), 2026-11-03. History: native/CHANGELOG.md.
// GroundDomain: the live ground nav mesh: commit, unload, queries, debug (nav spec 8.3, 12). Described in ground_domain.h.
#include "ground_domain.h"

#include <DetourAlloc.h>
#include <DetourCommon.h>
#include <DetourNavMesh.h>
#include <DetourNavMeshQuery.h>

#include <algorithm>
#include <cfloat>
#include <cstring>

static_assert(sizeof(dtPolyRef) == 8, "build with DT_POLYREF64 (see SConstruct)");

namespace navcore {

namespace {
constexpr int MAX_PATH_POLYS = 4096;
constexpr int MAX_STRAIGHT = 1024;
constexpr int MAX_QUERY_NODES = 8192;
const float SNAP_EXTENTS[3] = { 2.0f, 4.0f, 2.0f }; // how far from the nav mesh a start/goal may be

// Detour's findNearestPoly with ties settled by polygon ref. Detour keeps the first polygon with the smallest score, in the order
// its bounding-volume tree hands them over; that tree is built with qsort, which isn't stable, so polygons with equal keys come out
// in a different order on another platform's C runtime (MSVC against glibc), and so does the winner of a tie. Ties are common: a
// point over a polygon and within climb height scores 0, as does a point over two at their shared edge. Same score, then the
// lower ref, so every platform picks the same polygon. Found by comparing Windows and Linux (state store spec 13.11).
class DeterministicNearestPoly : public dtPolyQuery {
public:
	DeterministicNearestPoly(const dtNavMeshQuery *query, const float *center) : m_query(query), m_center(center) {}

	void process(const dtMeshTile *tile, dtPoly **polys, dtPolyRef *refs, int count) override {
		(void)polys;
		for (int i = 0; i < count; ++i) {
			float closest[3];
			float diff[3];
			bool over = false;
			m_query->closestPointOnPoly(refs[i], m_center, closest, &over);
			dtVsub(diff, m_center, closest);
			float d;
			if (over) { // Detour's rule: directly over it and within climb height counts as 0
				d = dtAbs(diff[1]) - tile->header->walkableClimb;
				d = d > 0 ? d * d : 0;
			} else {
				d = dtVlenSqr(diff);
			}
			if (d < best_distance || (d == best_distance && best_ref != 0 && refs[i] < best_ref)) {
				dtVcopy(best_point, closest);
				best_distance = d;
				best_ref = refs[i];
			}
		}
	}

	dtPolyRef best_ref = 0;
	float best_point[3] = {};
	float best_distance = FLT_MAX;

private:
	const dtNavMeshQuery *m_query;
	const float *m_center;
};

// Use this, never dtNavMeshQuery::findNearestPoly (see DeterministicNearestPoly). ref gets 0 if there's no polygon in reach.
dtStatus nearest_poly(const dtNavMeshQuery *query, const float *center, const float *extents, const dtQueryFilter *filter, dtPolyRef *ref,
		float *point) {
	DeterministicNearestPoly found(query, center);
	const dtStatus status = query->queryPolygons(center, extents, filter, &found);
	*ref = found.best_ref;
	if (found.best_ref && point) {
		dtVcopy(point, found.best_point);
	}
	return status;
}
} // namespace

GroundDomain::GroundDomain() {
	m_filters = new dtQueryFilter[MAX_TIERS];
	m_link_filters = new dtQueryFilter[MAX_TIERS];
	for (int t = 0; t < MAX_TIERS; ++t) {
		m_filters[t].setIncludeFlags(tier_flag(t));
		m_filters[t].setExcludeFlags(POLYFLAG_LINK);
		m_link_filters[t].setIncludeFlags(tier_flag(t));
		m_link_filters[t].setExcludeFlags(0);
	}
}

GroundDomain::~GroundDomain() {
	dtFreeNavMeshQuery(m_sync_query);
	dtFreeNavMeshQuery(m_sliced_query);
	dtFreeNavMesh(m_mesh);
	delete[] m_filters;
	delete[] m_link_filters;
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
	m_sync_state.polys.resize(MAX_PATH_POLYS);
	m_sliced_state.polys.resize(MAX_PATH_POLYS);
	return true;
}

bool GroundDomain::commit_tile(TileBuildResult &r) {
	if (!m_mesh) {
		return false;
	}
	// Detour stitches shared edges with already loaded neighbours automatically on add.
	const dtTileRef old = m_mesh->getTileRefAt(r.key.x, r.key.z, 0);
	if (r.empty || !r.nav_data) {
		if (old) {
			m_mesh->removeTile(old, nullptr, nullptr); // frees the old data (it was added with DT_TILE_FREE_DATA)
		}
		return true;
	}

	// The old tile has to go before the new one can take its place, and removing it frees its data, so keep a copy to put
	// back if the new one is refused. Otherwise a refused tile would leave a hole in the mesh.
	unsigned char *backup = nullptr;
	int backup_size = 0;
	if (old) {
		const dtMeshTile *tile = static_cast<const dtNavMesh *>(m_mesh)->getTileByRef(old);
		backup_size = tile->dataSize;
		backup = static_cast<unsigned char *>(dtAlloc(backup_size, DT_ALLOC_PERM));
		if (!backup) {
			return false; // out of memory: nothing has changed yet, the old tile stays
		}
		std::memcpy(backup, tile->data, backup_size);
		m_mesh->removeTile(old, nullptr, nullptr);
	}

	if (m_debug_fail_commits > 0) {
		--m_debug_fail_commits;
		reinterpret_cast<dtMeshHeader *>(r.nav_data)->magic = 0; // Detour refuses a tile with the wrong magic number
	}

	const dtStatus s = m_mesh->addTile(r.nav_data, r.nav_data_size, DT_TILE_FREE_DATA, 0, nullptr);
	if (dtStatusFailed(s)) {
		// Passing old as the last argument gives the tile its old identity back, so searches running over it stay valid.
		if (backup && dtStatusFailed(m_mesh->addTile(backup, backup_size, DT_TILE_FREE_DATA, old, nullptr))) {
			dtFree(backup);
		}
		return false; // r keeps ownership and frees the data
	}
	dtFree(backup);
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

const dtQueryFilter &GroundDomain::filter_for(int tier, bool use_links) const {
	const int t = std::clamp(tier, 0, MAX_TIERS - 1);
	return use_links ? m_link_filters[t] : m_filters[t];
}

bool GroundDomain::snap_endpoints(dtNavMeshQuery *q, QueryState &state, const float *from, const float *to, int tier, PathOutcome &fail,
		bool use_links) {
	const dtQueryFilter &f = filter_for(tier, use_links);
	dtPolyRef sref = 0, eref = 0;
	nearest_poly(q, from, SNAP_EXTENTS, &f, &sref, state.start_pos);
	nearest_poly(q, to, SNAP_EXTENTS, &f, &eref, state.end_pos);
	if (!sref) {
		fail.reason = "no nav mesh near start";
		return false;
	}
	if (!eref) {
		fail.reason = "no nav mesh near goal";
		return false;
	}
	state.start_ref = sref;
	state.end_ref = eref;
	return true;
}

void GroundDomain::straighten(dtNavMeshQuery *q, const QueryState &state, int npolys, bool partial, PathOutcome &out, bool want_links) {
	float end[3];
	dtVcopy(end, state.end_pos);
	if (npolys > 0 && state.polys[size_t(npolys - 1)] != state.end_ref) {
		// Goal not reached: aim for the closest point on the last polygon instead.
		q->closestPointOnPoly(state.polys[size_t(npolys - 1)], state.end_pos, end, nullptr);
		partial = true;
	}
	std::vector<float> corners(MAX_STRAIGHT * 3);
	int ncorners = 0;
	const int max_corners = m_debug_corner_limit > 0 ? std::min(m_debug_corner_limit, MAX_STRAIGHT) : MAX_STRAIGHT;
	// Detour marks the corner where a link starts, and gives its polygon, which holds the link's id.
	std::vector<unsigned char> corner_flags(want_links ? MAX_STRAIGHT : 0);
	std::vector<dtPolyRef> corner_refs(want_links ? MAX_STRAIGHT : 0);
	const dtStatus s = q->findStraightPath(state.start_pos, end, state.polys.data(), npolys, corners.data(),
			want_links ? corner_flags.data() : nullptr, want_links ? corner_refs.data() : nullptr, &ncorners, max_corners, 0);
	// Detour says when it ran out of room for corners. The path then stops short of the goal, so callers are told it
	// isn't complete.
	if (dtStatusDetail(s, DT_BUFFER_TOO_SMALL)) {
		partial = true;
	}
	out.ok = dtStatusSucceed(s) && ncorners > 0;
	out.partial = partial;
	out.points.assign(corners.begin(), corners.begin() + ncorners * 3);
	out.link_ids.clear();
	if (want_links && ncorners > 0) {
		out.link_ids.assign(size_t(ncorners), 0u);
		for (int i = 0; i < ncorners; ++i) {
			if (corner_flags[size_t(i)] & DT_STRAIGHTPATH_OFFMESH_CONNECTION) {
				const dtOffMeshConnection *link = m_mesh->getOffMeshConnectionByRef(corner_refs[size_t(i)]);
				out.link_ids[size_t(i)] = link ? link->userId : 0u;
			}
		}
	}
	if (!out.ok) {
		out.reason = "could not straighten path";
	}
}

bool GroundDomain::find_path_now(const float *from, const float *to, int tier, PathOutcome &out, bool use_links) {
	if (!m_mesh) {
		out.reason = "nav not initialised";
		return false;
	}
	if (!snap_endpoints(m_sync_query, m_sync_state, from, to, tier, out, use_links)) {
		return false;
	}
	int npolys = 0;
	const dtStatus s = m_sync_query->findPath(m_sync_state.start_ref, m_sync_state.end_ref, m_sync_state.start_pos, m_sync_state.end_pos, &filter_for(tier, use_links),
			m_sync_state.polys.data(), &npolys, MAX_PATH_POLYS);
	if (dtStatusFailed(s) || npolys == 0) {
		out.reason = "search failed";
		return false;
	}
	straighten(m_sync_query, m_sync_state, npolys, (s & DT_PARTIAL_RESULT) != 0, out, use_links);
	return out.ok;
}

bool GroundDomain::closest_point(const float *p, int tier, float *out) const {
	if (!m_mesh) {
		return false;
	}
	const float extents[3] = { 4.0f, 8.0f, 4.0f };
	dtPolyRef ref = 0;
	nearest_poly(m_sync_query, p, extents, &filter_for(tier), &ref, out);
	return ref != 0;
}

dtNavMeshQuery *GroundDomain::new_query() const {
	if (!m_mesh) {
		return nullptr;
	}
	dtNavMeshQuery *query = dtAllocNavMeshQuery();
	if (query && dtStatusFailed(query->init(m_mesh, 64))) { // moveAlongSurface needs only a small node pool
		dtFreeNavMeshQuery(query);
		return nullptr;
	}
	return query;
}

void GroundDomain::free_query(dtNavMeshQuery *query) {
	dtFreeNavMeshQuery(query);
}

bool GroundDomain::move_along_surface(dtNavMeshQuery *query, const float *from, const float *to, int tier, float tolerance, float height,
		float *out) const {
	if (!m_mesh || query == nullptr) {
		return false;
	}
	const dtQueryFilter &filter = filter_for(tier); // never across links
	const float extents[3] = { tolerance, height, tolerance };
	dtPolyRef start = 0;
	float nearest[3];
	if (dtStatusFailed(nearest_poly(query, from, extents, &filter, &start, nearest)) || start == 0) {
		return false;
	}
	// The walk starts where the pawn is, across, if that's on the poly found; nearest_poly gives a point on it.
	const float dx = nearest[0] - from[0];
	const float dz = nearest[2] - from[2];
	if (dx * dx + dz * dz > tolerance * tolerance) {
		return false;
	}
	dtPolyRef visited[16];
	int visited_count = 0;
	if (dtStatusFailed(query->moveAlongSurface(start, nearest, to, &filter, out, visited, &visited_count, 16))) {
		return false;
	}
	out[1] = from[1];
	return true;
}

bool GroundDomain::begin_sliced(const float *from, const float *to, int tier, PathOutcome &fail, bool use_links) {
	if (!m_mesh) {
		fail.reason = "nav not initialised";
		return false;
	}
	m_sliced_links = use_links;
	if (!snap_endpoints(m_sliced_query, m_sliced_state, from, to, tier, fail, use_links)) {
		return false;
	}
	const dtStatus s = m_sliced_query->initSlicedFindPath(m_sliced_state.start_ref, m_sliced_state.end_ref, m_sliced_state.start_pos, m_sliced_state.end_pos,
			&filter_for(tier, use_links));
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

void GroundDomain::sliced_endpoints(uint64_t &start_ref, uint64_t &end_ref, float *start_pos, float *end_pos) const {
	start_ref = uint64_t(m_sliced_state.start_ref);
	end_ref = uint64_t(m_sliced_state.end_ref);
	for (int i = 0; i < 3; ++i) {
		start_pos[i] = m_sliced_state.start_pos[i];
		end_pos[i] = m_sliced_state.end_pos[i];
	}
}

void GroundDomain::debug_snap_candidates(const float *p, int tier, bool use_links, std::vector<uint64_t> &refs, std::vector<uint8_t> &over,
		std::vector<float> &closest) const {
	dtPolyRef found[64];
	int count = 0;
	m_sync_query->queryPolygons(p, SNAP_EXTENTS, &filter_for(tier, use_links), found, &count, 64);
	for (int i = 0; i < count; ++i) {
		float c[3];
		bool is_over = false;
		m_sync_query->closestPointOnPoly(found[i], p, c, &is_over);
		refs.push_back(uint64_t(found[i]));
		over.push_back(is_over ? 1 : 0);
		closest.insert(closest.end(), { c[0], c[1], c[2] });
	}
}

void GroundDomain::finish_sliced(PathOutcome &out) {
	int npolys = 0;
	const dtStatus s = m_sliced_query->finalizeSlicedFindPath(m_sliced_state.polys.data(), &npolys, MAX_PATH_POLYS);
	if (dtStatusFailed(s) || npolys == 0) {
		out.ok = false;
		out.reason = "search failed";
		return;
	}
	straighten(m_sliced_query, m_sliced_state, npolys, (s & DT_PARTIAL_RESULT) != 0, out, m_sliced_links);
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

void GroundDomain::debug_links(const WorldRect &r, std::vector<float> &ends, std::vector<uint32_t> &ids, std::vector<uint8_t> &two_way) const {
	if (!m_mesh) {
		return;
	}
	const dtNavMesh *mesh = m_mesh;
	for (int i = 0; i < mesh->getMaxTiles(); ++i) {
		const dtMeshTile *tile = mesh->getTile(i);
		if (!tile || !tile->header) {
			continue;
		}
		for (int c = 0; c < tile->header->offMeshConCount; ++c) {
			const dtOffMeshConnection &link = tile->offMeshCons[c];
			if (link.pos[0] < r.min_x || link.pos[0] >= r.max_x || link.pos[2] < r.min_z || link.pos[2] >= r.max_z) {
				continue;
			}
			ends.insert(ends.end(), link.pos, link.pos + 6);
			ids.push_back(link.userId);
			two_way.push_back((link.flags & DT_OFFMESH_CON_BIDIR) ? 1 : 0);
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
