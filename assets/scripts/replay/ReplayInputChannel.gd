## Written by Claude (claude-opus-5-5), 2026-11-15: replay channel 2, "input": each pawn's input command, the owner's call for v0
## (replay spec section 1). Not used by the v0 viewer beyond showing it; it's here so a later replay can re-simulate from a keyframe,
## and so a recording shows what a player or the AI was pressing when something went wrong.
##
## A record, 20 bytes: move input (3 × half), look yaw (half), look pitch (half), held actions (u64, bits from InputActions), view
## ticks behind (half). Read back as a Dictionary:
## {move_input: Vector3, look_yaw: float, look_pitch: float, held_actions: int, view_ticks_behind: float}.
class_name ReplayInputChannel
extends ReplayEntityChannel

const ID := 2


func _init() -> void:
	channel_id = ID
	channel_name = "input"
	version = 1


func same_as_last(pawn: Pawn, last: Variant) -> bool:
	if last == null:
		return false
	var was: Array = last
	return was[0] == pawn.move_input and was[1] == pawn.look_yaw and was[2] == pawn.look_pitch and was[3] == pawn.held_actions \
		and was[4] == pawn.view_ticks_behind


func remember(pawn: Pawn) -> Variant:
	return [pawn.move_input, pawn.look_yaw, pawn.look_pitch, pawn.held_actions, pawn.view_ticks_behind]


func write_record(pawn: Pawn, out: StreamPeerBuffer) -> void:
	out.put_half(pawn.move_input.x)
	out.put_half(pawn.move_input.y)
	out.put_half(pawn.move_input.z)
	out.put_half(wrapf(pawn.look_yaw, -PI, PI))
	out.put_half(pawn.look_pitch)
	out.put_u64(pawn.held_actions)
	out.put_half(pawn.view_ticks_behind)


func read_record(data: StreamPeerBuffer) -> Variant:
	var move := Vector3(data.get_half(), data.get_half(), data.get_half())
	var look_yaw := data.get_half()
	var look_pitch := data.get_half()
	return {"move_input": move, "look_yaw": look_yaw, "look_pitch": look_pitch, "held_actions": data.get_u64(),
		"view_ticks_behind": data.get_half()}
