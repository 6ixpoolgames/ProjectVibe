## Written by Claude (claude-opus-5-5), 2026-11-09: one tunable state for every "how aware am I of an enemy" situation. Pawn spec
## section 10.6. The default Alert and Combat are two nodes running this script with different settings, so a designer makes a new
## awareness state, say a jumpy "Startled", by adding a node and filling in the settings, with no code.
##
## Its prerequisites hold when the entry it looks at (the current target, or any entry in memory) meets every setting:
##   min_awareness          awareness now is at least this
##   requires_certain       the entry became certain (reached full awareness) at some point
##   max_ticks_since_seen   it was seen within this many ticks (-1: any time)
## Step 10 adds being hit: "or hit within N ticks by a known (or unknown) attacker". Not built yet.
class_name AIAwarenessState
extends AIStateBase

enum LooksAt {
	CURRENT_TARGET, ## the target the target selector picked
	ANY_ENTRY, ## any entry in memory
}

## Which entries it looks at.
@export var looks_at := LooksAt.ANY_ENTRY
## Awareness it needs, 0 to 1.
@export_range(0.0, 1.0, 0.01) var min_awareness := 0.3
## On: only entries that became certain count.
@export var requires_certain := false
## Only entries seen within this many ticks count. -1: any time.
@export_range(-1, 36000, 1, "or_greater") var max_ticks_since_seen := -1


func prerequisites_met(context: AIContextComponent) -> bool:
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
