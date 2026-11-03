// Written by Claude (claude-opus-5-5), 2026-11-03: tile lifecycle, streaming, build scheduling, commits (spec section 9).
//
// Every tile has a version. Anything that changes a tile's inputs gives it a new version.
// A build remembers the version it started from; at commit, a build whose version is no
// longer current is thrown away (stale) and the tile simply builds again. Versions never
// repeat, so this works even across a tile being unloaded and loaded again.
//
// Tile states (derived, for stats/debug):
//   queued   = wanted, never built yet
//   building = a build is running on a worker
//   ready    = live data matches the current version
//   dirty    = live data is older than the current version (old data keeps serving queries)
#pragma once

#include "ground_builder.h"
#include "ground_domain.h"
#include "input_store.h"
#include "worker_pool.h"

#include <deque>
#include <memory>
#include <mutex>
#include <string>
#include <unordered_map>
#include <vector>

namespace navcore {

struct Interest {
	int id = 0;
	float x = 0, y = 0, z = 0;
	float load_radius = 0; // build tiles within this distance
	float unload_radius = 0; // drop tiles beyond this distance (bigger than load_radius: hysteresis)
	int priority = 0; // higher = built first
};

struct TileInfo {
	TileKey key;
	const char *state = "queued";
	bool provisional = false;
	bool has_live = false;
	int poly_count = 0;
	double build_ms = 0.0;
	std::string error;
};

struct TileStats {
	int tiles = 0, queued = 0, building = 0, ready = 0, dirty = 0, provisional = 0, failed = 0;
	int results_waiting = 0;
	uint64_t builds_committed = 0, builds_stale = 0;
	double avg_build_ms = 0.0, max_build_ms = 0.0;
	double last_commit_ms = 0.0, max_commit_ms = 0.0;
};

class TileManager {
public:
	void reset(const NavConfig &cfg); // forgets every tile; builds still running are discarded when they land
	// Call after WorkerPool::stop(): queued jobs were dropped without running, so only results
	// already waiting in m_done are still "in flight".
	void resync_after_pool_stop();

	// Tick phase 1: inputs changed in this world area.
	void mark_dirty(const WorldRect &world_rect);
	// Tick phase 1: create tiles near interests (if some ADD layer has data there), drop far ones.
	void update_wanted(const InputStore &store, const std::vector<Interest> &interests, GroundDomain &domain,
			std::vector<TileKey> &changed);
	// Tick phase 2: swap in finished builds until the time budget is used.
	void commit_finished(GroundDomain &domain, double budget_ms, std::vector<TileKey> &changed);
	// Tick phase 3: start builds for the most important tiles that need one.
	void schedule(const InputStore &store, const std::vector<Interest> &interests, WorkerPool &pool);

	void stats(TileStats &out) const;
	void tile_infos(std::vector<TileInfo> &out) const;
	bool idle() const; // nothing waiting to build, building, or waiting to commit

private:
	struct TileRecord {
		TileKey key;
		Version version = 0; // current inputs
		Version committed_version = 0; // version of the live data (0 = never built)
		Version in_flight_version = 0; // version being built right now (0 = none)
		bool has_live = false;
		bool provisional = false;
		int poly_count = 0;
		double build_ms = 0.0;
		std::string error;
	};

	float priority(const TileRecord &t, const std::vector<Interest> &interests) const; // lower = sooner

	NavConfig m_cfg;
	std::unordered_map<TileKey, TileRecord, TileKeyHash> m_tiles;
	Version m_next_version = 1;
	uint64_t m_generation = 1;
	int m_in_flight = 0; // dispatched and not yet consumed by commit_finished

	mutable std::mutex m_done_mutex; // guards m_done, the only thing worker threads touch
	std::deque<std::unique_ptr<TileBuildResult>> m_done;

	uint64_t m_builds_committed = 0, m_builds_stale = 0;
	double m_build_ms_total = 0.0, m_build_ms_max = 0.0;
	double m_last_commit_ms = 0.0, m_max_commit_ms = 0.0;
};

} // namespace navcore
