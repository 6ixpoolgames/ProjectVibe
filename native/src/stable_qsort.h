// Written by Claude (claude-opus-5-5), 2026-11-23. History: native/CHANGELOG.md.
// A stable drop-in for qsort, which the build forces into Recast's and Detour's sources only (SConstruct), so the nav mesh is built
// the same on every platform.
//
// Why: qsort isn't stable, and items that compare equal come out in an order that depends on the C runtime (MSVC's and glibc's
// differ). Recast sorts a region's holes and its candidate diagonals with it, and Detour sorts the polygons of each tile's
// bounding-volume tree, which decides the order queries meet polygons in. With exact ties (common on grid-aligned levels: dungeons,
// tiles, equal walls) the nav mesh and its queries came out differently on Windows and Linux (state store spec 13.11). A stable sort
// keeps tied items in their input order, and the input is the same everywhere. The third-party files stay untouched.
#pragma once

#include <cstdlib>
#include <stdlib.h> // both included first, so the define below can't rename their own declarations

// A merge sort with qsort's signature: equal items keep their order.
void navcore_stable_qsort(void *base, size_t count, size_t size, int (*compare)(const void *, const void *));

#define qsort navcore_stable_qsort
