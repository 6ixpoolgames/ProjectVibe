# Written by Claude (claude-opus-5-5), 2026-11-15. History: replay/CHANGELOG.md.
## Replay channel 1, "motion": where each pawn is and what it's doing (replay spec section 3).
##
## Read back as [code]{position: Vector3, yaw, velocity: Vector3, flags: int, mm: Vector3i}[/code]; test a flag with
## [code](record.flags & ReplayMotionChannel.FLAG_DEAD) != 0[/code].
## [br]
## Version 2's bytes for a tick are laid out field by field, because zstd shrinks a column of similar numbers far better than mixed
## records: count (u16); ids (u32 each); position x, y, z changes (i32 each, whole millimetres); yaws (half); velocities x, y, z
## (half); flags (u8, bit 7: the position is whole, not a change). A pawn that didn't change writes nothing; a keyframe or a pawn's
## first record writes the whole position. Version 1 (21-byte records, positions as f32) is still read.
## [br]
## Twin parity: the comparing and packing runs in C++ ([code]ReplayMotionPacker[/code], navcore library) with the same bytes as
## the GDScript here, which is used with [member use_cpp_packing] off or no library. The replay selftest compares them.
## Design: replay spec 3.
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
## A player controls it (ControllerManager.has_player()).
const FLAG_HAS_PLAYER := 32
# In the file only (version 2): this record's position is whole, not a change. Never in a record read back.
const _WHOLE_POSITION := 128

## Pack in C++ when the library is there. Set it before recording starts: the two keep their own last-written record.
var use_cpp_packing := true
var _packer: Object = null # the C++ packer, made on first use


func _init() -> void:
	channel_id = ID
	channel_name = "motion"
	version = 2 # see the top of the file


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
	if pawn.controller_manager and pawn.controller_manager.has_player():
		flags |= FLAG_HAS_PLAYER
	return flags


# Version 2's writing: gathers each pawn's values, then packs them with pack_lists.
func write_tick(_tick: int, out: StreamPeerBuffer, keyframe: bool) -> void:
	var ids := PackedInt64Array()
	var positions := PackedVector3Array()
	var yaws := PackedFloat64Array()
	var velocities := PackedVector3Array()
	var flags := PackedByteArray()
	for entry: Array in _pawns:
		var pawn: Pawn = entry[0]
		if not is_instance_valid(pawn):
			continue
		ids.append(entry[1])
		positions.append(pawn.global_position)
		yaws.append(pawn.yaw)
		velocities.append(pawn.velocity)
		flags.append(flags_of(pawn))
	out.put_data(pack_lists(ids, positions, yaws, velocities, flags, keyframe))


## One tick's bytes from the pawns' values, leaving out unchanged pawns (unless keyframe). C++ or GDScript, same bytes.
func pack_lists(ids: PackedInt64Array, positions: PackedVector3Array, yaws: PackedFloat64Array, velocities: PackedVector3Array,
		flags: PackedByteArray, keyframe: bool) -> PackedByteArray:
	if use_cpp_packing and ClassDB.class_exists(&"ReplayMotionPacker"):
		if _packer == null:
			_packer = ClassDB.instantiate(&"ReplayMotionPacker")
		return _packer.pack(ids, positions, yaws, velocities, flags, keyframe)
	return _pack_lists_gdscript(ids, positions, yaws, velocities, flags, keyframe)


# The GDScript packing (layout in the class comment).
func _pack_lists_gdscript(given_ids: PackedInt64Array, positions: PackedVector3Array, given_yaws: PackedFloat64Array,
		given_velocities: PackedVector3Array, given_flags: PackedByteArray, keyframe: bool) -> PackedByteArray:
	var out := StreamPeerBuffer.new()
	var ids := PackedInt64Array()
	var changes: Array[Vector3i] = []
	var yaws := PackedFloat32Array()
	var velocities: Array[Vector3] = []
	var flags := PackedByteArray()
	for i in given_ids.size():
		var id := given_ids[i]
		var at := positions[i]
		var yaw := given_yaws[i]
		var velocity := given_velocities[i]
		var pawn_flags := given_flags[i]
		var last: Variant = _last.get(id)
		# Exact comparison: any change at all is written.
		if not keyframe and last != null and last[0] == at and last[1] == yaw and last[2] == velocity and last[3] == pawn_flags:
			continue
		var mm := Vector3i(roundi(at.x * 1000.0), roundi(at.y * 1000.0), roundi(at.z * 1000.0))
		var whole := keyframe or last == null
		_last[id] = [at, yaw, velocity, pawn_flags, mm]
		ids.append(id)
		changes.append(mm if whole else mm - (last[4] as Vector3i))
		yaws.append(wrapf(yaw, -PI, PI)) # wrapped, so a pawn that has turned many times keeps its precision
		velocities.append(velocity)
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
	return out.data_array


# The C++ packer keeps its own record of what was last written, so it forgets pawns too.
func pawn_removed(pawn: Pawn, id: int) -> void:
	super(pawn, id)
	if _packer:
		_packer.forget(id)


func end() -> void:
	if _packer:
		_packer.clear()
	super()


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


# Version 1's record, still read for older recordings (version 2 writes no records; see write_tick).
func read_record(data: StreamPeerBuffer) -> Variant:
	var at := Vector3(data.get_float(), data.get_float(), data.get_float())
	var yaw := data.get_half()
	var moving := Vector3(data.get_half(), data.get_half(), data.get_half())
	var flags := data.get_u8()
	var mm := Vector3i(roundi(at.x * 1000.0), roundi(at.y * 1000.0), roundi(at.z * 1000.0))
	return {"position": at, "yaw": yaw, "velocity": moving, "flags": flags, "mm": mm}
