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

# Claude 2026-11-09: the five stats, kept here and read again only when the StatManager's version changes (pawn spec 15.2). Reading
# all five every tick was about a third of this ability's cost.
var _stats_version := -1
var _stats_speed_stat: StringName = &""
var _speed := 0.0
var _acceleration := 0.0
var _deceleration := 0.0
var _air_control := 0.0
var _turn_rate := 0.0


func _init() -> void:
	super()
	kind = Kind.LOCOMOTION
	category = &"movement.walk"
	# Claude 2026-11-09: moving cancels only actions with a threshold of 0, such as an emote. Locomotion never blocks an action:
	# anything that conflicts with it stops it, as before.
	interrupt_priority = 0
	interrupt_threshold = 0


func tick(dt: float) -> void:
	_refresh_stats() # Claude 2026-11-09: was five read_stat calls here
	var speed := _speed
	var acceleration := _acceleration
	var deceleration := _deceleration
	var air_control := _air_control
	var turn_rate := _turn_rate

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


# Claude 2026-11-09: reads the five stats again if a stat changed (or there was no StatManager before and there is now), or if
# speed_stat was changed. The same values and fallbacks as before.
func _refresh_stats() -> void:
	var version: int = pawn.stat_manager.version if pawn and pawn.stat_manager else 0
	if version == _stats_version and speed_stat == _stats_speed_stat:
		return
	_stats_version = version
	_stats_speed_stat = speed_stat
	_speed = read_stat(speed_stat, fallback_speed)
	_acceleration = read_stat(&"Acceleration", 30.0)
	_deceleration = read_stat(&"Deceleration", 40.0)
	_air_control = clampf(read_stat(&"AirControl", 0.3), 0.0, 1.0)
	_turn_rate = deg_to_rad(read_stat(&"TurnRate", 720.0))
