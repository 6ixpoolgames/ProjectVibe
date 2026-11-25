# Written by Claude (claude-opus-5-5), 2026-11-07. History: abilities/CHANGELOG.md.
## Walking on the ground: accelerating, slowing, steering in the air and turning to face where it's going. The default locomotion.
##
## Its numbers come from the pawn's stats, so a buff or a different pawn changes them: [member speed_stat] (MoveSpeed), Acceleration,
## Deceleration, AirControl and TurnRate (degrees per second), each with a fallback for a pawn without it. The pawn adds gravity. While
## its category is locked out (an attack that roots the pawn) it stops steering and the pawn slows to a stop.
## Design: pawn spec 8.5.
class_name WalkAbility
extends AbilityBase

# Its settings with their own type: the same object as settings.
var _walk: WalkDefinition = null

# Its settings, read from its definition (ability spec 3). Writing one is for a script's _init(); see AbilityBase._set.

# The five stats, read again only when the StatusManager's version changes (pawn spec 15.2); every tick was a third of the cost.
var _stats_version := -1
var _stats_speed_stat: StringName = &""
var _speed := 0.0
var _acceleration := 0.0
var _deceleration := 0.0
var _air_control := 0.0
var _turn_rate := 0.0


## Its kind's defaults: a new [WalkDefinition].
func make_default_definition() -> AbilityDefinition:
	return WalkDefinition.new()


func _settings_changed() -> void:
	super()
	_walk = settings as WalkDefinition


func _init() -> void:
	super()
	kind = Kind.LOCOMOTION


func tick(dt: float) -> void:
	_refresh_stats()
	var speed := _speed
	var acceleration := _acceleration
	var deceleration := _deceleration
	var air_control := _air_control
	var turn_rate := _turn_rate

	# Accelerate the horizontal velocity toward what's wanted. Locked out, nothing is wanted.
	var wanted := Vector3.ZERO if manager.is_locked(self) else move_input().limit_length(1.0)
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


# Reads the five stats again if a stat changed (or there was no StatusManager before and there is now), or if speed_stat was changed.
func _refresh_stats() -> void:
	var version: int = pawn.status_manager.version if pawn and pawn.status_manager else 0
	if version == _stats_version and _walk and _walk.speed_stat == _stats_speed_stat: # _walk, not the property: this runs every tick
		return
	_stats_version = version
	_stats_speed_stat = _walk.speed_stat
	_speed = read_stat(_walk.speed_stat, _walk.fallback_speed)
	_acceleration = read_stat(&"Acceleration", 30.0)
	_deceleration = read_stat(&"Deceleration", 40.0)
	_air_control = clampf(read_stat(&"AirControl", 0.3), 0.0, 1.0)
	_turn_rate = deg_to_rad(read_stat(&"TurnRate", 720.0))
