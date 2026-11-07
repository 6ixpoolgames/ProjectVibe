## Written by Claude (claude-opus-5-5), 2026-11-07: walking on the ground: acceleration, turning, gravity and a jump impulse.
## Made for rollback: everything it reads is on the pawn and listed in its TickState, so running a tick again gives the same result.
##
## Speeds are plain settings for now, because there's no stat manager yet. Later they'd be read from one, so that buffs apply.
##
## Claude 2026-11-07: a placeholder until abilities exist. Its steering becomes the Walk ability, its jump becomes the Jump ability, and
## its gravity moves to the Pawn. See docs/pawn/PAWN_ARCHITECTURE.md section 9.
class_name GroundMovement
extends MovementModule

@export var max_speed := 5.0
@export var sprint_multiplier := 1.8
## How fast it reaches its speed, and stops, in metres per second per second.
@export var acceleration := 30.0
@export var deceleration := 40.0
## How much of its grip it keeps in the air. 0 is none, and 1 is the same as on the ground.
@export_range(0.0, 1.0, 0.01) var air_control := 0.3
@export var turn_rate_deg := 720.0
@export var jump_velocity := 5.0
## How strongly it falls, in metres per second per second. Below 0, it uses the project's gravity setting.
@export var gravity := -1.0

var _project_gravity: float = ProjectSettings.get_setting("physics/3d/default_gravity", 9.8)


func simulate(pawn: Pawn, dt: float) -> void:
	# Accelerate the horizontal velocity toward what's wanted.
	var speed := max_speed * (sprint_multiplier if pawn.wants_sprint else 1.0)
	var target := pawn.move_input.limit_length(1.0) * speed
	var horizontal := Vector3(pawn.velocity.x, 0.0, pawn.velocity.z)
	var rate := acceleration if target.length_squared() > 0.0001 else deceleration
	if not pawn.grounded:
		rate *= air_control
	horizontal = horizontal.move_toward(target, rate * dt)
	pawn.velocity.x = horizontal.x
	pawn.velocity.z = horizontal.z

	# Reads the pawn's own grounded, not is_on_floor(), so a replay starts from the restored value.
	if not pawn.grounded:
		pawn.velocity.y -= (gravity if gravity >= 0.0 else _project_gravity) * dt
	elif pawn.wants_jump:
		pawn.velocity.y = jump_velocity
		pawn.grounded = false

	# Face where it's moving. Godot's forward is -Z.
	if horizontal.length_squared() > 0.01:
		var target_yaw := atan2(-horizontal.x, -horizontal.z)
		pawn.yaw = rotate_toward(pawn.yaw, target_yaw, deg_to_rad(turn_rate_deg) * dt)
