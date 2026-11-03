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
	bool partial = false; // goal unreachable: path leads to the closest reachable point
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

private:
	const dtQueryFilter &filter_for(int tier) const;
	bool snap_endpoints(dtNavMeshQuery *q, const float *from, const float *to, int tier, PathOutcome &fail);
	void straighten(dtNavMeshQuery *q, int npolys, bool partial, PathOutcome &out);

	NavConfig m_cfg;
	dtNavMesh *m_mesh = nullptr;
	dtNavMeshQuery *m_sync_query = nullptr; // find_path_now / closest_point
	dtNavMeshQuery *m_sliced_query = nullptr; // PathQueue's resumable searches
	dtQueryFilter *m_filters = nullptr; // one per tier

	// State of the endpoints / result of the current query.
	dtPolyRef m_start_ref = 0, m_end_ref = 0;
	float m_start_pos[3] = {}, m_end_pos[3] = {};
	int m_sliced_tier = 0;
	std::vector<dtPolyRef> m_polys;
};

} // namespace navcore
