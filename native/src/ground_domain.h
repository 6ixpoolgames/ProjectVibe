// Written by Claude (claude-opus-5-5), 2026-11-03. History: native/CHANGELOG.md.
// GroundDomain: the live ground nav mesh: commit, unload, queries, debug (nav spec 8.3, 12). Owned by NavServer; not seen by
// GDScript. CrowdBatch reads it through NavServer::ground().
// Main thread only, except move_along_surface (see below). dtNavMesh is only ever changed in commit_tile / remove_tile, which the
// NavServer calls in the commit phase of its tick, never while a query is running.
//
// The spec's INavDomain interface gets extracted from this class when a second domain (air) arrives.
#pragma once

#include "ground_builder.h"

#include <DetourNavMesh.h> // dtPolyRef

#include <string>
#include <vector>

class dtNavMeshQuery;
class dtQueryFilter;

namespace navcore {

struct PathOutcome {
	int id = 0;
	bool ok = false;
	// Also set when the path was too long to return whole.
	bool partial = false; // goal not reached: path leads as close as it could get
	std::vector<float> points; // x, y, z per corner
	// One per corner. Not 0 where that corner starts a link, which then ends at the next corner. Only searches
	// that allow links fill it in; the others leave it empty.
	std::vector<uint32_t> link_ids;
	std::string reason; // why it failed
};

class GroundDomain {
public:
	GroundDomain();
	~GroundDomain();
	GroundDomain(const GroundDomain &) = delete;
	GroundDomain &operator=(const GroundDomain &) = delete;

	bool init(const NavConfig &cfg); // drops every tile
	bool ready() const { return m_mesh != nullptr; }

	// Swap in a finished build. Takes ownership of r.nav_data on success.
	// If the new tile can't be added, the old one is put back, so a failure never leaves a hole.
	bool commit_tile(TileBuildResult &r);
	void remove_tile(const TileKey &key);

	// ---- queries (synchronous) -------------------------------------------------------------
	// use_links lets the search cross links. Off by default, so a walker that can't jump is never sent over a gap.
	bool find_path_now(const float *from, const float *to, int tier, PathOutcome &out, bool use_links = false);
	bool closest_point(const float *p, int tier, float *out) const;

	// ---- walking along the surface (the crowd mover's walls) -------------------------------------------------------------
	// Safe on worker threads while the nav mesh doesn't change (it only changes in NavServer.tick, on the main thread), as long as
	// each thread uses a query object of its own: a dtNavMeshQuery can't be shared. new_query() makes one; free it with free_query().
	dtNavMeshQuery *new_query() const;
	static void free_query(dtNavMeshQuery *query);
	// Walks from `from` toward `to` along the nav mesh for this tier, sliding along its edges (where the walls are, less the tier's
	// radius) instead of crossing them: Detour's moveAlongSurface, what Unreal's NavWalking does. Links are never taken. False if
	// there's no nav mesh within `tolerance` of `from` across, or within `height` of it up and down: the caller moves it some other
	// way. out gets where it ends up across; its height is from's (the ground decides that).
	bool move_along_surface(dtNavMeshQuery *query, const float *from, const float *to, int tier, float tolerance, float height,
			float *out) const;

	// ---- sliced queries (used by PathQueue, one at a time) ------------------------------------
	// use_links, as find_path_now has; finish_sliced then fills in link_ids too.
	bool begin_sliced(const float *from, const float *to, int tier, PathOutcome &fail, bool use_links = false);
	// Returns: 0 = still running, 1 = done (call finish_sliced), -1 = failed (nav changed under it)
	int step_sliced(int max_iterations, int &used);
	void finish_sliced(PathOutcome &out);
	// The current sliced search's snapped start and end: polygons and points. For PathQueue's debug log.
	void sliced_endpoints(uint64_t &start_ref, uint64_t &end_ref, float *start_pos, float *end_pos) const;
	// Every polygon a snap near p could pick, in the order Detour meets them, for PathQueue's debug log: each one's ref, whether p is
	// over it, and the closest point on it (three floats each in closest).
	void debug_snap_candidates(const float *p, int tier, bool use_links, std::vector<uint64_t> &refs, std::vector<uint8_t> &over,
			std::vector<float> &closest) const;

	// ---- debug ------------------------------------------------------------------------------
	// Triangles of every tile overlapping r, in Godot winding, plus one colour per vertex (by tier).
	void debug_triangles(const WorldRect &r, std::vector<float> &verts, std::vector<float> &colors) const;
	int tile_count() const;
	// Every link in the live tiles overlapping r: start and end (6 floats each), its id, and whether it's two way.
	void debug_links(const WorldRect &r, std::vector<float> &ends, std::vector<uint32_t> &ids, std::vector<uint8_t> &two_way) const;
	// For tests only, to reach failures that are very hard to cause for real.
	void debug_fail_commits(int count) { m_debug_fail_commits = count; } // the next count tiles get corrupted before they're added
	void debug_limit_corners(int limit) { m_debug_corner_limit = limit; } // room for this many path corners; 0 = normal

private:
	// The start, goal and polygons of one search. find_path_now and the sliced search each have their own, so an immediate
	// search during a slow one can't change where the slow one ends.
	struct QueryState {
		dtPolyRef start_ref = 0, end_ref = 0;
		float start_pos[3] = {}, end_pos[3] = {};
		std::vector<dtPolyRef> polys;
	};

	const dtQueryFilter &filter_for(int tier, bool use_links = false) const;
	bool snap_endpoints(dtNavMeshQuery *q, QueryState &state, const float *from, const float *to, int tier, PathOutcome &fail,
			bool use_links = false);
	void straighten(dtNavMeshQuery *q, const QueryState &state, int npolys, bool partial, PathOutcome &out, bool want_links = false);

	NavConfig m_cfg;
	dtNavMesh *m_mesh = nullptr;
	dtNavMeshQuery *m_sync_query = nullptr; // find_path_now / closest_point
	dtNavMeshQuery *m_sliced_query = nullptr; // PathQueue's resumable searches
	dtQueryFilter *m_filters = nullptr; // one per tier; these leave links out
	dtQueryFilter *m_link_filters = nullptr; // one per tier, links allowed

	QueryState m_sync_state; // used only by find_path_now, and finished within the call
	QueryState m_sliced_state; // lasts as long as PathQueue's current search
	bool m_sliced_links = false; // whether that search may cross links
	int m_debug_fail_commits = 0;
	int m_debug_corner_limit = 0;
};

} // namespace navcore
