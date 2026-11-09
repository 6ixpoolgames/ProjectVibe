// Written by Claude (claude-opus-5-5), 2026-11-09: worker threads for plain-data jobs on a server (scaling spec section 4, tier 1
// step 2). The owner's design, as agreed: the main thread runs ticks, and work that only reads plain data overflows to worker
// threads, with the scheduler learning what each kind of job costs.
//
// How a job runs:
//   - A job kind (AISensingJob, say) starts a run: some number of items (one per pawn, usually) and a function that does items
//     begin..end. The scheduler cuts it into batches, sized from what that kind has been measured to cost, so each batch is about
//     TARGET_BATCH_USEC of work: big enough to be worth a thread, small enough to spread.
//   - Batches go in one shared queue. Any idle worker takes the next one ("work stealing" in its simplest form), so the work balances
//     itself and no thread is planned in advance.
//   - When the result is needed (its due tick), the job kind calls finish(). If batches are left, the main thread runs them itself
//     and then waits for any still running. That's counted ("waits"), so an overloaded machine shows in the numbers.
//   - With 0 workers every batch runs on the main thread, in finish(). The answer is the same either way: a job only reads data
//     that doesn't change while it runs, and each item writes only its own place.
//
// How many workers (spec 4.1): the machine's logical cores, minus one for the main thread, minus one more when this machine also
// draws the game (not headless), at least 1, and at most max_workers (8 by default). set_worker_count() fixes a number instead (tests
// do, so they repeat on any machine; 0 means none).
//
// Nothing here touches Godot objects from a worker. A job's function must only read plain data and write its own results.
#pragma once

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/dictionary.hpp>

#include <condition_variable>
#include <cstdint>
#include <deque>
#include <functional>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

namespace godot {

class JobScheduler : public RefCounted {
	GDCLASS(JobScheduler, RefCounted)

public:
	// What one batch should cost, in microseconds: enough work to be worth handing to a thread.
	static constexpr double TARGET_BATCH_USEC = 100.0;

	using BatchFunction = std::function<void(int32_t begin, int32_t end)>;

	JobScheduler();
	~JobScheduler();

	// --- For GDScript ---
	// -1 (the default): sized to the machine, as above. 0: no workers, everything on the main thread. Any other number: that many.
	void set_worker_count(int64_t count);
	int64_t get_worker_count() const; // how many are running now
	int64_t workers_for_machine() const; // what -1 would give on this machine
	void set_max_workers(int64_t count);
	int64_t get_max_workers() const;
	// Finishes every run still going, on the main thread if it must.
	void finish_all();
	// For readouts: workers, and for each job kind its runs, items, batches, batches the main thread ran, waits, and its measured
	// cost per item in microseconds.
	Dictionary get_stats() const;
	void reset_stats();

	// --- For job kinds, in C++ ---
	// A kind's number, made on first use. first_guess_usec is what one item is guessed to cost until it's been measured.
	int kind(const char *name, double first_guess_usec);
	// Starts a run of item_count items and returns its handle (0 if there was nothing to do). Workers start on it at once.
	int64_t start(int kind, int32_t item_count, BatchFunction function);
	// Returns once the run is done: runs what's left on this thread, then waits for batches still running elsewhere.
	void finish(int64_t handle);
	bool is_finished(int64_t handle) const;

protected:
	static void _bind_methods();

private:
	struct Run {
		int64_t handle = 0;
		int kind = 0;
		BatchFunction function;
		int32_t item_count = 0;
		int32_t batch_size = 1;
		int32_t batch_count = 0;
		int32_t next_batch = 0; // the next batch nobody has taken
		int32_t batches_done = 0;
		int32_t batches_on_main = 0;
		double busy_usec = 0.0; // time spent in its batches, on any thread
	};
	struct Kind {
		std::string name;
		double usec_per_item = 1.0; // a running average, measured
		bool measured = false;
		int64_t runs = 0;
		int64_t items = 0;
		int64_t batches = 0;
		int64_t batches_on_main = 0;
		int64_t waits = 0;
	};

	void start_threads(int count);
	void stop_threads();
	void worker_loop();
	// Takes the next batch of run, or returns false. Called with the lock held.
	bool take_batch(Run &run, int32_t &begin, int32_t &end);
	void run_batch(const std::shared_ptr<Run> &run, int32_t begin, int32_t end, bool on_main);
	void retire(const std::shared_ptr<Run> &run); // called with the lock held, once its last batch is done
	std::shared_ptr<Run> find(int64_t handle) const; // called with the lock held

	mutable std::mutex _mutex;
	std::condition_variable _work_ready; // a batch was queued, or the threads must stop
	std::condition_variable _batch_done; // a batch finished
	std::vector<std::thread> _threads;
	std::deque<std::shared_ptr<Run>> _runs; // runs with batches left or running, oldest first
	std::vector<Kind> _kinds;
	int64_t _next_handle = 1;
	int64_t _requested_workers = -1;
	int64_t _max_workers = 8;
	bool _stopping = false;
};

} // namespace godot
