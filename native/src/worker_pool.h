// Written by Claude (claude-opus-5-5), 2026-11-03: background threads for tile builds (spec section 3).
#pragma once

#include <condition_variable>
#include <deque>
#include <functional>
#include <mutex>
#include <thread>
#include <vector>

namespace navcore {

class WorkerPool {
public:
	~WorkerPool() { stop(); }

	void start(int thread_count); // 0 = CPU cores - 1 (at least 1)
	void stop(); // drops queued jobs, waits for running ones
	bool running() const { return !m_threads.empty(); }
	int thread_count() const { return int(m_threads.size()); }

	void submit(std::function<void()> job);

private:
	void run();

	std::vector<std::thread> m_threads;
	std::deque<std::function<void()>> m_jobs;
	std::mutex m_mutex;
	std::condition_variable m_cv;
	bool m_stopping = false;
};

} // namespace navcore
