## Written by Claude (claude-opus-5-5), 2026-11-15: a replay channel with one record per pawn (replay spec section 3). Each tick it
## writes the pawns whose record changed since they were last written, and on a keyframe every pawn. Motion and input extend it.
##
## A tick's bytes:  count (u16), then for each pawn: its replay id (u32) and its record (what write_record writes)
##
## An extending channel overrides three things:
##   same_as_last(pawn, last) -> bool     true if nothing in the record changed. last is what remember() returned last time,
##                                        or null for a pawn not written yet. Cheap checks only: this runs for every pawn every tick.
##   remember(pawn) -> Variant            what same_as_last compares against next time
##   write_record(pawn, out)              the record's bytes
##   read_record(data) -> Variant         the record back from its bytes, as the reader keeps it (state[id] = this)
##
## The reader's state for this channel: replay id -> record. A pawn stays in it until the spawns channel says it went (the reader
## drops it then), because a pawn that didn't change writes nothing.
class_name ReplayEntityChannel
extends ReplayChannel

# Pawns being recorded, in the order they arrived: [pawn, replay id]. GDScript note: an Array of pairs rather than a Dictionary
# keyed by the pawn, because a freed pawn can't be used as a key safely; the recorder tells us when one goes.
var _pawns: Array = []
var _last := {} # replay id -> what remember() returned when it was last written


func pawn_added(pawn: Pawn, id: int) -> void:
	_pawns.append([pawn, id])


func pawn_removed(_pawn: Pawn, id: int) -> void:
	for i in _pawns.size():
		if _pawns[i][1] == id:
			_pawns.remove_at(i)
			break
	_last.erase(id)


func end() -> void:
	_pawns.clear()
	_last.clear()
	super()


func write_tick(_tick: int, out: StreamPeerBuffer, keyframe: bool) -> void:
	# The count goes first but isn't known yet, so a place is kept for it and filled in at the end.
	var count_at := out.get_position()
	out.put_u16(0)
	var count := 0
	for entry: Array in _pawns:
		var pawn: Pawn = entry[0]
		var id: int = entry[1]
		if not is_instance_valid(pawn):
			continue
		if not keyframe and same_as_last(pawn, _last.get(id)):
			continue
		_last[id] = remember(pawn)
		out.put_u32(id)
		write_record(pawn, out)
		count += 1
	var end_at := out.get_position()
	out.seek(count_at)
	out.put_u16(count)
	out.seek(end_at)


func read_tick(_tick: int, data: StreamPeerBuffer, _keyframe: bool, state: Dictionary) -> void:
	var count := data.get_u16()
	for i in count:
		var id := data.get_u32()
		state[id] = read_record(data)


func same_as_last(_pawn: Pawn, _last_value: Variant) -> bool:
	return false


func remember(_pawn: Pawn) -> Variant:
	return null


func write_record(_pawn: Pawn, _out: StreamPeerBuffer) -> void:
	pass


func read_record(_data: StreamPeerBuffer) -> Variant:
	return null
