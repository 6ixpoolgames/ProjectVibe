// Written by Claude (claude-opus-5-5), 2026-11-03. History: native/CHANGELOG.md.
// PathQueue: budgeted, resumable path requests (nav spec 12.2, RequestQueue), behind NavServer.find_path. Not seen by GDScript.
// v1 runs the searches on the main thread inside tick(), with an iteration budget per tick.
// The spec moves them to worker threads in phase 5; the queue API stays the same.
#pragma once

#include "ground_domain.h"

#include <cstdint>
#include <deque>
#include <vector>

namespace navcore {

class PathQueue {
public:
	// use_links lets the search cross links, as find_path_now_result's does.
	int push(const float *from, const float *to, int tier, bool use_links = false);
	void cancel(int id);
	void clear();
	size_t pending() const { return m_queue.size() + (m_active ? 1 : 0); }

	// Spend up to iteration_budget search steps; finished requests are appended to out.
	void process(GroundDomain &domain, int iteration_budget, std::vector<PathOutcome> &out);

	// For finding where two machines' searches part (NavServer.debug_log_path_steps): while log isn't null, process() appends
	// entries of five numbers, [tick, request id, kind, a, b]. Kinds: LOG_START (a, b: start and end polygon), LOG_FROM and LOG_TO
	// (the asked-for points), LOG_START_POS and LOG_END_POS (the snapped points), each point as a = (x bits << 32) | y bits, b = z
	// bits; LOG_STEP (a: steps used, b: 0 running, 1 done, -1 failed); LOG_NO_START (it failed to start); LOG_GOAL_CANDIDATE (a: a
	// polygon the goal could snap to, b: 1 if the goal is over it) and LOG_GOAL_CANDIDATE_POS (its closest point to the goal).
	enum LogKind { LOG_START = 0, LOG_STEP = 1, LOG_START_POS = 2, LOG_END_POS = 3, LOG_NO_START = 4, LOG_FROM = 5, LOG_TO = 6, LOG_GOAL_CANDIDATE = 7, LOG_GOAL_CANDIDATE_POS = 8 };
	void set_debug_log(std::vector<int64_t> *log, int64_t tick) {
		m_log = log;
		m_log_tick = tick;
	}

private:
	struct Request {
		int id = 0;
		float from[3] = {};
		float to[3] = {};
		int tier = 0;
		bool use_links = false;
		int retries = 0;
	};

	std::deque<Request> m_queue;
	Request m_current;
	bool m_active = false;
	int m_next_id = 1;
	std::vector<int64_t> *m_log = nullptr;
	int64_t m_log_tick = 0;

	void log(int id, LogKind kind, int64_t a, int64_t b);
	void log_point(int id, LogKind kind, const float *p);
};

} // namespace navcore
