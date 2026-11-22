// Written by Claude (claude-opus-5-5), 2026-11-03. History: native/CHANGELOG.md.
// PathQueue: budgeted, resumable path requests. Described in path_queue.h.
#include "path_queue.h"

#include <algorithm>
#include <cstring>

namespace navcore {

namespace {
constexpr int MAX_RETRIES = 3; // a tile committed mid-search invalidates it; just start over
// What starting a request costs, in search steps. Finding the nearest polygons to its start and goal is real work, so even
// requests that fail there count against the budget, and a big batch of them can't all run in one tick.
constexpr int REQUEST_START_COST = 16;
}

int PathQueue::push(const float *from, const float *to, int tier, bool use_links) {
	Request r;
	r.id = m_next_id++;
	std::copy(from, from + 3, r.from);
	std::copy(to, to + 3, r.to);
	r.tier = tier;
	r.use_links = use_links;
	m_queue.push_back(r);
	return r.id;
}

void PathQueue::cancel(int id) {
	if (m_active && m_current.id == id) {
		m_active = false;
	}
	m_queue.erase(std::remove_if(m_queue.begin(), m_queue.end(), [id](const Request &r) { return r.id == id; }), m_queue.end());
}

void PathQueue::log(int id, LogKind kind, int64_t a, int64_t b) {
	if (m_log) {
		m_log->insert(m_log->end(), { m_log_tick, int64_t(id), int64_t(kind), a, b });
	}
}

// A point's exact bits: x and y in a, z in b.
void PathQueue::log_point(int id, LogKind kind, const float *p) {
	if (!m_log) {
		return;
	}
	uint32_t bits[3];
	std::memcpy(bits, p, sizeof(bits));
	log(id, kind, int64_t((uint64_t(bits[0]) << 32) | bits[1]), int64_t(bits[2]));
}

void PathQueue::clear() {
	m_queue.clear();
	m_active = false;
}

void PathQueue::process(GroundDomain &domain, int iteration_budget, std::vector<PathOutcome> &out) {
	int budget = iteration_budget;
	while (budget > 0) {
		if (!m_active) {
			if (m_queue.empty()) {
				return;
			}
			m_current = m_queue.front();
			m_queue.pop_front();
			PathOutcome fail;
			fail.id = m_current.id;
			budget -= REQUEST_START_COST;
			log_point(m_current.id, LOG_FROM, m_current.from);
			log_point(m_current.id, LOG_TO, m_current.to);
			if (!domain.begin_sliced(m_current.from, m_current.to, m_current.tier, fail, m_current.use_links)) {
				log(m_current.id, LOG_NO_START, 0, 0);
				out.push_back(std::move(fail));
				continue;
			}
			if (m_log) {
				uint64_t start_ref = 0, end_ref = 0;
				float start_pos[3], end_pos[3];
				domain.sliced_endpoints(start_ref, end_ref, start_pos, end_pos);
				log(m_current.id, LOG_START, int64_t(start_ref), int64_t(end_ref));
				log_point(m_current.id, LOG_START_POS, start_pos);
				log_point(m_current.id, LOG_END_POS, end_pos);
				std::vector<uint64_t> refs;
				std::vector<uint8_t> over;
				std::vector<float> closest;
				domain.debug_snap_candidates(m_current.to, m_current.tier, m_current.use_links, refs, over, closest);
				for (size_t i = 0; i < refs.size(); ++i) {
					log(m_current.id, LOG_GOAL_CANDIDATE, int64_t(refs[i]), over[i]);
					log_point(m_current.id, LOG_GOAL_CANDIDATE_POS, &closest[i * 3]);
				}
			}
			m_active = true;
			continue; // the budget may be used up now
		}

		int used = 0;
		const int state = domain.step_sliced(budget, used);
		log(m_current.id, LOG_STEP, used, state);
		budget -= std::max(used, 1);
		if (state == 0) {
			continue; // still searching; the loop ends when the budget is used up
		}
		m_active = false;
		if (state < 0) {
			if (++m_current.retries <= MAX_RETRIES) {
				m_queue.push_front(m_current);
			} else {
				PathOutcome fail;
				fail.id = m_current.id;
				fail.reason = "search kept failing (nav changing too fast?)";
				out.push_back(std::move(fail));
			}
			continue;
		}
		PathOutcome done;
		done.id = m_current.id;
		domain.finish_sliced(done);
		out.push_back(std::move(done));
	}
}

} // namespace navcore
