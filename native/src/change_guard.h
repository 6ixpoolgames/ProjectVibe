// Written by Claude (claude-opus-5-5), 2026-11-17. History: native/CHANGELOG.md.
// ChangeGuard: the "wait for the readers" list that shared data keeps (PawnTable, AIPawnGrid, SightGeometry), so worker jobs can
// read it while it never changes under them. Not seen by GDScript.
//
// A job that reads one of them adds itself here, with what to call to wait for it (in practice, its scheduler's finish_all). The
// data calls before_change() just before it changes anything, which waits for every reader, so nothing is read half-changed.
// Every reader is on the list, so a second job reading the same data doesn't push out the first, and each piece of data has a
// list of its own (the pawn grid doesn't count on the table's guard having run first).
//
// Only touched on the main thread, like the data it guards.
#pragma once

#include <algorithm>
#include <functional>
#include <vector>

namespace navcore {

class ChangeGuard {
public:
	// reader is who's reading (the job itself), only used to find it again; adding the same reader twice replaces its wait.
	void add(const void *reader, std::function<void()> wait) {
		remove(reader);
		_readers.push_back(Reader{ reader, std::move(wait) });
	}

	void remove(const void *reader) {
		_readers.erase(std::remove_if(_readers.begin(), _readers.end(), [reader](const Reader &r) { return r.reader == reader; }),
				_readers.end());
	}

	// Waits for every reader. Call it before changing anything they read.
	void before_change() const {
		for (const Reader &r : _readers) {
			if (r.wait) {
				r.wait();
			}
		}
	}

private:
	struct Reader {
		const void *reader = nullptr;
		std::function<void()> wait;
	};
	std::vector<Reader> _readers;
};

} // namespace navcore
