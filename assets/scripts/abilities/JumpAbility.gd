# Written by Claude (claude-opus-5-5), 2026-11-07. History: abilities/CHANGELOG.md.
## Jumping: an action bound to &"jump", which happens at once.
##
## It starts from the ground, or within [member coyote_time] of walking off an edge. A press a moment too early waits [member buffer_window]
## seconds and jumps on landing; holding the key doesn't bounce, because only a press starts it. Height comes from the pawn's JumpVelocity
## stat, in metres per second upward. Rollback: [member ticks_off_ground].
## Design: pawn spec 8.5.
class_name JumpAbility
extends AbilityBase

## Seconds after leaving the ground, without jumping, that a press still jumps.
@export_range(0.0, 1.0, 0.01) var coyote_time := 0.1

## Ticks since the pawn was last on the ground, capped at COUNT_CAP. Rolls back.
var ticks_off_ground := 0

## The cap on [member ticks_off_ground], so it's one byte on the network. Anything past the coyote time counts the same.
const COUNT_CAP := 100


func _init() -> void:
	super()
	kind = Kind.ACTION
	trigger_action = &"jump"
	# Tags are constants, so a misspelling is an error, not a warning while playing.
	category = Tags.MOVEMENT_JUMP
	extra_categories = [Tags.MOVEMENT_BASIC]
	buffer_window = 0.15
	interrupt_priority = 5 # between Walk (0) and Sprint (10)


func get_rollback_properties() -> Array[String]:
	var out := super()
	out.append("ticks_off_ground")
	return out


func every_tick(_dt: float) -> void:
	ticks_off_ground = 0 if pawn.grounded else mini(ticks_off_ground + pawn.ticks_elapsed, COUNT_CAP) # every tick this run covers


## True while [member ticks_off_ground] is 0: a sleeping pawn is grounded, so it would only keep it there (pawn spec 15.3).
func can_sleep() -> bool:
	return ticks_off_ground == 0


func can_start() -> bool:
	if pawn.grounded:
		return true
	# Walked off an edge a moment ago, and not already going up.
	return ticks_off_ground <= manager.ticks_for(coyote_time) and pawn.velocity.y <= 0.0


func start() -> void:
	pawn.velocity.y = read_stat(&"JumpVelocity", 5.0)
	pawn.grounded = false
	ticks_off_ground = COUNT_CAP # so coyote time can't give a second jump
