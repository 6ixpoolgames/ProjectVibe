// Written by Claude (claude-opus-5-5), 2026-11-03. History: native/CHANGELOG.md.
// TileManager: NavServer's tile lifecycle, streaming, build scheduling and commits (nav spec section 9). Not seen by GDScript.
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

#include <condition_variable>
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
	int link_count = 0; // links baked into the live tile, placed and found
	int auto_link_count = 0;
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
	// Tick phase 2: commit the builds due on this nav tick, in the order they started, waiting for any still running (state store
	// spec 13.12). Builds that finished early wait for their tick.
	void commit_finished(GroundDomain &domain, int64_t tick, std::vector<TileKey> &changed);
	// The tiles committed by the last commit_finished, in commit order (the landing record).
	const std::vector<TileKey> &last_committed() const { return m_last_committed; }
	// Tick phase 3: start builds for the most important tiles that need one.
	// links are the placed links; each build gets those starting in its tile.
	// Each build lands on tick + build_delay_ticks.
	void schedule(const InputStore &store, const std::vector<Interest> &interests, const std::vector<LinkDef> &links, WorkerPool &pool,
			int64_t tick);

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
		int link_count = 0;
		int auto_link_count = 0;
		double build_ms = 0.0;
		std::string error;
	};

	float priority(const TileRecord &t, const std::vector<Interest> &interests) const; // lower = sooner
	// The result of the build started as seq, waiting for it if it's still running.
	std::unique_ptr<TileBuildResult> wait_for(uint64_t seq);

	NavConfig m_cfg;
	std::unordered_map<TileKey, TileRecord, TileKeyHash> m_tiles;
	Version m_next_version = 1;
	uint64_t m_generation = 1;
	int m_in_flight = 0; // dispatched and not yet consumed by commit_finished

	mutable std::mutex m_done_mutex; // guards m_done, the only thing worker threads touch
	std::deque<std::unique_ptr<TileBuildResult>> m_done;
	std::condition_variable m_done_cv; // a worker added to m_done
	struct Dispatched {
		uint64_t seq = 0;
		int64_t due = 0; // the nav tick it lands on
	};
	std::deque<Dispatched> m_dispatched; // started and not yet landed, in the order they started (main thread only)
	std::unordered_map<uint64_t, std::unique_ptr<TileBuildResult>> m_finished; // finished early, waiting for their tick
	uint64_t m_next_seq = 1;
	std::vector<TileKey> m_last_committed;

	uint64_t m_builds_committed = 0, m_builds_stale = 0;
	double m_build_ms_total = 0.0, m_build_ms_max = 0.0;
	double m_last_commit_ms = 0.0, m_max_commit_ms = 0.0;
};

} // namespace navcore
