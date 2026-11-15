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


# Claude 2026-11-16 (pawn M4): the input is the ControllerManager's now; a pawn without one records nothing pressed.
func same_as_last(pawn: Pawn, last: Variant) -> bool:
	if last == null:
		return false
	return last == remember(pawn)


func remember(pawn: Pawn) -> Variant:
	var c := pawn.controller_manager
	if c == null:
		return [Vector3.ZERO, pawn.yaw, 0.0, 0, 0.0]
	return [c.move_input, c.look_yaw, c.look_pitch, c.held_actions, c.view_ticks_behind]


func write_record(pawn: Pawn, out: StreamPeerBuffer) -> void:
	var values: Array = remember(pawn)
	out.put_half(values[0].x)
	out.put_half(values[0].y)
	out.put_half(values[0].z)
	out.put_half(wrapf(values[1], -PI, PI))
	out.put_half(values[2])
	out.put_u64(values[3])
	out.put_half(values[4])


func read_record(data: StreamPeerBuffer) -> Variant:
	var move := Vector3(data.get_half(), data.get_half(), data.get_half())
	var look_yaw := data.get_half()
	var look_pitch := data.get_half()
	return {"move_input": move, "look_yaw": look_yaw, "look_pitch": look_pitch, "held_actions": data.get_u64(),
		"view_ticks_behind": data.get_half()}
