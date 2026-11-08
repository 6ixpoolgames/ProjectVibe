## Written by Claude (claude-opus-5-5), 2026-11-09: a short, fast burst along the ground. An action bound to &"dash". Pawn spec section
## 8.6, step 9.
##
## For duration (0.15 s, 9 ticks) it drives the pawn at the DashSpeed stat (18 m/s by default), about 2.7 m in all, then Walk takes
## over again and slows it down. The direction is the way the pawn is being moved, or the way it faces when standing still. Ground
## only: no air dash (the owner's call). Gravity stays as normal.
##
## While it runs, walking, sprinting and jumping are locked out. With interrupt_priority 20 it cancels a MeleeAttack (threshold 15):
## that's the player's animation cancel. Its own threshold, 25, lets knockback (30) cancel it.
##
## Rollback: its direction is rollback state, with its timer and cooldown, so a corrected replay dashes the same way.
class_name DashAbility
extends AbilityBase

## The stat for its speed, in metres per second.
@export var speed_stat: StringName = &"DashSpeed"
## Its speed when the pawn has no such stat.
@export var fallback_speed := 18.0
## When it ends, horizontal speed is cut to this stat, so the dash stops crisply instead of Walk easing 18 m/s down over several
## metres. MoveSpeed by default.
@export var exit_speed_stat: StringName = &"MoveSpeed"
## The exit speed when the pawn has no such stat.
@export var fallback_exit_speed := 5.0

## The way it's dashing, flat and length 1. Rolls back.
var dash_direction := Vector3.ZERO


func _init() -> void:
	super()
	kind = Kind.ACTION
	trigger_action = &"dash"
	category = &"movement.dash"
	duration = 0.15
	cooldown = 1.0
	locks_out = [&"movement.walk", &"movement.sprint", &"movement.jump"]
	interrupt_priority = 20
	interrupt_threshold = 25


func get_rollback_properties() -> Array[String]:
	var out := super()
	out.append("dash_direction")
	return out


## Ground only.
func can_start() -> bool:
	return pawn.grounded


func start() -> void:
	var wanted := Vector3(pawn.move_input.x, 0.0, pawn.move_input.z)
	if wanted.length_squared() > 0.0001:
		dash_direction = wanted.normalized()
	else:
		dash_direction = Vector3(-sin(pawn.yaw), 0.0, -cos(pawn.yaw)) # the way it faces; Godot's forward is -Z
	pawn.yaw = atan2(-dash_direction.x, -dash_direction.z)


func tick(_dt: float) -> void:
	var speed := read_stat(speed_stat, fallback_speed)
	pawn.velocity.x = dash_direction.x * speed
	pawn.velocity.z = dash_direction.z * speed


## Ends crisply: horizontal speed is cut to the exit speed. A cancel (by knockback, say) sets its own velocity straight after.
func stop() -> void:
	var horizontal := Vector3(pawn.velocity.x, 0.0, pawn.velocity.z).limit_length(read_stat(exit_speed_stat, fallback_exit_speed))
	pawn.velocity.x = horizontal.x
	pawn.velocity.z = horizontal.z
