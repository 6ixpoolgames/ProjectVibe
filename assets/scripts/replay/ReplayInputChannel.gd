# Written by Claude (claude-opus-5-5), 2026-11-15. History: replay/CHANGELOG.md.
## Replay channel 2, "input": each pawn's input command (replay spec section 1).
##
## Shows what a player or the AI was pressing when something went wrong, and lets a later replay re-simulate from a keyframe. The
## viewer only shows it for now. The input is the pawn's ControllerManager's; a pawn without one records nothing pressed.
## [br]
## A record, 20 bytes: move input (3 × half), look yaw (half), look pitch (half), held actions (u64, bits from [InputActions]),
## view ticks behind (half). Read back as [code]{move_input: Vector3, look_yaw, look_pitch, held_actions: int, view_ticks_behind}[/code].
## Design: replay spec 1.
class_name ReplayInputChannel
extends ReplayEntityChannel

const ID := 2


func _init() -> void:
	channel_id = ID
	channel_name = "input"
	version = 1


# Compared value by value, without building a list: this runs for every pawn every tick.
func same_as_last(pawn: Pawn, last: Variant) -> bool:
	if last == null:
		return false
	var c := pawn.controller_manager
	if c == null:
		return last[0] == Vector3.ZERO and last[1] == pawn.yaw and last[2] == 0.0 and last[3] == 0 and last[4] == 0.0
	return last[0] == c.move_input and last[1] == c.look_yaw and last[2] == c.look_pitch and last[3] == c.held_actions and last[4] == c.view_ticks_behind


func remember(pawn: Pawn) -> Variant:
	var c := pawn.controller_manager
	if c == null:
		return [Vector3.ZERO, pawn.yaw, 0.0, 0, 0.0]
	return [c.move_input, c.look_yaw, c.look_pitch, c.held_actions, c.view_ticks_behind]


func write_record(pawn: Pawn, out: StreamPeerBuffer) -> void:
	# Written straight from the controller manager, without building remember()'s list again.
	var c := pawn.controller_manager
	var move: Vector3 = c.move_input if c else Vector3.ZERO
	out.put_half(move.x)
	out.put_half(move.y)
	out.put_half(move.z)
	out.put_half(wrapf(c.look_yaw if c else pawn.yaw, -PI, PI))
	out.put_half(c.look_pitch if c else 0.0)
	out.put_u64(c.held_actions if c else 0)
	out.put_half(c.view_ticks_behind if c else 0.0)


func read_record(data: StreamPeerBuffer) -> Variant:
	var move := Vector3(data.get_half(), data.get_half(), data.get_half())
	var look_yaw := data.get_half()
	var look_pitch := data.get_half()
	return {"move_input": move, "look_yaw": look_yaw, "look_pitch": look_pitch, "held_actions": data.get_u64(),
		"view_ticks_behind": data.get_half()}
