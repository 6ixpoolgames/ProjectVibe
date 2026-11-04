// Written by Claude (claude-opus-5-5), 2026-11-03: budgeted, resumable path requests (spec 12.2, RequestQueue).
#include "path_queue.h"

#include <algorithm>

namespace navcore {

namespace {
constexpr int MAX_RETRIES = 3; // a tile committed mid-search invalidates it; just start over
// Claude 2026-11-05: what starting a request costs, in search steps. Finding the nearest polygons to its start and goal
// is real work, and requests that fail there used to cost nothing, so a big batch of them all ran in one tick.
constexpr int REQUEST_START_COST = 16;
}

int PathQueue::push(const float *from, const float *to, int tier) {
	Request r;
	r.id = m_next_id++;
	std::copy(from, from + 3, r.from);
	std::copy(to, to + 3, r.to);
	r.tier = tier;
	m_queue.push_back(r);
	return r.id;
}

void PathQueue::cancel(int id) {
	if (m_active && m_current.id == id) {
		m_active = false;
	}
	m_queue.erase(std::remove_if(m_queue.begin(), m_queue.end(), [id](const Request &r) { return r.id == id; }), m_queue.end());
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
			if (!domain.begin_sliced(m_current.from, m_current.to, m_current.tier, fail)) {
				out.push_back(std::move(fail));
				continue;
			}
			m_active = true;
			continue; // the budget may be used up now
		}

		int used = 0;
		const int state = domain.step_sliced(budget, used);
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
