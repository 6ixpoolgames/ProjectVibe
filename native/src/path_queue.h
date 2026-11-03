// Written by Claude (claude-opus-5-5), 2026-11-03: budgeted, resumable path requests (spec 12.2, RequestQueue).
// v1 runs the searches on the main thread inside tick(), with an iteration budget per tick.
// The spec moves them to worker threads in phase 5; the queue API stays the same.
#pragma once

#include "ground_domain.h"

#include <deque>
#include <vector>

namespace navcore {

class PathQueue {
public:
	int push(const float *from, const float *to, int tier);
	void cancel(int id);
	void clear();
	size_t pending() const { return m_queue.size() + (m_active ? 1 : 0); }

	// Spend up to iteration_budget search steps; finished requests are appended to out.
	void process(GroundDomain &domain, int iteration_budget, std::vector<PathOutcome> &out);

private:
	struct Request {
		int id = 0;
		float from[3] = {};
		float to[3] = {};
		int tier = 0;
		int retries = 0;
	};

	std::deque<Request> m_queue;
	Request m_current;
	bool m_active = false;
	int m_next_id = 1;
};

} // namespace navcore
