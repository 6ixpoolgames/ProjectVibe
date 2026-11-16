## Written by Claude (claude-opus-5-5), 2026-11-09: being dead. An action with no trigger action: the pawn starts it when its Health
## stat reaches 0 (Pawn.receive_hit). Pawn spec section 8.7, step 10. The owner's call: death is an ability, not a separate manager.
##
## While it runs:
##   - it locks out movement, combat and utility, so Walk stops steering (the body slows to a stop and falls) and nothing else starts;
##   - its interrupt_priority, 1000, cancels whatever was running when it started, and its interrupt_threshold, 1000, means nothing
##     cancels it;
##   - Pawn.is_dead() is true: the pawn ignores its input and its AI, other pawns' sensing ignores it, and memories forget it.
## It keeps itself running for as long as Health is 0. AbilityManager.revive() (Pawn's until pawn M3) fills Health again, and it ends on its next tick.
##
## The body stays where it falls. Removing it, playing a death animation or respawning are game rules, for game code listening to
## AbilityManager.died (Pawn's until pawn M3) or AbilityManager.ability_started.
##
## Rollback: its timer is rollback state, with Health, so clients see the pawn dead from snapshots.
class_name DeathAbility
extends AbilityBase

# Claude 2026-11-17 (the owner's call): health_stat is gone. Death watches the one Health stat (StatManager.HEALTH), the same one hits
# and the EffectManager's death check read; a setting here would only have let the two disagree.


func _init() -> void:
	super()
	kind = Kind.ACTION
	# Claude 2026-11-10: tags as Tags constants (tags/Tags.gd), so a misspelling is an error, not a warning while playing.
	category = Tags.STATUS_DEAD
	locks_out = [Tags.MOVEMENT, Tags.COMBAT, Tags.UTILITY]
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


# Claude 2026-11-16 (wider audit): a corpse lying still may sleep: Death only waits for Health to come back. The moment it does
# (revive), this answers false, the pawn wakes on its next tick, and Death ends as before.
func can_sleep_while_running() -> bool:
	return _health_is_gone()


func _health_is_gone() -> bool:
	var stats := pawn.stat_manager if pawn else null
	return stats == null or stats.get_health() <= 0.0


func tick(_dt: float) -> void:
	if _health_is_gone():
		ticks_left += ticks_elapsed() # the manager takes as many away after this, so it stays running (Claude 2026-11-16: was 1)
