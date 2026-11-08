## Written by Claude (claude-opus-5-5), 2026-11-09: one tunable state for every "how aware am I of an enemy" situation. Pawn spec
## section 10.6. The default Alert and Combat are two nodes running this script with different settings, so a designer makes a new
## awareness state, say a jumpy "Startled", by adding a node and filling in the settings, with no code.
##
## Its prerequisites hold when the entry it looks at (the current target, or any entry in memory) meets every setting:
##   min_awareness          awareness now is at least this
##   requires_certain       the entry became certain (reached full awareness) at some point
##   max_ticks_since_seen   it was seen within this many ticks (-1: any time)
## Claude 2026-11-09, step 10: or, separately, the pawn was hit recently:
##   hit_within_ticks       hit within this many ticks (-1: off)
##   attacker               KNOWN: the attacker is in memory; UNKNOWN: it isn't; ANY: either
## So Combat holds when a known attacker hits, and Alert when an unknown one does: the owner's rule, with no damage sense.
class_name AIAwarenessState
extends AIStateBase

enum LooksAt {
	CURRENT_TARGET, ## the target the target selector picked
	ANY_ENTRY, ## any entry in memory
}

## Claude 2026-11-09: which attackers count for the hit rule.
enum Attacker {
	ANY, ## any attacker
	KNOWN, ## one the pawn has in memory
	UNKNOWN, ## one it doesn't
}

## Which entries it looks at.
@export var looks_at := LooksAt.ANY_ENTRY
## Awareness it needs, 0 to 1.
@export_range(0.0, 1.0, 0.01) var min_awareness := 0.3
## On: only entries that became certain count.
@export var requires_certain := false
## Only entries seen within this many ticks count. -1: any time.
@export_range(-1, 36000, 1, "or_greater") var max_ticks_since_seen := -1
## Claude 2026-11-09: or the pawn was hit within this many ticks, by an attacker of the kind below. -1: off.
@export_range(-1, 36000, 1, "or_greater") var hit_within_ticks := -1
## Claude 2026-11-09: which attackers count for hit_within_ticks.
@export var attacker := Attacker.ANY


func prerequisites_met(context: AIContextComponent) -> bool:
	if _hit_fits(context):
		return true
	var memory := context.memory
	if memory == null:
		return false
	if looks_at == LooksAt.CURRENT_TARGET:
		var index := context.current_target_index()
		return index >= 0 and _entry_fits(memory, index, context.current_tick)
	for i in memory.entry_count():
		if _entry_fits(memory, i, context.current_tick):
			return true
	return false


func _entry_fits(memory: AIMemory, index: int, tick: int) -> bool:
	if requires_certain and not memory.is_certain_at(index):
		return false
	if max_ticks_since_seen >= 0 and memory.ticks_since_seen_at(index, tick) > max_ticks_since_seen:
		return false
	return memory.awareness_at(index, tick) >= min_awareness


# Claude 2026-11-09: the hit rule.
func _hit_fits(context: AIContextComponent) -> bool:
	if hit_within_ticks < 0 or not context.was_hit_within(hit_within_ticks):
		return false
	match attacker:
		Attacker.KNOWN:
			return context.last_attacker_is_known()
		Attacker.UNKNOWN:
			return not context.last_attacker_is_known()
		_:
			return true
