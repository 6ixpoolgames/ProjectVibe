# Written by Claude (claude-opus-5-5), 2026-11-07. History: abilities/CHANGELOG.md.
## Jumping: an action bound to &"jump", which happens at once.
##
## It starts from the ground, or within [member coyote_time] of walking off an edge. A press a moment too early waits [member buffer_window]
## seconds and jumps on landing; holding the key doesn't bounce, because only a press starts it. Height comes from the pawn's JumpVelocity
## stat, in metres per second upward. Rollback: [member left_ground_at].
## Design: pawn spec 8.5.
class_name JumpAbility
extends AbilityBase

## Seconds after leaving the ground, without jumping, that a press still jumps.
@export_range(0.0, 1.0, 0.01) var coyote_time := 0.1

## The last tick the pawn was known to be on the ground before it left it; [constant ON_GROUND] while it's there. Rolls back (pushed).
var left_ground_at := ON_GROUND:
	set(value):
		if value == left_ground_at:
			return
		left_ground_at = value
		push_state(&"left_ground_at", value)

## [member left_ground_at] while the pawn is on the ground.
const ON_GROUND := -(1 << 62)
## The most [method ticks_off_ground] counts. Anything past the coyote time counts the same.
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


func get_pushed_properties() -> Array[String]:
	var out := super()
	out.append("left_ground_at")
	return out


## Ticks since the pawn was last on the ground, up to [constant COUNT_CAP]; 0 on the ground.
func ticks_off_ground() -> int:
	return 0 if left_ground_at == ON_GROUND else mini(TickDriver.tick - left_ground_at, COUNT_CAP)


func every_tick(_dt: float) -> void:
	if pawn.grounded:
		left_ground_at = ON_GROUND
	elif left_ground_at == ON_GROUND:
		left_ground_at = TickDriver.tick - pawn.ticks_elapsed # off the ground for every tick this run covers


## True while on the ground: a sleeping pawn is grounded, so it would only keep it there (pawn spec 15.3).
func can_sleep() -> bool:
	return left_ground_at == ON_GROUND


func can_start() -> bool:
	if pawn.grounded:
		return true
	# Walked off an edge a moment ago, and not already going up.
	return ticks_off_ground() <= manager.ticks_for(coyote_time) and pawn.velocity.y <= 0.0


func start() -> void:
	pawn.velocity.y = read_stat(&"JumpVelocity", 5.0)
	pawn.grounded = false
	left_ground_at = TickDriver.tick - COUNT_CAP # so coyote time can't give a second jump
