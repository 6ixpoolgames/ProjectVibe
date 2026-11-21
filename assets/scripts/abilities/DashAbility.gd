# Written by Claude (claude-opus-5-5), 2026-11-09. History: abilities/CHANGELOG.md.
## A short, fast burst toward the movement input: an action bound to &"dash".
##
## It adds acceleration along the dash direction for [member speed_up_seconds], then takes speed off for [member slow_down_seconds], so
## left alone the pawn ends at the speed it started with. Speed gained some other way during a dash stays. Walking, sprinting and jumping
## are locked out while it runs, and it works on the ground and in the air ([member usable_in_air]). The pawn turns to face the dash.
## [br][br]It cancels a swing, and it's invulnerable for its first 0.18 s (an [InvulnerabilityInterceptor], pawn spec 8.23). Rollback:
## [member dash_direction] rolls back with its timer and cooldown; its phase comes from [method AbilityBase.ticks_before_this_run].
## Design: pawn spec 8.6, 8.9.
class_name DashAbility
extends AbilityBase

## The stat for the speed-up's acceleration, in metres per second per second.
@export var acceleration_stat: StringName = &"DashAcceleration"
## The speed-up's acceleration when the pawn has no such stat.
@export var fallback_acceleration := 100.0
## How long it speeds up for, in seconds.
@export_range(0.0, 2.0, 0.01, "or_greater") var speed_up_seconds := 0.1
## How hard it slows down after, in metres per second per second.
@export_range(0.0, 1000.0, 1.0, "or_greater") var slow_down_deceleration := 50.0
## How long it slows down for, in seconds. The defaults take off what the speed-up added (50 x 0.2 against 100 x 0.1).
@export_range(0.0, 2.0, 0.01, "or_greater") var slow_down_seconds := 0.2
## On: it can start in the air as well as on the ground. Off: ground only.
@export var usable_in_air := true

## The way it's dashing, flat and length 1. Rolls back (pushed).
var dash_direction := Vector3.ZERO:
	set(value):
		if value == dash_direction:
			return
		dash_direction = value
		push_state(&"dash_direction", value)


func _init() -> void:
	super()
	kind = Kind.ACTION
	trigger_action = &"dash"
	# Tags are constants, so a misspelling is an error, not a warning while playing.
	category = Tags.MOVEMENT_DASH
	needs_full_movement = true # a dash is too fast for the crowd mover's checks (pawn spec 8.22)
	extra_categories = [Tags.MOVEMENT_ADVANCED] # the AI asks for this group, not for "dash"
	# Its length comes from its two phases (duration_ticks), not duration.
	duration = 0.0
	cooldown = 2.0
	# The basic movement group: walk, sprint and jump.
	locks_out = [Tags.MOVEMENT_BASIC]
	interrupt_priority = 40 # above knockback's threshold (35)
	interrupt_threshold = 25 # a knockback (30) cancels it once its invulnerability is over
	pauses_locomotion = true # Walk would otherwise slow the pawn as well


## With no interceptor of its own, a Dash is invulnerable for its first 0.18 s, so the end of its slow-down can be hit.
func make_default_interceptors() -> void:
	var dodge := InvulnerabilityInterceptor.new()
	dodge.name = "Invulnerable"
	dodge.active_seconds = 0.18
	add_child(dodge)


func get_pushed_properties() -> Array[String]:
	var out := super()
	out.append("dash_direction")
	return out


## Timed, by its two phases rather than duration.
func is_timed() -> bool:
	return true


## The speed-up's ticks plus the slow-down's.
func duration_ticks() -> int:
	return manager.ticks_for(speed_up_seconds) + manager.ticks_for(slow_down_seconds) if manager else 0


## Anywhere with usable_in_air on (the default); on the ground only with it off.
func can_start() -> bool:
	return usable_in_air or pawn.grounded


## Picks the direction (the movement input, or the facing with none) and turns the pawn to face it.
func start() -> void:
	var wanted := Vector3(move_input().x, 0.0, move_input().z)
	if wanted.length_squared() > 0.0001:
		dash_direction = wanted.normalized()
	else:
		dash_direction = Vector3(-sin(pawn.yaw), 0.0, -cos(pawn.yaw)) # the way it faces; Godot's forward is -Z
	pawn.yaw = atan2(-dash_direction.x, -dash_direction.z)


# Adds speed, then takes it away. dash_direction is flat, so the vertical speed (a jump, gravity) is left alone.
func tick(dt: float) -> void:
	if ticks_before_this_run() < manager.ticks_for(speed_up_seconds):
		pawn.velocity += dash_direction * read_stat(acceleration_stat, fallback_acceleration) * dt
		return
	# The speed along the dash direction, and how much of it to take off this tick: never more than there is, so never backwards.
	var along := pawn.velocity.dot(dash_direction)
	var slow := minf(slow_down_deceleration * dt, maxf(along, 0.0))
	pawn.velocity -= dash_direction * slow

# No stop(): whatever speed is left is kept, and Walk brings it back to walking speed.
