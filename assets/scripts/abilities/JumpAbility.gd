## Written by Claude (claude-opus-5-5), 2026-11-07: jumping. An action bound to &"jump", which happens at once. Pawn spec section 8.5.
## It replaces GroundMovement's jump.
##
## It starts from the ground, or within coyote_time of walking off an edge, which forgives a press a moment too late. A press a
## moment too early, in the air, waits buffer_window seconds and jumps on landing. Holding the key doesn't bounce, because only a
## press starts it. The height comes from the pawn's JumpVelocity stat, in metres per second upward.
class_name JumpAbility
extends AbilityBase

## Seconds after leaving the ground, without jumping, that a press still jumps.
@export_range(0.0, 1.0, 0.01) var coyote_time := 0.1

## Ticks since the pawn was last on the ground, capped at COUNT_CAP. Rolls back.
var ticks_off_ground := 0

## Kept small, so it's one byte on the network. Anything past the coyote time counts the same.
const COUNT_CAP := 100


func _init() -> void:
	super()
	kind = Kind.ACTION
	trigger_action = &"jump"
	category = &"movement.jump"
	buffer_window = 0.15


func get_rollback_properties() -> Array[String]:
	var out := super()
	out.append("ticks_off_ground")
	return out


func every_tick(_dt: float) -> void:
	ticks_off_ground = 0 if pawn.grounded else mini(ticks_off_ground + 1, COUNT_CAP)


func can_start() -> bool:
	if pawn.grounded:
		return true
	# Walked off an edge a moment ago, and not already going up.
	return ticks_off_ground <= manager.ticks_for(coyote_time) and pawn.velocity.y <= 0.0


func start() -> void:
	pawn.velocity.y = read_stat(&"JumpVelocity", 5.0)
	pawn.grounded = false
	ticks_off_ground = COUNT_CAP # so coyote time can't give a second jump
