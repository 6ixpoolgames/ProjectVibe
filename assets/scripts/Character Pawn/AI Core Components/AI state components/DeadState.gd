## Written by Claude (claude-opus-5-5), 2026-11-04: example state, ported from AIStateManager_enum's check_dead().
## Valid when the health stat is 0 or below. Permanent: can_exit() is false, so not even force_state() leaves it.
## No health stat on the pawn = never dead (escape clause).
extends AIStateComponentBase
class_name DeadState

@export var health_stat: String = "Health"


func _init() -> void:
	state_priority = 0


func is_valid(context: AIContext) -> bool:
	return context.get_stat(health_stat, INF) <= 0.0


func can_exit(_context: AIContext) -> bool:
	return false


func enter(context: AIContext) -> void:
	context.stop_moving()
