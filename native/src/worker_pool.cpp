// Written by Claude (claude-opus-5-5), 2026-11-03: background threads for tile builds (spec section 3).
#include "worker_pool.h"

namespace navcore {

void WorkerPool::start(int thread_count) {
	stop();
	if (thread_count <= 0) {
		const int cores = int(std::thread::hardware_concurrency());
		thread_count = cores > 1 ? cores - 1 : 1;
	}
	m_stopping = false;
	for (int i = 0; i < thread_count; ++i) {
		m_threads.emplace_back([this]() { run(); });
	}
}

void WorkerPool::stop() {
	{
		std::lock_guard<std::mutex> lock(m_mutex);
		m_stopping = true;
		m_jobs.clear();
	}
	m_cv.notify_all();
	for (std::thread &t : m_threads) {
		if (t.joinable()) {
			t.join();
		}
	}
	m_threads.clear();
}

void WorkerPool::submit(std::function<void()> job) {
	{
		std::lock_guard<std::mutex> lock(m_mutex);
		m_jobs.push_back(std::move(job));
	}
	m_cv.notify_one();
}

void WorkerPool::run() {
	for (;;) {
		std::function<void()> job;
		{
			std::unique_lock<std::mutex> lock(m_mutex);
			m_cv.wait(lock, [this]() { return m_stopping || !m_jobs.empty(); });
			if (m_stopping) {
				return;
			}
			job = std::move(m_jobs.front());
			m_jobs.pop_front();
		}
		job();
	}
}

} // namespace navcore
