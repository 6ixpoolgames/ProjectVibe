# Written by Claude (claude-opus-5-5), 2026-11-15. History: replay/CHANGELOG.md.
## A replay channel with one record per pawn (replay spec section 3).
##
## Each tick it writes the pawns whose record changed since they were last written, and every pawn on a keyframe. Input extends it;
## motion does too, but writes its ticks field by field ([ReplayMotionChannel]). A tick's bytes: count (u16), then per pawn its
## replay id (u32) and its record. An extending channel overrides [method same_as_last], [method remember], [method write_record]
## and [method read_record]. The reader's state is replay id -> record; a pawn's last record stays in it, shown only while the
## spawns channel lists the pawn as alive.
## Design: replay spec 3.
class_name ReplayEntityChannel
extends ReplayChannel

# Pawns being recorded, in arrival order: [pawn, replay id]. Not keyed by pawn: a freed pawn isn't a safe key.
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
	# The count goes first but isn't known yet: its place is kept and filled in at the end.
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


## True if nothing in the pawn's record changed since [method remember]'s last value (null if not written yet). Runs for every pawn every tick: cheap checks only.
func same_as_last(_pawn: Pawn, _last_value: Variant) -> bool:
	return false


## What [method same_as_last] compares against next time.
func remember(_pawn: Pawn) -> Variant:
	return null


## The pawn's record bytes.
func write_record(_pawn: Pawn, _out: StreamPeerBuffer) -> void:
	pass


## Reading: one record from its bytes, as the reader keeps it ([code]state[id][/code]).
func read_record(_data: StreamPeerBuffer) -> Variant:
	return null
