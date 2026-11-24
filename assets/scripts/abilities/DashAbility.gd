# Written by Claude (claude-opus-5-5), 2026-11-09. History: abilities/CHANGELOG.md.
## A short, fast burst toward the movement input: an action bound to &"dash".
##
## It adds acceleration along the dash direction for [member speed_up_ticks], then takes speed off for [member slow_down_ticks], so
## left alone the pawn ends at the speed it started with. Speed gained some other way during a dash stays. Walking, sprinting and jumping
## are locked out while it runs, and it works on the ground and in the air ([member usable_in_air]). The pawn turns to face the dash.
## [br][br]It cancels a swing, and it's invulnerable for its first 0.18 s (an [InvulnerabilityInterceptor], pawn spec 8.23). Rollback:
## [member dash_direction] rolls back with its timer and cooldown; its phase comes from [method AbilityBase.ticks_before_this_run].
## Design: pawn spec 8.6, 8.9.
class_name DashAbility
extends AbilityBase

# Its settings with their own type: the same object as settings.
var _dash: DashDefinition = null

# Its settings, read from its definition (ability spec 3). Writing one is for a script's _init(); see AbilityBase._write_setting.
## From the definition: [member DashDefinition.acceleration_stat].
var acceleration_stat: StringName:
	get:
		if _dash == null:
			prepare_settings()
		return _dash.acceleration_stat
	set(value):
		_write_setting(&"acceleration_stat", value)
## From the definition: [member DashDefinition.fallback_acceleration].
var fallback_acceleration: float:
	get:
		if _dash == null:
			prepare_settings()
		return _dash.fallback_acceleration
	set(value):
		_write_setting(&"fallback_acceleration", value)
## From the definition: [member DashDefinition.speed_up_ticks].
var speed_up_ticks: int:
	get:
		if _dash == null:
			prepare_settings()
		return _dash.speed_up_ticks
	set(value):
		_write_setting(&"speed_up_ticks", value)
## From the definition: [member DashDefinition.slow_down_deceleration].
var slow_down_deceleration: float:
	get:
		if _dash == null:
			prepare_settings()
		return _dash.slow_down_deceleration
	set(value):
		_write_setting(&"slow_down_deceleration", value)
## From the definition: [member DashDefinition.slow_down_ticks].
var slow_down_ticks: int:
	get:
		if _dash == null:
			prepare_settings()
		return _dash.slow_down_ticks
	set(value):
		_write_setting(&"slow_down_ticks", value)
## From the definition: [member DashDefinition.usable_in_air].
var usable_in_air: bool:
	get:
		if _dash == null:
			prepare_settings()
		return _dash.usable_in_air
	set(value):
		_write_setting(&"usable_in_air", value)

## The way it's dashing, flat and length 1. Rolls back (pushed).
var dash_direction := Vector3.ZERO:
	set(value):
		if value == dash_direction:
			return
		dash_direction = value
		push_state(&"dash_direction", value)


## Its kind's defaults: a new [DashDefinition].
func make_default_definition() -> AbilityDefinition:
	return DashDefinition.new()


func _settings_changed() -> void:
	super()
	_dash = settings as DashDefinition


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
func run_length_ticks() -> int:
	return TickDriver.ticks_at_rate(speed_up_ticks) + TickDriver.ticks_at_rate(slow_down_ticks)


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
	if ticks_before_this_run() < TickDriver.ticks_at_rate(speed_up_ticks):
		pawn.velocity += dash_direction * read_stat(acceleration_stat, fallback_acceleration) * dt
		return
	# The speed along the dash direction, and how much of it to take off this tick: never more than there is, so never backwards.
	var along := pawn.velocity.dot(dash_direction)
	var slow := minf(slow_down_deceleration * dt, maxf(along, 0.0))
	pawn.velocity -= dash_direction * slow

# No stop(): whatever speed is left is kept, and Walk brings it back to walking speed.
