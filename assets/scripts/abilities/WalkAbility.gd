## Written by Claude (claude-opus-5-5), 2026-11-07: walking on the ground: accelerating, slowing, steering in the air and turning to
## face where it's going. The default locomotion. Pawn spec section 8.5. It replaces GroundMovement's steering; the pawn adds gravity.
##
## Its numbers come from the pawn's stats, so a buff or a different pawn changes them without touching this:
##   speed_stat (MoveSpeed), Acceleration, Deceleration, AirControl, TurnRate (degrees per second)
## Each has a fallback, the same as GroundMovement used, for a pawn without that stat.
##
## While its category is locked out (an attack that roots the pawn), it stops steering and the pawn slows to a stop.
class_name WalkAbility
extends AbilityBase

## The stat for top speed, in metres per second. Sprint uses its own.
@export var speed_stat: StringName = &"MoveSpeed"
## Top speed when the pawn has no such stat.
@export var fallback_speed := 5.0


func _init() -> void:
	super()
	kind = Kind.LOCOMOTION
	category = &"movement.walk"


func tick(dt: float) -> void:
	var speed := read_stat(speed_stat, fallback_speed)
	var acceleration := read_stat(&"Acceleration", 30.0)
	var deceleration := read_stat(&"Deceleration", 40.0)
	var air_control := clampf(read_stat(&"AirControl", 0.3), 0.0, 1.0)
	var turn_rate := deg_to_rad(read_stat(&"TurnRate", 720.0))

	# Accelerate the horizontal velocity toward what's wanted. Locked out, nothing is wanted.
	var wanted := Vector3.ZERO if manager.is_locked(self) else pawn.move_input.limit_length(1.0)
	var target := wanted * speed
	var horizontal := Vector3(pawn.velocity.x, 0.0, pawn.velocity.z)
	var rate := acceleration if target.length_squared() > 0.0001 else deceleration
	if not pawn.grounded:
		rate *= air_control
	horizontal = horizontal.move_toward(target, rate * dt)
	pawn.velocity.x = horizontal.x
	pawn.velocity.z = horizontal.z

	# Face where it's moving. Godot's forward is -Z.
	if horizontal.length_squared() > 0.01:
		var target_yaw := atan2(-horizontal.x, -horizontal.z)
		pawn.yaw = rotate_toward(pawn.yaw, target_yaw, turn_rate * dt)
