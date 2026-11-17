# Written by Claude (claude-opus-5-5), 2026-11-09. History: abilities/CHANGELOG.md.
## Being pushed by a hit: an action with no trigger action, started by a KnockbackPart through [method push].
##
## It lives on the pawn being hit. For the push's duration it sets the pawn's horizontal velocity to the push, fading in a straight line
## to nothing, and locks out movement and combat. A push with a hop speed lifts a grounded pawn on its first tick (not one already in the
## air); the hop can outlast the push. A second hit while it runs starts it again with the new push. Only Dash cancels it.
## [br][br]Rollback: [member push_velocity] and [member push_ticks] roll back with its timer, so a corrected client replays the push.
## Design: pawn spec 8.6, 8.9.
class_name KnockbackAbility
extends AbilityBase

## The push at the start, in metres per second; its y is the hop speed upward. Rolls back.
var push_velocity := Vector3.ZERO
## How many ticks this push lasts. Rolls back.
var push_ticks := 0


func _init() -> void:
	super()
	kind = Kind.ACTION
	# Tags are constants, so a misspelling is an error, not a warning while playing.
	category = Tags.COMBAT_KNOCKBACK
	needs_full_movement = true # a push should collide properly, and may lift (pawn spec 8.22)
	locks_out = [Tags.MOVEMENT, Tags.COMBAT]
	interrupt_priority = 30
	interrupt_threshold = 35 # only Dash (40) cancels it


func get_rollback_properties() -> Array[String]:
	var out := super()
	out.append_array(["ticks_left", "push_velocity", "push_ticks"])
	return out


func duration_ticks() -> int:
	return push_ticks


## Starts a push; hop is the upward speed in metres per second (0: none). Returns false if something stronger is running.
func push(velocity: Vector3, ticks: int, hop: float = 0.0) -> bool:
	if ticks <= 0 or velocity.length_squared() < 0.0001:
		return false
	push_velocity = Vector3(velocity.x, maxf(hop, 0.0), velocity.z)
	push_ticks = ticks
	return manager.start_ability(self) if manager else false


func tick(_dt: float) -> void:
	# The hop, on the first tick (the manager counts ticks_left down after each tick, so it's still push_ticks), as Jump does it.
	if ticks_left == push_ticks and push_velocity.y > 0.0 and pawn.grounded:
		pawn.velocity.y = push_velocity.y
		pawn.grounded = false
	var left := float(ticks_left) / maxf(float(push_ticks), 1.0) # 1 at the start, falling toward 0
	pawn.velocity.x = push_velocity.x * left
	pawn.velocity.z = push_velocity.z * left
