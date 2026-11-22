## Written by Claude (claude-opus-5-5), 2026-11-22: compares two replay recordings tick by tick (the owner's request: judge
## determinism across separate sessions from their replays, without the determinism check's own run). A tool, not a test: it reads
## two .pbreplay files with ReplayReader and reports the first tick where they differ, which pawn and which field, with both values,
## then how many ticks and pawns differ in all; when they agree, what they hold (the most pawns at once, events by kind), so a pass
## can be judged. Two sessions that start the same and play the same give equal files tick for tick.
##
## What it compares, per tick: which pawns exist, and each one's name, scene, team, motion (position in whole millimetres, yaw and
## velocity as stored, flags) and input; and the tick's events (spawns, world, gameplay), leaving out diagnostics, which are timings.
## The motion is what the recording keeps, so a difference smaller than its precision (a millimetre, half floats) isn't seen; the
## determinism check's fingerprints see every column exactly.
##
## Run from the project folder (tools/determinism/compare_replays.py does this for you):
##   godot --headless --path . "res://assets/scripts/samples/tests/replay_compare.tscn" -- --a=PATH --b=PATH
##   ... -- --latest=user://replays/headless/host     the two newest recordings in that folder, older first
##   ... -- --latest=FOLDER --count=4                  the four newest, each against the oldest of them
## More: --details=N (pawns listed at the first differing tick, default 10), --stop-at-first (skip the totals). Exit code 0: the
## recordings agree; 1: they differ; 2: a file couldn't be read.
extends Node

var _details := 10
var _stop_at_first := false
var _count := 2


func _ready() -> void:
	var path_a := ""
	var path_b := ""
	var latest_folder := ""
	for argument in OS.get_cmdline_user_args():
		var parts := argument.trim_prefix("--").split("=", true, 1)
		var value: String = parts[1] if parts.size() > 1 else ""
		match parts[0]:
			"a":
				path_a = value
			"b":
				path_b = value
			"latest":
				latest_folder = value
			"count":
				_count = maxi(int(value), 2)
			"details":
				_details = int(value)
			"stop-at-first":
				_stop_at_first = true
	if latest_folder != "":
		var newest := _newest(latest_folder, _count)
		if newest.size() < _count:
			print("replay_compare: %s holds %d recordings, fewer than the %d asked for" % [latest_folder, newest.size(), _count])
			get_tree().quit(2)
			return
		# Each against the oldest of them: N sessions, N - 1 comparisons. The worst result is the exit code.
		var worst := 0
		for i in range(1, newest.size()):
			print("--- Recording %d of %d against the first ---" % [i + 1, newest.size()])
			worst = maxi(worst, _compare(newest[0], newest[i]))
		get_tree().quit(worst)
		return
	if path_a == "" or path_b == "":
		print("replay_compare: give --a=PATH --b=PATH, or --latest=FOLDER with at least two recordings in it")
		get_tree().quit(2)
		return
	get_tree().quit(_compare(path_a, path_b))


func _compare(path_a: String, path_b: String) -> int:
	var a := ReplayReader.new()
	var b := ReplayReader.new()
	for pair in [[a, path_a], [b, path_b]]:
		if (pair[0] as ReplayReader).open(pair[1]) != OK:
			print("Couldn't read %s" % pair[1])
			return 2
	print("A: %s\nB: %s" % [path_a.get_file(), path_b.get_file()])
	for reader: ReplayReader in [a, b]:
		if reader.is_cut_short():
			print("  note: %s ends partway through a block; compared up to its last whole one" % ("A" if reader == a else "B"))
	var ticks_a := a.get_ticks()
	var ticks_b := b.get_ticks()
	if ticks_a.is_empty() or ticks_b.is_empty():
		print("One recording is empty.")
		return 2
	if ticks_a[0] != ticks_b[0]:
		print("  note: A starts at tick %d, B at tick %d. Ticks are compared by number, so the ones before the later start are left out." % [ticks_a[0], ticks_b[0]])
	var in_b := {}
	for tick in ticks_b:
		in_b[tick] = true
	var common: Array[int] = []
	for tick in ticks_a:
		if in_b.has(tick):
			common.append(tick)
	if common.is_empty():
		print("The recordings share no ticks.")
		return 2
	print("Comparing %d ticks (%d to %d); A has %d, B has %d." % [common.size(), common[0], common[-1], ticks_a.size(), ticks_b.size()])

	var first_tick := -1
	var differing_ticks := 0
	var differing_pawns := {} # id -> name, every pawn that ever differs
	var event_ticks := 0
	var most_pawns := 0
	var started := Time.get_ticks_msec()
	for tick in common:
		var frame_a := a.get_frame(tick)
		var frame_b := b.get_frame(tick)
		most_pawns = maxi(most_pawns, frame_a.pawns.size())
		var pawns_same: bool = frame_a.pawns == frame_b.pawns
		var events_a := _gameplay_events(frame_a.events)
		var events_b := _gameplay_events(frame_b.events)
		var events_same := events_a == events_b
		if pawns_same and events_same:
			continue
		differing_ticks += 1
		if not events_same:
			event_ticks += 1
		var ids := _differing_ids(frame_a.pawns, frame_b.pawns)
		for id in ids:
			differing_pawns[id] = _name_of(frame_a.pawns.get(id, frame_b.pawns.get(id)))
		if first_tick < 0:
			first_tick = tick
			_report_first(tick, frame_a, frame_b, ids, events_a, events_b)
			if _stop_at_first:
				break
	if first_tick < 0:
		print("The recordings agree: %d ticks, every pawn and event the same (%.1f s)." % [common.size(), (Time.get_ticks_msec() - started) / 1000.0])
		print("  What they hold: %s" % _contents(a, common, most_pawns))
		return 0
	if not _stop_at_first:
		print("In all: %d of %d ticks differ (%d with different events), in %d pawns (%.1f s)." % [differing_ticks, common.size(), event_ticks, differing_pawns.size(), (Time.get_ticks_msec() - started) / 1000.0])
	return 1


# The first differing tick in full: which pawns, which fields, both values, and the events if they differ.
func _report_first(tick: int, frame_a: Dictionary, frame_b: Dictionary, ids: Array, events_a: Array, events_b: Array) -> void:
	print("They differ from tick %d, in %d pawns%s:" % [tick, ids.size(), " and the events" if events_a != events_b else ""])
	for i in mini(ids.size(), _details):
		var id: int = ids[i]
		var info_a: Variant = frame_a.pawns.get(id)
		var info_b: Variant = frame_b.pawns.get(id)
		if info_a == null or info_b == null:
			print("  pawn %d (%s): only in %s" % [id, _name_of(info_a if info_a != null else info_b), "A" if info_a != null else "B"])
			continue
		print("  pawn %d (%s):" % [id, _name_of(info_a)])
		for key in info_a:
			if key == "motion" and info_a.motion is Dictionary and info_b.motion is Dictionary:
				for field in info_a.motion:
					if info_a.motion[field] != info_b.motion.get(field):
						print("      motion.%s  A %s  B %s" % [field, info_a.motion[field], info_b.motion.get(field)])
			elif info_a[key] != info_b.get(key):
				print("      %s  A %s  B %s" % [key, info_a[key], info_b.get(key)])
	if ids.size() > _details:
		print("  ... and %d more pawns" % (ids.size() - _details))
	if events_a != events_b:
		for side in [["A", events_a, events_b], ["B", events_b, events_a]]:
			var only: Array = side[1].filter(func(event: Dictionary) -> bool: return not side[2].has(event))
			for i in mini(only.size(), _details):
				var event: Dictionary = only[i]
				print("  event only in %s: %s %s %s %s" % [side[0], event.get("channel"), event.get("kind"), event.get("id"), event.get("data")])
			if only.size() > _details:
				print("  ... and %d more events only in %s" % [only.size() - _details, side[0]])
		if events_a.size() == events_b.size() and events_a.all(func(event: Dictionary) -> bool: return events_b.has(event)):
			print("  the events are the same, in a different order")


# A line saying what a recording holds over these ticks, so an agreement can be judged: the most pawns at once, and its events by kind
# (deaths and hits show the fight happened), leaving out diagnostics.
static func _contents(reader: ReplayReader, ticks: Array[int], most_pawns: int) -> String:
	var kinds := {}
	for event: Dictionary in _gameplay_events(reader.get_events(ticks[0], ticks[-1])):
		var kind := "%s %s" % [event.get("channel"), event.get("kind")]
		kinds[kind] = kinds.get(kind, 0) + 1
	var parts := PackedStringArray()
	var names := kinds.keys()
	names.sort()
	for kind in names:
		parts.append("%s %d" % [kind, kinds[kind]])
	return "up to %d pawns at once; events: %s" % [most_pawns, ", ".join(parts) if not parts.is_empty() else "none"]


# Pawn ids that differ between two frames, sorted: in one only, or with any field different.
static func _differing_ids(pawns_a: Dictionary, pawns_b: Dictionary) -> Array:
	var out: Array = []
	for id in pawns_a:
		if not pawns_b.has(id) or pawns_a[id] != pawns_b[id]:
			out.append(id)
	for id in pawns_b:
		if not pawns_a.has(id):
			out.append(id)
	out.sort()
	return out


# The tick's events without the diagnostics channel's, which are timings and differ every run.
static func _gameplay_events(events: Array) -> Array:
	return events.filter(func(event: Dictionary) -> bool: return event.get("channel") != "diagnostics") # ReplayDiagnosticsChannel's channel_name


static func _name_of(info: Variant) -> String:
	return String(info.get("name", "?")) if info is Dictionary else "?"


# The newest count .pbreplay files in a folder, oldest first; fewer if it has fewer.
static func _newest(folder: String, count: int) -> Array[String]:
	var files: Array[String] = []
	for file in DirAccess.get_files_at(folder):
		if file.ends_with(".pbreplay"):
			files.append(folder.path_join(file))
	files.sort_custom(func(x: String, y: String) -> bool: return FileAccess.get_modified_time(x) < FileAccess.get_modified_time(y) or (FileAccess.get_modified_time(x) == FileAccess.get_modified_time(y) and x < y))
	return files.slice(maxi(files.size() - count, 0))
