// Written by Claude (claude-opus-5-5), 2026-11-09: see job_scheduler.h.
#include "job_scheduler.h"

#include <godot_cpp/classes/display_server.hpp>
#include <godot_cpp/core/class_db.hpp>

#include <algorithm>
#include <chrono>
#include <cmath>

using namespace godot;

namespace {
double now_usec() {
	using namespace std::chrono;
	return double(duration_cast<nanoseconds>(steady_clock::now().time_since_epoch()).count()) / 1000.0;
}
} // namespace

JobScheduler::JobScheduler() {
	// The threads start on the first run, not here: a scheduler nobody uses costs nothing.
}

JobScheduler::~JobScheduler() {
	stop_threads();
}

// --- For GDScript ---

void JobScheduler::set_worker_count(int64_t count) {
	finish_all();
	stop_threads();
	_requested_workers = count < 0 ? -1 : count;
}

int64_t JobScheduler::get_worker_count() const {
	std::lock_guard<std::mutex> lock(_mutex);
	return int64_t(_threads.size());
}

int64_t JobScheduler::workers_for_machine() const {
	const int64_t cores = std::max<int64_t>(int64_t(std::thread::hardware_concurrency()), 1);
	int64_t count = cores - 1; // one core for the main thread
	// A machine that also draws the game needs a core for that. A dedicated server, or a headless test, doesn't.
	DisplayServer *display = DisplayServer::get_singleton();
	if (display != nullptr && display->get_name() != String("headless")) {
		count -= 1;
	}
	return std::clamp<int64_t>(count, 1, std::max<int64_t>(_max_workers, 1));
}

void JobScheduler::set_max_workers(int64_t count) {
	finish_all();
	stop_threads(); // restarted at the new size by the next run
	_max_workers = std::max<int64_t>(count, 1);
}

int64_t JobScheduler::get_max_workers() const {
	return _max_workers;
}

void JobScheduler::finish_all() {
	for (;;) {
		int64_t handle = 0;
		{
			std::lock_guard<std::mutex> lock(_mutex);
			if (_runs.empty()) {
				return;
			}
			handle = _runs.front()->handle;
		}
		finish(handle);
	}
}

Dictionary JobScheduler::get_stats() const {
	std::lock_guard<std::mutex> lock(_mutex);
	Dictionary stats;
	stats["workers"] = int64_t(_threads.size());
	Dictionary kinds;
	for (const Kind &k : _kinds) {
		Dictionary entry;
		entry["runs"] = k.runs;
		entry["items"] = k.items;
		entry["batches"] = k.batches;
		entry["batches_on_main"] = k.batches_on_main;
		entry["waits"] = k.waits;
		entry["usec_per_item"] = k.usec_per_item;
		kinds[String(k.name.c_str())] = entry;
	}
	stats["kinds"] = kinds;
	return stats;
}

void JobScheduler::reset_stats() {
	std::lock_guard<std::mutex> lock(_mutex);
	for (Kind &k : _kinds) {
		k.runs = 0;
		k.items = 0;
		k.batches = 0;
		k.batches_on_main = 0;
		k.waits = 0;
	}
}

// --- For job kinds ---

int JobScheduler::kind(const char *name, double first_guess_usec) {
	std::lock_guard<std::mutex> lock(_mutex);
	for (size_t i = 0; i < _kinds.size(); ++i) {
		if (_kinds[i].name == name) {
			return int(i);
		}
	}
	Kind k;
	k.name = name;
	k.usec_per_item = std::max(first_guess_usec, 0.01);
	_kinds.push_back(k);
	return int(_kinds.size() - 1);
}

int64_t JobScheduler::start(int kind_index, int32_t item_count, BatchFunction function) {
	if (item_count <= 0 || kind_index < 0) {
		return 0;
	}
	bool need_threads = false;
	std::shared_ptr<Run> run = std::make_shared<Run>();
	{
		std::lock_guard<std::mutex> lock(_mutex);
		const Kind &k = _kinds[size_t(kind_index)];
		run->handle = _next_handle++;
		run->kind = kind_index;
		run->function = std::move(function);
		run->item_count = item_count;
		// Batches of about TARGET_BATCH_USEC of work each, from what this kind has been measured to cost.
		const double per_batch = std::round(TARGET_BATCH_USEC / std::max(k.usec_per_item, 0.01));
		run->batch_size = int32_t(std::clamp<double>(per_batch, 1.0, double(item_count)));
		run->batch_count = (item_count + run->batch_size - 1) / run->batch_size;
		_runs.push_back(run);
		need_threads = _threads.empty() && _requested_workers != 0;
	}
	if (need_threads) {
		start_threads(int(_requested_workers < 0 ? workers_for_machine() : _requested_workers));
	}
	_work_ready.notify_all();
	return run->handle;
}

void JobScheduler::finish(int64_t handle) {
	std::unique_lock<std::mutex> lock(_mutex);
	std::shared_ptr<Run> run = find(handle);
	if (!run) {
		return; // already done
	}
	if (!_threads.empty()) {
		_kinds[size_t(run->kind)].waits += 1; // workers didn't get it done before it was needed
	}
	int32_t begin = 0;
	int32_t end = 0;
	while (take_batch(*run, begin, end)) {
		lock.unlock();
		run_batch(run, begin, end, true);
		lock.lock();
	}
	_batch_done.wait(lock, [&run]() { return run->batches_done >= run->batch_count; });
}

bool JobScheduler::is_finished(int64_t handle) const {
	std::lock_guard<std::mutex> lock(_mutex);
	return !find(handle);
}

// --- Threads ---

void JobScheduler::start_threads(int count) {
	std::lock_guard<std::mutex> lock(_mutex);
	if (!_threads.empty()) {
		return;
	}
	_stopping = false;
	for (int i = 0; i < count; ++i) {
		_threads.emplace_back([this]() { worker_loop(); });
	}
}

void JobScheduler::stop_threads() {
	{
		std::lock_guard<std::mutex> lock(_mutex);
		_stopping = true;
	}
	_work_ready.notify_all();
	for (std::thread &t : _threads) {
		if (t.joinable()) {
			t.join();
		}
	}
	std::lock_guard<std::mutex> lock(_mutex);
	_threads.clear();
	_stopping = false;
	// Runs still queued stay queued: finish() runs them on the main thread.
}

void JobScheduler::worker_loop() {
	std::unique_lock<std::mutex> lock(_mutex);
	for (;;) {
		std::shared_ptr<Run> chosen;
		int32_t begin = 0;
		int32_t end = 0;
		_work_ready.wait(lock, [&]() {
			if (_stopping) {
				return true;
			}
			for (const std::shared_ptr<Run> &run : _runs) {
				if (take_batch(*run, begin, end)) {
					chosen = run;
					return true;
				}
			}
			return false;
		});
		if (_stopping && !chosen) {
			return;
		}
		lock.unlock();
		run_batch(chosen, begin, end, false);
		lock.lock();
		if (_stopping) {
			return;
		}
	}
}

bool JobScheduler::take_batch(Run &run, int32_t &begin, int32_t &end) {
	if (run.next_batch >= run.batch_count) {
		return false;
	}
	begin = run.next_batch * run.batch_size;
	end = std::min(begin + run.batch_size, run.item_count);
	run.next_batch += 1;
	return true;
}

void JobScheduler::run_batch(const std::shared_ptr<Run> &run, int32_t begin, int32_t end, bool on_main) {
	const double started = now_usec();
	run->function(begin, end);
	const double took = now_usec() - started;
	{
		std::lock_guard<std::mutex> lock(_mutex);
		run->busy_usec += took;
		run->batches_done += 1;
		if (on_main) {
			run->batches_on_main += 1;
		}
		if (run->batches_done >= run->batch_count) {
			retire(run);
		}
	}
	_batch_done.notify_all();
}

void JobScheduler::retire(const std::shared_ptr<Run> &run) {
	auto found = std::find(_runs.begin(), _runs.end(), run);
	if (found != _runs.end()) {
		_runs.erase(found);
	}
	Kind &k = _kinds[size_t(run->kind)];
	k.runs += 1;
	k.items += run->item_count;
	k.batches += run->batch_count;
	k.batches_on_main += run->batches_on_main;
	// The running average per item: the first measurement replaces the guess, later ones move it a fifth of the way.
	const double measured = run->busy_usec / double(std::max(run->item_count, 1));
	k.usec_per_item = k.measured ? k.usec_per_item * 0.8 + measured * 0.2 : measured;
	k.measured = true;
}

std::shared_ptr<JobScheduler::Run> JobScheduler::find(int64_t handle) const {
	for (const std::shared_ptr<Run> &run : _runs) {
		if (run->handle == handle) {
			return run;
		}
	}
	return nullptr;
}

void JobScheduler::_bind_methods() {
	ClassDB::bind_method(D_METHOD("set_worker_count", "count"), &JobScheduler::set_worker_count);
	ClassDB::bind_method(D_METHOD("get_worker_count"), &JobScheduler::get_worker_count);
	ClassDB::bind_method(D_METHOD("workers_for_machine"), &JobScheduler::workers_for_machine);
	ClassDB::bind_method(D_METHOD("set_max_workers", "count"), &JobScheduler::set_max_workers);
	ClassDB::bind_method(D_METHOD("get_max_workers"), &JobScheduler::get_max_workers);
	ClassDB::bind_method(D_METHOD("finish_all"), &JobScheduler::finish_all);
	ClassDB::bind_method(D_METHOD("get_stats"), &JobScheduler::get_stats);
	ClassDB::bind_method(D_METHOD("reset_stats"), &JobScheduler::reset_stats);
}
