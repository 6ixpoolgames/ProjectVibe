## Written by Claude (claude-opus-5-5), 2026-11-04: example state, ported from AIStateManager_enum's check_aggresive().
## Valid while memory holds a strong (recent) threat. The old version used "in line of sight right now";
## reading memory instead means it stays aggressive briefly after losing sight, then drops to Alerted.
## No memory = never aggressive (escape clause).
extends AIStateComponentBase
class_name AggressiveState

@export var threat_fact: StringName = &"pawn_seen" ## memory fact type that counts as a threat
@export var min_confidence: float = 0.8 ## at the default 5 s memory half-life: about 1.6 s after last sighting


func _init() -> void:
	state_priority = 20


func is_valid(context: AIContext) -> bool:
	return context.memory != null and context.memory.has_fact(threat_fact, min_confidence)
