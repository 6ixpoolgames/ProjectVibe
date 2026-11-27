# Written by Claude (claude-opus-5-5), 2026-11-27. History: steps/CHANGELOG.md.
## The input a host's steps write in one tick: an [InputCommand] that also knows which parts were written (pawn spec 16.7).
##
## Its host ([ControllerStepHost], an AI behaviour) clears it before its steps run, and the controller uses what they wrote. One writer
## per input: move and look take the last write, held actions OR together. A part nothing wrote is left to the controller (a still
## pawn, the pawn's own look).
class_name StepInput
extends InputCommand

## True once a step wrote [member InputCommand.move] this tick.
var move_set := false
## True once a step wrote the look this tick.
var look_set := false


## Before the steps run: nothing written.
func clear() -> void:
	move = Vector3.ZERO
	held_actions = 0
	move_set = false
	look_set = false


## Writes the move: which way to go, in world space, up to length 1.
func write_move(direction: Vector3) -> void:
	move = direction.limit_length(1.0)
	move_set = true


## Writes the look as a yaw and pitch, in radians.
func write_look(yaw: float, pitch: float) -> void:
	look_yaw = yaw
	look_pitch = pitch
	look_set = true


## Writes the look toward a point, measured from [param eye] (the pawn's eyes). Writes nothing for a point at the eyes.
func look_at(eye: Vector3, point: Vector3) -> void:
	var offset := point - eye
	if offset.length_squared() < 0.000001:
		return
	# Godot's forward is -Z, so a point straight ahead has yaw 0.
	write_look(atan2(-offset.x, -offset.z), atan2(offset.y, Vector2(offset.x, offset.z).length()))


## Holds these actions this tick ([InputActions] bits), along with any others written.
func write_held(bits: int) -> void:
	held_actions |= bits
