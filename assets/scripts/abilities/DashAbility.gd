# Written by Claude (claude-opus-5-5), 2026-11-09. History: abilities/CHANGELOG.md.
## A short, fast burst toward the movement input: an action bound to &"dash".
##
## Pawn spec sections 8.6 and 8.9, the owner's design. Two phases, worked by acceleration instead of setting the speed:
## [br]1. Speed-up: for [member speed_up_seconds] (0.1 s) it adds acceleration along the dash direction: the DashAcceleration stat,
##   100 m/s^2, so +10 m/s.
## [br]2. Slow-down: for [member slow_down_seconds] (0.2 s) it takes [member slow_down_deceleration] (50 m/s^2) off the speed along the
##   dash direction, so -10 m/s, but never below 0 along it: it never pushes the pawn backwards.
## [br]
## Left alone, the pawn ends at the speed it started with: standing, it peaks at 10 m/s and covers about 1.5 m; walking (5 m/s),
## 15 m/s and about 3 m; sprinting (9 m/s), 19 m/s and about 4.2 m. Speed across the dash direction is left as it was. It adds and
## takes away speed instead of setting it, and the slow-down lasts a fixed time instead of aiming at a speed, so speed gained some
## other way during a dash is still there when it ends: room for movement tech. After it, Walk brings the pawn back to walking speed
## at its own rate.
## [br]
## While it runs, walking, sprinting and jumping are locked out (a jump can't cancel it), and pauses_locomotion keeps Walk from
## slowing the pawn as well, so the two don't fight. It works on the ground and in the air ([member usable_in_air]); gravity pulls as
## usual. Direction: the way the movement input points; only with no input, the way the pawn faces. The pawn turns to face the dash.
## [br]
## Interrupts and invulnerability (the owner's calls): interrupt_priority 40, so it cancels a swing (15), a knockback (35) and a
## parry (20). It's invulnerable for its first 0.18 s (an InvulnerabilityInterceptor, pawn spec 8.23): hits don't land at all. After
## that, a hit lands and its knockback (30) cancels the rest of the dash, through interrupt_threshold 25.
## [br]
## Rollback: its direction is rollback state, with its timer and cooldown, so a corrected replay dashes the same way. Where it is in
## its run comes from its timer (ticks_running), so it needs nothing more.
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
## How long it slows down for, in seconds. With the defaults, 50 x 0.2 takes off the 10 m/s that 100 x 0.1 added.
@export_range(0.0, 2.0, 0.01, "or_greater") var slow_down_seconds := 0.2
## On (the default): it can start in the air as well as on the ground. Off: ground only.
@export var usable_in_air := true

## The way it's dashing, flat and length 1. Rolls back.
var dash_direction := Vector3.ZERO


func _init() -> void:
	super()
	kind = Kind.ACTION
	trigger_action = &"dash"
	# Tags as Tags constants (tags/Tags.gd), so a misspelling is an error, not a warning while playing.
	category = Tags.MOVEMENT_DASH
	needs_full_movement = true # a dash is too fast for the crowd mover's checks (pawn spec 8.22)
	extra_categories = [Tags.MOVEMENT_ADVANCED] # the AI asks for this group, not for "dash"
	# Its length comes from its two phases (duration_ticks), not duration.
	duration = 0.0
	cooldown = 2.0
	# The basic movement group: walk, sprint and jump.
	locks_out = [Tags.MOVEMENT_BASIC]
	interrupt_priority = 40 # above knockback's threshold (35)
	# A knockback (30) cancels it, once its invulnerability is over.
	interrupt_threshold = 25
	# Its invulnerability is an InvulnerabilityInterceptor; see make_default_interceptors.
	pauses_locomotion = true # Walk would otherwise slow the pawn as well


## With no interceptor of its own, a Dash is invulnerable for its first 0.18 s (the owner's call), so the end of its slow-down can be
## hit. Give it an InvulnerabilityInterceptor child to change that.
func make_default_interceptors() -> void:
	var dodge := InvulnerabilityInterceptor.new()
	dodge.name = "Invulnerable"
	dodge.active_seconds = 0.18
	add_child(dodge)


func get_rollback_properties() -> Array[String]:
	var out := super()
	out.append("ticks_left") # duration is 0, so the base doesn't know it's timed
	out.append("dash_direction")
	return out


## The speed-up's ticks and the slow-down's.
func duration_ticks() -> int:
	return manager.ticks_for(speed_up_seconds) + manager.ticks_for(slow_down_seconds) if manager else 0


## Anywhere with usable_in_air on (the default); on the ground only with it off.
func can_start() -> bool:
	return usable_in_air or pawn.grounded


## The way the movement input points; the facing only when there's no input. Then the pawn turns to face the dash.
func start() -> void:
	var wanted := Vector3(move_input().x, 0.0, move_input().z)
	if wanted.length_squared() > 0.0001:
		dash_direction = wanted.normalized()
	else:
		dash_direction = Vector3(-sin(pawn.yaw), 0.0, -cos(pawn.yaw)) # the way it faces; Godot's forward is -Z
	pawn.yaw = atan2(-dash_direction.x, -dash_direction.z)


# Adds speed, then takes it away. dash_direction is flat, so the vertical speed (a jump, gravity) is left alone.
func tick(dt: float) -> void:
	if ticks_running() < manager.ticks_for(speed_up_seconds):
		pawn.velocity += dash_direction * read_stat(acceleration_stat, fallback_acceleration) * dt
		return
	# The speed along the dash direction, and how much of it to take off this tick: never more than there is, so never backwards.
	var along := pawn.velocity.dot(dash_direction)
	var slow := minf(slow_down_deceleration * dt, maxf(along, 0.0))
	pawn.velocity -= dash_direction * slow

# No stop(): whatever speed is left is kept, and Walk brings it back to walking speed.
