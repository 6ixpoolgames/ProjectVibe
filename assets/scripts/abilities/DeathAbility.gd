## Written by Claude (claude-opus-5-5), 2026-11-09: being dead. An action with no trigger action: the pawn starts it when its Health
## stat reaches 0 (Pawn.receive_hit). Pawn spec section 8.7, step 10. The owner's call: death is an ability, not a separate manager.
##
## While it runs:
##   - it locks out movement, combat and utility, so Walk stops steering (the body slows to a stop and falls) and nothing else starts;
##   - its interrupt_priority, 1000, cancels whatever was running when it started, and its interrupt_threshold, 1000, means nothing
##     cancels it;
##   - Pawn.is_dead() is true: the pawn ignores its input and its AI, other pawns' sensing ignores it, and memories forget it.
## It keeps itself running for as long as Health is 0. Pawn.revive() fills Health again, and it ends on its next tick.
##
## The body stays where it falls. Removing it, playing a death animation or respawning are game rules, for game code listening to
## Pawn.died or AbilityManager.ability_started.
##
## Rollback: its timer is rollback state, with Health, so clients see the pawn dead from snapshots.
class_name DeathAbility
extends AbilityBase

## The stat that, at 0, keeps the pawn dead.
@export var health_stat: StringName = &"Health"


func _init() -> void:
	super()
	kind = Kind.ACTION
	category = &"status.dead"
	locks_out = [&"movement", &"combat", &"utility"]
	interrupt_priority = 1000
	interrupt_threshold = 1000


func get_rollback_properties() -> Array[String]:
	var out := super()
	out.append("ticks_left")
	return out


# Claude 2026-11-09 (scaling spec step 4): keeps Pawn.dead current, a plain value that C++ (sensing, memory) reads directly, instead
# of calling Pawn.is_dead() through GDScript for every pawn it looks at, which was about a third of sensing's cost.
func _running_changed(running: bool) -> void:
	if pawn:
		pawn.dead = running


# One tick at a time: each tick it adds one back for as long as Health is 0, so it never runs out while the pawn is dead.
func duration_ticks() -> int:
	return 1


func tick(_dt: float) -> void:
	var stats := pawn.stat_manager if pawn else null
	if stats == null or stats.get_current(health_stat, 0.0) <= 0.0:
		ticks_left += 1 # the manager takes one away after this, so it stays running
