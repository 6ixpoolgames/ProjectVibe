## Written by Claude (claude-opus-5-5), 2026-11-04: example state, ported from AIStateManager_enum's check_routed().
## Enters when health drops below rout_below while a threat is remembered.
## Stays until health recovers above recover_above (the old version could never leave Routed).
## The gap between the two thresholds stops it flickering in and out at the boundary.
## No health stat or no memory = never routed (escape clause).
extends AIStateComponentBase
class_name RoutedState

@export var health_stat: String = "Health"
@export var rout_below: float = 0.15 ## fraction of max health that triggers routing
@export var recover_above: float = 0.4 ## fraction of max health needed to stop routing
@export var threat_fact: StringName = &"pawn_seen" ## memory fact type that counts as a threat
@export var threat_min_confidence: float = 0.5


func _init() -> void:
	state_priority = 10


func is_valid(context: AIContext) -> bool:
	var health := context.get_stat_fraction(health_stat, 1.0)
	if isCurrent:
		return health < recover_above
	return health < rout_below and context.memory != null and context.memory.has_fact(threat_fact, threat_min_confidence)
