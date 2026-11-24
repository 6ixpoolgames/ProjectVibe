// Written by Claude (claude-opus-5-5), 2026-11-24. History: assets/scripts/singletons/CHANGELOG.md.
// Repeatable random numbers for gameplay: a hash of a seed, a key (usually an entity number), a tick and a salt (pawn spec 16.9).
// Nothing is stored, so a replayed tick rolls the same. Bit-for-bit twin of DeterministicRandom.unit_seeded in
// assets/scripts/singletons/DeterministicRandom.gd; the AI decider's comparison test checks they agree.
#pragma once

#include <cstdint>

namespace deterministic_random {

// A number from 0 up to (not including) 1, 24 bits.
inline double unit(int64_t seed, int64_t key, int64_t tick, int64_t salt) {
	// GDScript's ints are 64-bit and wrap on overflow; unsigned arithmetic wraps the same way in C++ (signed overflow is undefined).
	uint64_t h = (uint64_t(seed) * 83492791ULL) ^ (uint64_t(key) * 19349663ULL) ^ (uint64_t(tick) * 73856093ULL) ^ uint64_t(salt);
	h &= 0xFFFFFFFFULL;
	h = ((h ^ (h >> 16)) * 0x45D9F3BULL) & 0xFFFFFFFFULL;
	h = ((h ^ (h >> 16)) * 0x45D9F3BULL) & 0xFFFFFFFFULL;
	h = h ^ (h >> 16);
	return double(h & 0xFFFFFFULL) / 16777216.0;
}

} // namespace deterministic_random
