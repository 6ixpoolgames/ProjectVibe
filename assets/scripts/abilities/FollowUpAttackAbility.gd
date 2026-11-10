## Written by Claude (claude-opus-5-5), 2026-11-09: a follow-up swing, for combos. A MeleeAttackAbility that can only start within
## follow_window seconds after another ability (follows, MeleeAttack by default) finishes, and that answers to the same action.
##
## How a press picks it (AbilityManager, higher priority wins): it has a lower priority than the attack it follows (-10 against 0),
## so a press starts the normal attack whenever that's ready. While the normal attack can't start (its cooldown is running), and the
## follow-up's window is open, the same press starts the follow-up instead. After the follow-up, the window closes until the normal
## attack finishes again. So with a cooldown on the normal attack: swing, press again quickly for the follow-up, then wait.
##
## The AI needs nothing extra: its Attack behaviour presses the attack action, and the manager picks, the same way as for a player.
##
## Rollback: the tick its leader last finished is rollback state, so a replay agrees with what was predicted.
class_name FollowUpAttackAbility
extends MeleeAttackAbility

## The name of the ability (its node) it follows.
@export var follows: StringName = &"MeleeAttack"
## Seconds after that ability finishes during which this one can start.
@export_range(0.0, 10.0, 0.05, "or_greater") var follow_window := 0.6

## The tick the ability it follows last finished, or -1 once this has started (or before it ever has). Rolls back.
var leader_finished_tick := -1


func _init() -> void:
	super()
	priority = -10 # below the attack it follows, so a press prefers that one
	# Quicker and lighter than the normal swing (8, 4 and 12 ticks, 20 damage).
	windup_ticks = 5
	hit_ticks = 4
	recovery_ticks = 10
	damage = 12
	knockback_speed = 4.0
	# Claude 2026-11-10, game feel: the return stroke, sweeping back the other way (left to right), with a smaller hop.
	sweep_from_left = true
	knockback_hop_speed = 1.5


# GDScript note: _enter_tree runs before any _ready, and the parent is the AbilityManager, whose signal already exists then.
func _enter_tree() -> void:
	var parent := get_parent() as AbilityManager
	if parent and not parent.ability_finished.is_connected(_on_ability_finished):
		parent.ability_finished.connect(_on_ability_finished)


func get_rollback_properties() -> Array[String]:
	var out := super()
	out.append("leader_finished_tick")
	return out


## Only within follow_window after the ability it follows finished.
func can_start() -> bool:
	if not super() or leader_finished_tick < 0 or manager == null:
		return false
	return TickDriver.tick - leader_finished_tick <= manager.ticks_for(follow_window)


func start() -> void:
	super()
	leader_finished_tick = -1 # one follow-up per normal attack


# The ability it follows finished (or was cancelled, which finishes it first): the window opens.
func _on_ability_finished(ability: AbilityBase) -> void:
	if ability.name == follows:
		leader_finished_tick = TickDriver.tick
