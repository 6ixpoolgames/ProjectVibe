## Written by Claude (claude-opus-5-5), 2026-11-04: example state, replaces AIStateManager_enum's isIncapacitated flag.
## Never valid on its own: other systems (stuns from combat, cutscenes) put a pawn here with
## aiStateManager.force_state(&"Incapacitated", seconds). When the time runs out, normal evaluation resumes.
extends AIStateComponentBase
class_name IncapacitatedState


func _init() -> void:
	state_priority = 1


func enter(context: AIContext) -> void:
	context.stop_moving()
