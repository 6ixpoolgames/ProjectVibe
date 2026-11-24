# Written by Claude (claude-opus-5-5), 2026-11-09. History: abilities/CHANGELOG.md.
## Being pushed by a hit: an action with no trigger action, started by [code]event.reaction.knockback[/code], which a
## [KnockbackEffector] sends with the push ([KnockbackEventData]); code can push with [method push].
##
## It lives on the pawn being hit. For the push's duration it sets the pawn's horizontal velocity to the push, fading in a straight line
## to nothing, and locks out movement and combat. A push with a hop speed lifts a grounded pawn on its first tick (not one already in the
## air); the hop can outlast the push. A second hit while it runs starts it again with the new push. Only Dash cancels it.
## [br][br]Rollback: [member push_velocity] and [member push_ticks] roll back with its timer, so a corrected client replays the push.
## Design: pawn spec 8.6, 8.9.
class_name KnockbackAbility
extends AbilityBase

## The push at the start, in metres per second; its y is the hop speed upward. Rolls back (pushed).
var push_velocity := Vector3.ZERO:
	set(value):
		if value == push_velocity:
			return
		push_velocity = value
		push_state(&"push_velocity", value)
## How many ticks this push lasts. Rolls back (pushed).
var push_ticks := 0:
	set(value):
		if value == push_ticks:
			return
		push_ticks = value
		push_state(&"push_ticks", value)


## Its kind's defaults: a new [KnockbackDefinition].
func make_default_definition() -> AbilityDefinition:
	return KnockbackDefinition.new()


func get_pushed_properties() -> Array[String]:
	var out := super()
	out.append_array(["push_velocity", "push_ticks"])
	return out


## Timed, by its push's length rather than duration.
func is_timed() -> bool:
	return true


func run_length_ticks() -> int:
	return push_ticks


## Takes the push from its event before it starts (its length decides how long it runs).
func prepare_from_event(event: GameplayEventData) -> void:
	var push_data := event as KnockbackEventData
	if push_data:
		push_velocity = Vector3(push_data.push_velocity.x, maxf(push_data.hop_speed, 0.0), push_data.push_velocity.z)
		push_ticks = push_data.push_ticks


## Starts a push from code; hop is the upward speed in metres per second (0: none). Returns false if something stronger is running.
func push(velocity: Vector3, ticks: int, hop: float = 0.0) -> bool:
	if ticks <= 0 or velocity.length_squared() < 0.0001:
		return false
	push_velocity = Vector3(velocity.x, maxf(hop, 0.0), velocity.z)
	push_ticks = ticks
	return manager.start_ability(self) if manager else false


func tick(_dt: float) -> void:
	# The hop, on the first tick, as Jump does it.
	var before := ticks_before_this_run()
	if before == 0 and push_velocity.y > 0.0 and pawn.grounded:
		pawn.velocity.y = push_velocity.y
		pawn.grounded = false
	var left := float(push_ticks - before) / maxf(float(push_ticks), 1.0) # 1 at the start, falling toward 0
	pawn.velocity.x = push_velocity.x * left
	pawn.velocity.z = push_velocity.z * left
