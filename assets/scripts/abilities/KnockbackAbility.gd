# Written by Claude (claude-opus-5-5), 2026-11-09. History: abilities/CHANGELOG.md.
## Being pushed by a hit: an action with no trigger action, started by a KnockbackPart through [method push].
##
## Pawn spec sections 8.6 and 8.9. It lives on the pawn being hit and moves it through that pawn's own movement (the owner's call):
## for its duration it sets the pawn's horizontal velocity to the push, fading in a straight line to nothing, and locks out movement
## and combat, so the pawn can't steer or attack while staggered.
## [br]
## Interrupts: with interrupt_priority 30 it cancels a running MeleeAttack (threshold 15) and a Dash past its invulnerable start
## (threshold 25). Its own threshold, 35, means only a Dash (40) cancels it: the one way out of a stagger.
## [br]
## A small hop back (the owner's request): a push with a hop speed lifts the pawn on its first tick, as a jump does, if it's on the
## ground; then gravity brings it down. A pawn already in the air isn't lifted again, so several hits in a row can't keep it up. The
## hop can outlast the push: once the push is over, the pawn finishes its hop under its own air control.
## [br]
## Rollback: the push and its length are rollback state, with its timer, so a client whose pawn is knocked back gets corrected and
## replays it the same way. A second hit while it runs starts it again with the new push.
class_name KnockbackAbility
extends AbilityBase

## The push at the start, in metres per second; its y is the hop speed upward. Rolls back.
var push_velocity := Vector3.ZERO
## How many ticks this push lasts. Rolls back.
var push_ticks := 0


func _init() -> void:
	super()
	kind = Kind.ACTION
	# Tags as Tags constants (tags/Tags.gd), so a misspelling is an error, not a warning while playing.
	category = Tags.COMBAT_KNOCKBACK
	needs_full_movement = true # a push should collide properly, and may lift (pawn spec 8.22)
	locks_out = [Tags.MOVEMENT, Tags.COMBAT]
	interrupt_priority = 30
	# The owner's call: only Dash (40) cancels a knockback. Walking, sprinting, jumping and attacking stay locked out.
	interrupt_threshold = 35


func get_rollback_properties() -> Array[String]:
	var out := super()
	out.append_array(["ticks_left", "push_velocity", "push_ticks"])
	return out


func duration_ticks() -> int:
	return push_ticks


## Starts a push. hop is how fast it lifts the pawn, in metres per second upward; 0 for none. Returns false if something stronger is
## running and it couldn't start.
func push(velocity: Vector3, ticks: int, hop: float = 0.0) -> bool:
	if ticks <= 0 or velocity.length_squared() < 0.0001:
		return false
	push_velocity = Vector3(velocity.x, maxf(hop, 0.0), velocity.z)
	push_ticks = ticks
	return manager.start_ability(self) if manager else false


func tick(_dt: float) -> void:
	# The hop, on the first tick (the manager counts ticks_left down after each tick, so it's still push_ticks).
	# As JumpAbility does: upward speed, and not on the ground any more, so the pawn's gravity starts next tick.
	if ticks_left == push_ticks and push_velocity.y > 0.0 and pawn.grounded:
		pawn.velocity.y = push_velocity.y
		pawn.grounded = false
	var left := float(ticks_left) / maxf(float(push_ticks), 1.0) # 1 at the start, falling toward 0
	pawn.velocity.x = push_velocity.x * left
	pawn.velocity.z = push_velocity.z * left
