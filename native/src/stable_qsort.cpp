// Written by Claude (claude-opus-5-5), 2026-11-23. History: native/CHANGELOG.md.
// navcore_stable_qsort: a stable qsort for Recast and Detour. Described in stable_qsort.h.
#include "stable_qsort.h"

#include <algorithm>
#include <cstring>
#include <vector>

void navcore_stable_qsort(void *base, size_t count, size_t size, int (*compare)(const void *, const void *)) {
	if (count < 2 || size == 0) {
		return;
	}
	unsigned char *bytes = static_cast<unsigned char *>(base);
	// Sort the positions, then move the items once: the items are plain structs of any size, so a sort of indices is simplest.
	std::vector<size_t> order(count);
	for (size_t i = 0; i < count; ++i) {
		order[i] = i;
	}
	std::stable_sort(order.begin(), order.end(), [&](size_t a, size_t b) { return compare(bytes + a * size, bytes + b * size) < 0; });
	std::vector<unsigned char> sorted(count * size);
	for (size_t i = 0; i < count; ++i) {
		std::memcpy(&sorted[i * size], bytes + order[i] * size, size);
	}
	std::memcpy(bytes, sorted.data(), count * size);
}
