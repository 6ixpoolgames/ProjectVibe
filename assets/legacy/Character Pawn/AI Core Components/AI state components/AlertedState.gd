## Written by Claude (claude-opus-5-5), 2026-11-04: example state, ported from AIStateManager_enum's check_alerted().
## Valid while memory holds any non-faint threat: "something was here recently".
## Sits below Aggressive, so it takes over as a sighting fades. No memory = never alerted (escape clause).
extends AIStateComponentBase
class_name AlertedState

@export var threat_fact: StringName = &"pawn_seen" ## memory fact type that counts as a threat
@export var min_confidence: float = 0.2 ## at the default 5 s memory half-life: about 11.6 s after last sighting


func _init() -> void:
	state_priority = 30


func is_valid(context: AIContext) -> bool:
	return context.memory != null and context.memory.has_fact(threat_fact, min_confidence)
