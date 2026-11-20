// Written by Claude (claude-opus-5-5), 2026-11-21. History: native/CHANGELOG.md.
// VisualPlacement: places every pawn's Visual between ticks, in one call a frame (pawn/VisualPlacer.gd runs it). Each slot is one
// drawn body: its Visual node, its Model (turned, or none), where the body was after its last two runs and its yaw then, how many
// ticks the last run covered and when it ended, and what's left of a network correction. place() glides each Visual from the run
// before to the last one: by the tick driver's fraction, or across the whole run for a run longer than a tick (pawn spec 8.21); a
// correction fades out over about 100 ms (netcode spec 6.2).
//
// Twin: pawn/VisualPlacementGD.gd does exactly the same in GDScript; a change goes in both, and pawn/tests/visual_placement_selftest
// compares them.
#pragma once

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/packed_int64_array.hpp>
#include <godot_cpp/variant/packed_vector3_array.hpp>
#include <godot_cpp/variant/vector3.hpp>

#include <cstdint>
#include <vector>

namespace godot {

class VisualPlacement : public RefCounted {
	GDCLASS(VisualPlacement, RefCounted)

public:
	// A new slot for this Visual and its Model (null: nothing turns), standing at position, facing yaw. Returns its number.
	int64_t add(Object *visual, Object *model, const Vector3 &position, double yaw);
	// Frees a slot; its number is reused.
	void remove(int64_t slot);
	// The body was put somewhere without moving there (a rollback, a spawn, a teleport): its Visual goes straight there.
	void snap(int64_t slot, const Vector3 &position, double yaw);
	// A run ended on tick, covering span ticks: the Visual glides from where the last run left the body to position.
	void note_run(int64_t slot, const Vector3 &position, double yaw, int64_t span, int64_t tick);
	// The same for many slots at once (the crowd mover's pawns); a slot below 0 is skipped.
	void note_runs(const PackedInt64Array &slots, const PackedVector3Array &positions, const PackedFloat32Array &yaws,
			const PackedInt64Array &spans, int64_t tick);
	// On a client, for a pawn someone else controls: moved between snapshots, so the Visual glides after it over one tick.
	void note_moved(int64_t slot, const Vector3 &position, double yaw);
	// On a client: a correction moved the body by jump. The Visual keeps where it was and catches up.
	void add_correction(int64_t slot, const Vector3 &jump);
	Vector3 get_correction(int64_t slot) const;
	// Places every slot's Visual: tick is the tick driver's, fraction how far it is towards the next, delta the frame's seconds.
	// spans_runs: false without a tick driver, when every glide is one tick long.
	void place(int64_t tick, double fraction, double delta, bool spans_runs);
	// Slots in use.
	int64_t get_count() const;

protected:
	static void _bind_methods();

private:
	struct Slot {
		bool used = false;
		uint64_t visual_id = 0;
		uint64_t model_id = 0;
		Vector3 previous_position;
		Vector3 current_position;
		double previous_yaw = 0.0;
		double current_yaw = 0.0;
		Vector3 correction;
		int64_t span = 1;
		int64_t run_tick = -1;
	};

	Slot *slot_at(int64_t slot);

	std::vector<Slot> m_slots;
	std::vector<int64_t> m_free;
	int64_t m_count = 0;
};

} // namespace godot
