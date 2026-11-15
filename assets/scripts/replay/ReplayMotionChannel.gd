## Written by Claude (claude-opus-5-5), 2026-11-15: replay channel 1, "motion": where each pawn is and what it's doing (replay spec
## section 3). The data t0 debugging needs most, such as seeing a pawn walk off loaded ground and fall.
##
## Read back as a Dictionary: {position: Vector3, yaw: float, velocity: Vector3, flags: int, mm: Vector3i}. Test a flag with
## FLAG_*, as in (record.flags & ReplayMotionChannel.FLAG_DEAD) != 0.
##
## Claude 2026-11-15: version 2, the owner's request for better compression. A tick's bytes, laid out field by field (all the ids,
## then all the x changes, and so on), because zstd shrinks a column of similar small numbers far better than mixed records:
##   count (u16); ids (u32 each); position x, y, z changes (i32 each, whole millimetres); yaws (half); velocities x, y, z (half);
##   flags (u8, with bit 7 meaning "the position is whole, not a change")
## Positions are kept in whole millimetres, which loses nothing that matters: rollback already rounds them to 1 mm. Each is written
## as the change since that pawn's last record, so a walking pawn's is a few dozen, and a standing one writes nothing at all. A
## keyframe, or a pawn's first record, writes the whole position, so reading can start at any block.
## Version 1 (21-byte records one after another, positions as f32) is still read, for recordings made before.
class_name ReplayMotionChannel
extends ReplayEntityChannel

const ID := 1

## On the ground (Pawn.grounded).
const FLAG_GROUNDED := 1
## Dead (Pawn.dead): its Death ability runs.
const FLAG_DEAD := 2
## Frozen: switched off completely, so it doesn't tick at all (Pawn.is_frozen()). The AI switch-off does this
## where no ground is loaded.
const FLAG_FROZEN := 4
## Sleeping: idle, so it skipped its physics this tick, but still ticks its input and AI and wakes at once (Pawn.is_sleeping).
const FLAG_SLEEPING := 8
## Keeps the world loaded around it: it has a chunk source of its own (Pawn.is_keeping_world_loaded()).
const FLAG_HAS_SOURCE := 16
## A player controls it (ControllerManager.has_player(); Pawn's until pawn M4).
const FLAG_HAS_PLAYER := 32
# Claude 2026-11-15: in the file only, version 2: this record's position is whole, not a change. Never in a record read back.
const _WHOLE_POSITION := 128


func _init() -> void:
	channel_id = ID
	channel_name = "motion"
	version = 2 # Claude 2026-11-15: was 1; see the top of the file


## The flags for a pawn now.
static func flags_of(pawn: Pawn) -> int:
	var flags := 0
	if pawn.grounded:
		flags |= FLAG_GROUNDED
	if pawn.dead:
		flags |= FLAG_DEAD
	if pawn.is_frozen():
		flags |= FLAG_FROZEN
	if pawn.is_sleeping:
		flags |= FLAG_SLEEPING
	if pawn.is_keeping_world_loaded():
		flags |= FLAG_HAS_SOURCE
	if pawn.controller_manager and pawn.controller_manager.has_player(): # Claude 2026-11-16 (pawn M4)
		flags |= FLAG_HAS_PLAYER
	return flags


# Claude 2026-11-15: version 2's writing and reading, replacing ReplayEntityChannel's record-by-record ones.
func write_tick(_tick: int, out: StreamPeerBuffer, keyframe: bool) -> void:
	var ids := PackedInt64Array()
	var changes: Array[Vector3i] = []
	var yaws := PackedFloat32Array()
	var velocities: Array[Vector3] = []
	var flags := PackedByteArray()
	for entry: Array in _pawns:
		var pawn: Pawn = entry[0]
		var id: int = entry[1]
		if not is_instance_valid(pawn):
			continue
		var at := pawn.global_position
		var pawn_flags := flags_of(pawn)
		var last: Variant = _last.get(id)
		# GDScript note: == on Vector3 compares exactly, which is what's wanted: any change at all is written.
		if not keyframe and last != null and last[0] == at and last[1] == pawn.yaw and last[2] == pawn.velocity and last[3] == pawn_flags:
			continue
		var mm := Vector3i(roundi(at.x * 1000.0), roundi(at.y * 1000.0), roundi(at.z * 1000.0))
		var whole := keyframe or last == null
		_last[id] = [at, pawn.yaw, pawn.velocity, pawn_flags, mm]
		ids.append(id)
		changes.append(mm if whole else mm - (last[4] as Vector3i))
		yaws.append(wrapf(pawn.yaw, -PI, PI)) # wrapped, so a pawn that has turned many times keeps its precision
		velocities.append(pawn.velocity)
		flags.append(pawn_flags | (_WHOLE_POSITION if whole else 0))
	out.put_u16(ids.size())
	for id in ids:
		out.put_u32(id)
	for change in changes:
		out.put_32(change.x)
	for change in changes:
		out.put_32(change.y)
	for change in changes:
		out.put_32(change.z)
	for yaw in yaws:
		out.put_half(yaw)
	for moving in velocities:
		out.put_half(moving.x)
	for moving in velocities:
		out.put_half(moving.y)
	for moving in velocities:
		out.put_half(moving.z)
	out.put_data(flags)


func read_tick(tick: int, data: StreamPeerBuffer, keyframe: bool, state: Dictionary) -> void:
	if file_version < 2:
		super(tick, data, keyframe, state) # version 1: record by record
		return
	var count := data.get_u16()
	var ids := PackedInt64Array()
	for i in count:
		ids.append(data.get_u32())
	var changes: Array[Vector3i] = []
	changes.resize(count)
	for i in count:
		changes[i].x = data.get_32()
	for i in count:
		changes[i].y = data.get_32()
	for i in count:
		changes[i].z = data.get_32()
	var yaws := PackedFloat32Array()
	for i in count:
		yaws.append(data.get_half())
	var velocities: Array[Vector3] = []
	velocities.resize(count)
	for i in count:
		velocities[i].x = data.get_half()
	for i in count:
		velocities[i].y = data.get_half()
	for i in count:
		velocities[i].z = data.get_half()
	for i in count:
		var raw_flags := data.get_u8()
		var mm := changes[i]
		var before: Variant = state.get(ids[i])
		if (raw_flags & _WHOLE_POSITION) == 0 and before != null:
			mm += before.mm as Vector3i
		state[ids[i]] = {"position": Vector3(mm) / 1000.0, "yaw": yaws[i], "velocity": velocities[i],
			"flags": raw_flags & ~_WHOLE_POSITION, "mm": mm}


# Claude 2026-11-15: version 1's record, still read for older recordings (version 2 writes no records; see write_tick).
func read_record(data: StreamPeerBuffer) -> Variant:
	var at := Vector3(data.get_float(), data.get_float(), data.get_float())
	var yaw := data.get_half()
	var moving := Vector3(data.get_half(), data.get_half(), data.get_half())
	var flags := data.get_u8()
	var mm := Vector3i(roundi(at.x * 1000.0), roundi(at.y * 1000.0), roundi(at.z * 1000.0))
	return {"position": at, "yaw": yaw, "velocity": moving, "flags": flags, "mm": mm}
