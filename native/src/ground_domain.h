// Written by Claude (claude-opus-5-5), 2026-11-03: the live ground nav mesh: commit, unload, queries, debug (spec 8.3, 12).
// Main thread only. dtNavMesh is only ever changed in commit_tile / remove_tile, which the
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
	// Claude 2026-11-05: also set when the path was too long to return whole.
	bool partial = false; // goal not reached: path leads as close as it could get
	std::vector<float> points; // x, y, z per corner
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
	// Claude 2026-11-05: if the new tile can't be added, the old one is put back, so a failure never leaves a hole.
	bool commit_tile(TileBuildResult &r);
	void remove_tile(const TileKey &key);

	// ---- queries (synchronous) -------------------------------------------------------------
	bool find_path_now(const float *from, const float *to, int tier, PathOutcome &out);
	bool closest_point(const float *p, int tier, float *out) const;

	// ---- sliced queries (used by PathQueue, one at a time) ------------------------------------
	bool begin_sliced(const float *from, const float *to, int tier, PathOutcome &fail);
	// Returns: 0 = still running, 1 = done (call finish_sliced), -1 = failed (nav changed under it)
	int step_sliced(int max_iterations, int &used);
	void finish_sliced(PathOutcome &out);

	// ---- debug ------------------------------------------------------------------------------
	// Triangles of every tile overlapping r, in Godot winding, plus one colour per vertex (by tier).
	void debug_triangles(const WorldRect &r, std::vector<float> &verts, std::vector<float> &colors) const;
	int tile_count() const;
	// Claude 2026-11-05: for tests only, to reach failures that are very hard to cause for real.
	void debug_fail_commits(int count) { m_debug_fail_commits = count; } // the next count tiles get corrupted before they're added
	void debug_limit_corners(int limit) { m_debug_corner_limit = limit; } // room for this many path corners; 0 = normal

private:
	// Claude 2026-11-05: the start, goal and polygons of one search. find_path_now and the sliced search used to
	// share these, so an immediate search during a slow one changed where the slow one ended.
	struct QueryState {
		dtPolyRef start_ref = 0, end_ref = 0;
		float start_pos[3] = {}, end_pos[3] = {};
		std::vector<dtPolyRef> polys;
	};

	const dtQueryFilter &filter_for(int tier) const;
	bool snap_endpoints(dtNavMeshQuery *q, QueryState &state, const float *from, const float *to, int tier, PathOutcome &fail);
	void straighten(dtNavMeshQuery *q, const QueryState &state, int npolys, bool partial, PathOutcome &out);

	NavConfig m_cfg;
	dtNavMesh *m_mesh = nullptr;
	dtNavMeshQuery *m_sync_query = nullptr; // find_path_now / closest_point
	dtNavMeshQuery *m_sliced_query = nullptr; // PathQueue's resumable searches
	dtQueryFilter *m_filters = nullptr; // one per tier

	QueryState m_sync_state; // used only by find_path_now, and finished within the call
	QueryState m_sliced_state; // lasts as long as PathQueue's current search
	int m_debug_fail_commits = 0;
	int m_debug_corner_limit = 0;
};

} // namespace navcore
