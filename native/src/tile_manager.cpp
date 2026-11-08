// Written by Claude (claude-opus-5-5), 2026-11-03: tile lifecycle, streaming, build scheduling, commits (spec section 9).
#include "tile_manager.h"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <limits>

namespace navcore {

namespace {
using Clock = std::chrono::steady_clock;

float dist_xz(float ax, float az, float bx, float bz) {
	const float dx = ax - bx, dz = az - bz;
	return std::sqrt(dx * dx + dz * dz);
}
} // namespace

void TileManager::reset(const NavConfig &cfg) {
	m_cfg = cfg;
	m_tiles.clear();
	++m_generation; // results from older builds are recognised and dropped
	// m_in_flight stays: those builds still land in m_done and are counted down there.
}

void TileManager::resync_after_pool_stop() {
	std::lock_guard<std::mutex> lock(m_done_mutex);
	m_in_flight = int(m_done.size());
	for (auto &kv : m_tiles) {
		kv.second.in_flight_version = 0; // their builds may have been dropped; schedule() redoes them
	}
}

void TileManager::mark_dirty(const WorldRect &world_rect) {
	// A tile's border reads this far into its neighbours, so changes that close also concern them.
	const WorldRect r = world_rect.expanded(m_cfg.border_cells() * m_cfg.cell_size + m_cfg.cell_size);
	const float tw = m_cfg.tile_world();
	const int x0 = int(std::floor(r.min_x / tw)), x1 = int(std::floor(r.max_x / tw));
	const int z0 = int(std::floor(r.min_z / tw)), z1 = int(std::floor(r.max_z / tw));
	for (int z = z0; z <= z1; ++z) {
		for (int x = x0; x <= x1; ++x) {
			auto it = m_tiles.find(TileKey{ x, z });
			if (it != m_tiles.end()) {
				it->second.version = m_next_version++;
			}
		}
	}
}

void TileManager::update_wanted(const InputStore &store, const std::vector<Interest> &interests, GroundDomain &domain,
		std::vector<TileKey> &changed) {
	const float tw = m_cfg.tile_world();
	const float half_diag = tw * 0.7072f;

	// Create records for wanted tiles that have something walkable as input.
	for (const Interest &in : interests) {
		const int x0 = int(std::floor((in.x - in.load_radius) / tw)), x1 = int(std::floor((in.x + in.load_radius) / tw));
		const int z0 = int(std::floor((in.z - in.load_radius) / tw)), z1 = int(std::floor((in.z + in.load_radius) / tw));
		for (int z = z0; z <= z1; ++z) {
			for (int x = x0; x <= x1; ++x) {
				const TileKey key{ x, z };
				if (m_tiles.count(key)) {
					continue;
				}
				if (dist_xz((x + 0.5f) * tw, (z + 0.5f) * tw, in.x, in.z) > in.load_radius + half_diag) {
					continue;
				}
				if (!store.has_walkable_source_in(tile_world_rect(m_cfg, key))) {
					continue;
				}
				TileRecord rec;
				rec.key = key;
				rec.version = m_next_version++;
				m_tiles.emplace(key, rec);
			}
		}
	}

	// Drop tiles no interest wants any more. Builds still running for them are discarded on landing.
	for (auto it = m_tiles.begin(); it != m_tiles.end();) {
		const float cx = (it->first.x + 0.5f) * tw, cz = (it->first.z + 0.5f) * tw;
		bool wanted = false;
		for (const Interest &in : interests) {
			if (dist_xz(cx, cz, in.x, in.z) <= in.unload_radius + half_diag) {
				wanted = true;
				break;
			}
		}
		if (wanted) {
			++it;
			continue;
		}
		if (it->second.has_live) {
			domain.remove_tile(it->first);
			changed.push_back(it->first);
		}
		it = m_tiles.erase(it);
	}
}

void TileManager::commit_finished(GroundDomain &domain, double budget_ms, std::vector<TileKey> &changed) {
	const auto t0 = Clock::now();
	bool committed_any = false;
	for (;;) {
		if (committed_any && std::chrono::duration<double, std::milli>(Clock::now() - t0).count() >= budget_ms) {
			break; // leave the rest for next tick; at least one commit always happens so we never stall
		}
		std::unique_ptr<TileBuildResult> r;
		{
			std::lock_guard<std::mutex> lock(m_done_mutex);
			if (m_done.empty()) {
				break;
			}
			r = std::move(m_done.front());
			m_done.pop_front();
		}
		--m_in_flight;

		if (r->generation != m_generation) {
			continue; // built before a reset
		}
		auto it = m_tiles.find(r->key);
		if (it == m_tiles.end()) {
			continue; // tile was unloaded while building
		}
		TileRecord &t = it->second;
		t.in_flight_version = 0;
		if (r->version != t.version) {
			++m_builds_stale; // inputs changed while building; the tile will build again
			continue;
		}
		if (!r->error.empty()) {
			t.error = r->error;
			t.committed_version = t.version; // don't retry until something changes
			continue;
		}
		if (!domain.commit_tile(*r)) {
			t.error = "Detour addTile failed";
			t.committed_version = t.version;
			continue;
		}
		t.error.clear();
		t.committed_version = r->version;
		t.has_live = !r->empty;
		t.provisional = r->provisional;
		t.poly_count = r->poly_count;
		t.link_count = r->link_count; // Claude 2026-11-08
		t.auto_link_count = r->auto_link_count;
		t.build_ms = r->build_ms;
		++m_builds_committed;
		m_build_ms_total += r->build_ms;
		m_build_ms_max = std::max(m_build_ms_max, r->build_ms);
		changed.push_back(r->key);
		committed_any = true;
	}
	m_last_commit_ms = std::chrono::duration<double, std::milli>(Clock::now() - t0).count();
	m_max_commit_ms = std::max(m_max_commit_ms, m_last_commit_ms);
}

float TileManager::priority(const TileRecord &t, const std::vector<Interest> &interests) const {
	const float tw = m_cfg.tile_world();
	const float cx = (t.key.x + 0.5f) * tw, cz = (t.key.z + 0.5f) * tw;
	float best = std::numeric_limits<float>::max();
	for (const Interest &in : interests) {
		best = std::min(best, dist_xz(cx, cz, in.x, in.z) - in.priority * tw * 4.0f);
	}
	if (t.has_live) {
		best -= tw * 2.0f; // edits to tiles people are standing on feel instant
	}
	return best;
}

void TileManager::schedule(const InputStore &store, const std::vector<Interest> &interests, const std::vector<LinkDef> &links, WorkerPool &pool) {
	int slots = m_cfg.max_builds_in_flight - m_in_flight;
	if (slots <= 0) {
		return;
	}
	std::vector<std::pair<float, TileRecord *>> candidates;
	for (auto &kv : m_tiles) {
		TileRecord &t = kv.second;
		// One build per tile at a time: a tile changed again mid-build waits for that build to land
		// (and be discarded as stale) instead of piling up builds. This is the rebuild-storm guard.
		if (t.in_flight_version == 0 && t.committed_version != t.version) {
			candidates.emplace_back(priority(t, interests), &t);
		}
	}
	const size_t n = std::min(candidates.size(), size_t(slots));
	std::partial_sort(candidates.begin(), candidates.begin() + long(n), candidates.end(),
			[](const auto &a, const auto &b) { return a.first < b.first; });

	for (size_t i = 0; i < n; ++i) {
		TileRecord &t = *candidates[i].second;
		auto input = std::make_shared<TileBuildInput>();
		input->key = t.key;
		input->version = t.version;
		input->generation = m_generation;
		input->cfg = m_cfg;
		store.snapshot(tile_build_rect(m_cfg, t.key), input->snapshot); // references, not copies
		// Claude 2026-11-08: placed links starting in this tile. Copied, so a link removed mid-build can't change it.
		const WorldRect own = tile_world_rect(m_cfg, t.key);
		for (const LinkDef &link : links) {
			if (link.start[0] >= own.min_x && link.start[0] < own.max_x && link.start[2] >= own.min_z && link.start[2] < own.max_z) {
				input->placed_links.push_back(link);
			}
		}
		t.in_flight_version = t.version;
		++m_in_flight;
		pool.submit([this, input]() {
			std::unique_ptr<TileBuildResult> r = build_ground_tile(*input);
			std::lock_guard<std::mutex> lock(m_done_mutex);
			m_done.push_back(std::move(r));
		});
	}
}

void TileManager::stats(TileStats &out) const {
	out = TileStats();
	for (const auto &kv : m_tiles) {
		const TileRecord &t = kv.second;
		++out.tiles;
		if (t.in_flight_version != 0) {
			++out.building;
		} else if (t.committed_version == t.version) {
			if (!t.error.empty()) {
				++out.failed;
			} else {
				++out.ready;
			}
		} else if (t.committed_version == 0) {
			++out.queued;
		} else {
			++out.dirty;
		}
		if (t.provisional) {
			++out.provisional;
		}
	}
	{
		std::lock_guard<std::mutex> lock(m_done_mutex);
		out.results_waiting = int(m_done.size());
	}
	out.builds_committed = m_builds_committed;
	out.builds_stale = m_builds_stale;
	out.avg_build_ms = m_builds_committed ? m_build_ms_total / double(m_builds_committed) : 0.0;
	out.max_build_ms = m_build_ms_max;
	out.last_commit_ms = m_last_commit_ms;
	out.max_commit_ms = m_max_commit_ms;
}

void TileManager::tile_infos(std::vector<TileInfo> &out) const {
	out.clear();
	out.reserve(m_tiles.size());
	for (const auto &kv : m_tiles) {
		const TileRecord &t = kv.second;
		TileInfo info;
		info.key = t.key;
		if (t.in_flight_version != 0) {
			info.state = "building";
		} else if (t.committed_version == t.version) {
			info.state = t.error.empty() ? "ready" : "failed";
		} else if (t.committed_version == 0) {
			info.state = "queued";
		} else {
			info.state = "dirty";
		}
		info.provisional = t.provisional;
		info.has_live = t.has_live;
		info.poly_count = t.poly_count;
		info.link_count = t.link_count; // Claude 2026-11-08
		info.auto_link_count = t.auto_link_count;
		info.build_ms = t.build_ms;
		info.error = t.error;
		out.push_back(info);
	}
}

bool TileManager::idle() const {
	if (m_in_flight > 0) {
		return false;
	}
	for (const auto &kv : m_tiles) {
		if (kv.second.committed_version != kv.second.version) {
			return false;
		}
	}
	return true;
}

} // namespace navcore
