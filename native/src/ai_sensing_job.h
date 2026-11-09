// Written by Claude (claude-opus-5-5), 2026-11-09: the first job kind on worker threads (scaling spec step 2): for each pawn whose
// full sensing pass is next tick, find the pawns of other teams near it (AIPawnGrid) and work out how visible each one is
// (ai_sight_rules.h). The main thread then casts only the rays and records what's seen (AIMemoryStore.sight_check_prepared), because
// physics rays can't run off the main thread; step 4 moves line of sight into C++ too.
//
// When it runs: AISensingManager collects the pawns due next tick, and at the end of tick T (TickDriver.after_tick) asks for each
// one (add_request) and calls start(T). The table is read then, so the job sees every pawn where tick T left it, which is exactly
// what the pass on tick T+1 would have seen; workers do the work in the time between the two ticks. On tick T+1 each pawn's pass
// takes its result, waiting for it (or doing it on the main thread) only if it isn't done. So the answers are the same as the
// main-thread pass gives, with any number of workers or none, and the AI tests didn't need to change.
//
// The one difference: something that moves a pawn between ticks (a teleport, a test placing a pawn) isn't seen by the next tick's
// pass. A pass that has no result for its tick (a pawn that wasn't due, or one just spawned) runs on the main thread as before.
#pragma once

#include "ai_pawn_grid.h"
#include "ai_sight_rules.h"
#include "job_scheduler.h"
#include "pawn_table.h"
#include "sight_geometry.h" // Claude 2026-11-09 (scaling spec step 4)

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_float64_array.hpp>
#include <godot_cpp/variant/vector3.hpp>

#include <cstdint>
#include <unordered_map>
#include <vector>

namespace godot {

class AISensingJob : public RefCounted {
	GDCLASS(AISensingJob, RefCounted)

public:
	// One candidate, as the job found it: who, where it was, the point the ray aims at, and how visible it is (0 when it can't be
	// seen at all; it's still listed, because a check that sees nothing is recorded too).
	struct Candidate {
		uint64_t id = 0; // instance id
		Vector3 position;
		Vector3 aim;
		double visibility = 0.0;
		// Claude 2026-11-09 (step 4): line of sight, tested here when it could be seen and the geometry can answer: -1 not tested
		// (the main thread casts a physics ray), 0 clear, 1 blocked.
		int8_t ray = -1;
	};

	// The scheduler that runs it, and the grid it searches (which reads the pawn table). Sets the table's change guard, so the table
	// never changes while the job reads it.
	void setup(const Ref<JobScheduler> &scheduler, const Ref<AIPawnGrid> &grid);
	// Claude 2026-11-09 (scaling spec step 4): line of sight on the workers too, from this geometry (null: physics rays on the main
	// thread, as in step 2). Sets the geometry's change guard as well.
	void set_geometry(const Ref<SightGeometry> &geometry);
	~AISensingJob(); // finishes a run still going, which writes into this object
	// Asks for observer's pass on the tick after the next start(): eyes facing eye_yaw, looking reach metres for at most
	// max_candidates pawns, with its SightSense's settings (in AIMemoryStore.set_sight_settings' order). Where the eyes are is worked
	// out here, from the observer's position and eye_height. False if there's no setup or the observer isn't in the tree.
	bool add_request(Object *observer, double eye_yaw, double reach, int64_t max_candidates, const PackedFloat64Array &sight_settings);
	// Reads the table and starts the work for every request since the last start, for the passes on tick + 1. Results from the
	// previous start are dropped.
	void start(int64_t tick);
	// True if there's a result for observer's pass on this tick.
	bool has_result(Object *observer, int64_t tick) const;
	// The candidates found for observer's pass on this tick, as nodes, nearest first: for senses other than sight. Empty if none.
	Array get_candidates(Object *observer, int64_t tick);
	// For readouts and tests: requests, results taken, and the same since the counts were reset.
	Dictionary get_stats() const;
	void reset_stats();

	// For AIMemoryStore: observer's result on this tick, finishing the run first. Null if there's none. eye is where the eyes were.
	const Candidate *take(Object *observer, int64_t tick, int64_t &count, Vector3 &eye);

protected:
	static void _bind_methods();

private:
	struct Request {
		uint64_t observer = 0;
		int64_t slot = -1; // the observer's table slot, found at start
		int64_t team = 0;
		Vector3 eye;
		double eye_yaw = 0.0;
		double reach = 0.0;
		int64_t max_candidates = 0;
		sight_rules::Settings sight;
		bool use_geometry = false; // Claude 2026-11-09 (step 4): its mask doesn't include its own layer, so pawns can't block it
		size_t first = 0; // where its candidates start in _candidates
		int64_t found = 0; // how many it found
	};

	void run_requests(int32_t begin, int32_t end);
	int64_t find_request(Object *observer, int64_t tick) const;

	Ref<JobScheduler> _scheduler;
	Ref<AIPawnGrid> _grid;
	Ref<SightGeometry> _geometry; // Claude 2026-11-09 (step 4)
	const PawnTable *_table = nullptr; // the grid's table, set by start(); the grid holds the reference
	int _kind = -1;
	int _detectability = -1; // the table's detectability column

	std::vector<Request> _pending; // asked for since the last start
	std::vector<Request> _requests; // the running or finished run's
	std::vector<Candidate> _candidates; // every request's candidates, max_candidates places each
	std::unordered_map<uint64_t, size_t> _request_of; // observer's instance id -> its request
	int64_t _due_tick = -1; // the tick the results are for
	int64_t _handle = 0;

	int64_t _total_requests = 0;
	int64_t _total_taken = 0;
};

} // namespace godot
