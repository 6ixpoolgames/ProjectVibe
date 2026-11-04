## Written by Claude (claude-opus-5-5), 2026-11-03: AI working memory. Lives under AICoreComponent next to sensing.
## Senses WRITE facts here (record()), decision code (states, behaviours) READS from here, never from raw sensing.
## Facts fade over time unless refreshed, so a pawn remembers "enemy was last seen there, 4 s ago" after losing sight.
##
## Extending it:
##  - new fact kinds need no code: just record() a new type name, e.g. &"heard_noise"
##  - per-type fade speed: half_life_by_type in the inspector, e.g. {"pawn_seen": 10.0}
##  - custom rules: subclass and override _get_half_life() / _should_forget()
## Works without an AI core too (it just skips registration), which is what the headless test relies on.
extends Node
class_name AIMemoryComponent

signal fact_added(fact: AIMemoryFact) ## a new fact was recorded
signal fact_refreshed(fact: AIMemoryFact) ## an existing fact was updated by a sense
signal fact_forgotten(fact: AIMemoryFact) ## a fact faded out, was evicted, or forget() was called

#node references
var pawn: CharacterPawn3D
var nexus: PawnNexusComponent
var aiCore: AICoreComponent

@export var isPremade:= false
@export var update_interval: float = 0.25 ##seconds between fade passes. Memory doesn't need to update every frame
@export var default_half_life: float = 5.0 ##seconds for an un-refreshed fact's confidence to halve
@export var half_life_by_type: Dictionary = {} ##per-type override of default_half_life, e.g. {"pawn_seen": 10.0}
@export var forget_below: float = 0.05 ##facts with confidence under this are forgotten
@export var forget_when_subject_freed:= true ##forget facts whose subject node no longer exists
@export var max_facts: int = 64 ##when full, the least confident fact is dropped to make room
@export var anonymous_merge_radius: float = 2.0 ##facts with no subject (e.g. noises) of the same type this close together count as one
@export var debug_draw:= false ##draws a point at each fact's position, redder = more confident

var facts: Array[AIMemoryFact] = []
var _timeSinceUpdate: float = 0.0


func _enter_tree() -> void:
	if get_parent() is AICoreComponent:
		aiCore = get_parent()
		nexus = aiCore.nexus
		if nexus:
			pawn = nexus.pawn
		_check_overwrite_premade()
		if not isForDeletion and nexus:
			nexus.aiMemory = self


#same premade/spawned rules as the sensing and state components, so it behaves like its siblings
var isForDeletion:= false
func _check_overwrite_premade()->void:
	var allowOverwrite: bool = nexus.allow_overwrites.get("AIMemory", false) if nexus else false #.get(): older scenes have no "AIMemory" key
	if aiCore.aiMemory and aiCore.aiMemory != self:
		var keepSelf: bool = (isPremade and not allowOverwrite) or (not isPremade and allowOverwrite)
		if keepSelf:
			aiCore.aiMemory.queue_free()
		else:
			isForDeletion = true
			queue_free()
			return
	aiCore.aiMemory = self


func _physics_process(delta: float) -> void:
	_timeSinceUpdate += delta
	if _timeSinceUpdate >= update_interval:
		decay_by(_timeSinceUpdate)
		_timeSinceUpdate = 0.0


#region writing
##records (or refreshes) a fact. Call this from senses.
##[param subject] the node it's about, or null for things like noises.
##A fact is matched by (type, subject); subject-less facts are matched by (type, within anonymous_merge_radius).
func record(type: StringName, subject: Object, position: Vector3, confidence: float = 1.0, source: StringName = &"", data: Dictionary = {}) -> AIMemoryFact:
	var now := _now()
	var fact := _find_match(type, subject, position)
	if fact:
		fact.position = position
		fact.confidence = maxf(fact.confidence, confidence) #a weak report never lowers what we already know
		fact.source = source
		fact.lastTime = now
		fact.data.merge(data, true)
		fact_refreshed.emit(fact)
		return fact
	if facts.size() >= max_facts:
		forget(get_least_confident())
	fact = AIMemoryFact.new(type, subject, position)
	fact.confidence = clampf(confidence, 0.0, 1.0)
	fact.source = source
	fact.firstTime = now
	fact.lastTime = now
	fact.data = data.duplicate()
	facts.append(fact)
	fact_added.emit(fact)
	return fact


##removes a fact right away
func forget(fact: AIMemoryFact) -> void:
	var at := facts.find(fact)
	if at == -1:
		return
	facts.remove_at(at)
	fact_forgotten.emit(fact)


##removes every fact (or every fact of [param type])
func clear(type: StringName = &"") -> void:
	for fact in facts.duplicate():
		if type == &"" or fact.type == type:
			forget(fact)


##fades every fact as if [param seconds] had passed. Called automatically every update_interval.
##Public so tests (or a "time skip") can drive it directly.
func decay_by(seconds: float) -> void:
	for fact in facts.duplicate(): #duplicate: forget() edits the array
		var halfLife := _get_half_life(fact)
		if halfLife > 0.0:
			fact.confidence *= pow(0.5, seconds / halfLife)
		if _should_forget(fact):
			forget(fact)
	if debug_draw:
		_draw_debug()
#endregion


#region reading
##all facts, or only those of [param type], at or above [param min_confidence]
func get_facts(type: StringName = &"", min_confidence: float = 0.0) -> Array[AIMemoryFact]:
	var out: Array[AIMemoryFact] = []
	for fact in facts:
		if (type == &"" or fact.type == type) and fact.confidence >= min_confidence:
			out.append(fact)
	return out


##the fact about [param subject] (of [param type], if given), or null
func get_fact_about(subject: Object, type: StringName = &"") -> AIMemoryFact:
	if subject == null:
		return null
	var id := subject.get_instance_id()
	for fact in facts:
		if fact.subjectId == id and (type == &"" or fact.type == type):
			return fact
	return null


##the most recently refreshed fact (of [param type], if given), or null
func get_most_recent(type: StringName = &"") -> AIMemoryFact:
	var best: AIMemoryFact = null
	for fact in facts:
		if (type == &"" or fact.type == type) and (best == null or fact.lastTime > best.lastTime):
			best = fact
	return best


##the most confident fact (of [param type], if given), or null
func get_most_confident(type: StringName = &"") -> AIMemoryFact:
	var best: AIMemoryFact = null
	for fact in facts:
		if (type == &"" or fact.type == type) and (best == null or fact.confidence > best.confidence):
			best = fact
	return best


##the least confident fact (of [param type], if given), or null. Used to make room when full
func get_least_confident(type: StringName = &"") -> AIMemoryFact:
	var worst: AIMemoryFact = null
	for fact in facts:
		if (type == &"" or fact.type == type) and (worst == null or fact.confidence < worst.confidence):
			worst = fact
	return worst


##true if memory holds any fact of [param type] at or above [param min_confidence]
func has_fact(type: StringName, min_confidence: float = 0.0) -> bool:
	for fact in facts:
		if fact.type == type and fact.confidence >= min_confidence:
			return true
	return false


func get_debug_string() -> String:
	var lines: PackedStringArray = []
	var now := _now()
	for fact in facts:
		lines.append("%s age %.1fs" % [fact, fact.age(now)])
	return "\n".join(lines)
#endregion


#region overridable rules
##how fast [param fact] fades. Override for custom rules (e.g. remember enemies longer when alert)
func _get_half_life(fact: AIMemoryFact) -> float:
	if half_life_by_type.has(fact.type):
		return half_life_by_type[fact.type]
	if half_life_by_type.has(String(fact.type)): #inspector-entered keys are Strings
		return half_life_by_type[String(fact.type)]
	return default_half_life


##whether [param fact] should be dropped on this pass. Override for custom rules
func _should_forget(fact: AIMemoryFact) -> bool:
	if fact.confidence < forget_below:
		return true
	return forget_when_subject_freed and fact.is_subject_gone()
#endregion


func _find_match(type: StringName, subject: Object, position: Vector3) -> AIMemoryFact:
	if subject:
		var id := subject.get_instance_id()
		for fact in facts:
			if fact.type == type and fact.subjectId == id:
				return fact
		return null
	var bestDist := anonymous_merge_radius
	var best: AIMemoryFact = null
	for fact in facts:
		if fact.type == type and fact.subjectId == 0:
			var d := fact.position.distance_to(position)
			if d <= bestDist:
				bestDist = d
				best = fact
	return best


func _now() -> float:
	return Time.get_ticks_msec() / 1000.0


#looks GlobalTools up at runtime instead of naming the autoload, so this script also loads where autoloads don't exist (headless tests)
func _draw_debug() -> void:
	var tools := get_node_or_null("/root/GlobalTools")
	if tools == null:
		return
	for fact in facts:
		tools.point(fact.position + Vector3.UP, 0.25, Color(1.0, 1.0 - fact.confidence, 0.2), update_interval)
