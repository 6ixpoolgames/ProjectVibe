# Written by Claude (claude-opus-5-5), 2026-11-17. History: ai/CHANGELOG.md.
## One pawn's AI inputs: the named numbers its behaviours' conditions read.
##
## Every name has a slot, the same for every pawn, so a crowd's inputs line up as one table the C++ decider reads. The built-in inputs
## (the constants below) are worked out the first time a condition reads them in a decision; any other name is a game's own, kept
## until written again ([method set_input]). Names starting [code]ticks_[/code] are times in ticks, written for 60 a second.
## Design: scaling spec 6.2.
## [codeblock]
## pawn.ai_context.inputs.set_input(&"morale", 0.4)
## pawn.ai_context.inputs.value_of(AIInputs.TARGET_DISTANCE)
## [/codeblock]
class_name AIInputs
extends RefCounted

## Flat distance to where the AI last knew its target to be; [constant FAR] with no target.
const TARGET_DISTANCE := &"target_distance"
## 1 if the memory entry it's most aware of is certain, else 0.
const MOST_AWARE_CERTAIN := &"most_aware_certain"
## 1 if there's a most aware entry and it isn't certain yet, else 0.
const MOST_AWARE_UNCERTAIN := &"most_aware_uncertain"
## Ticks since an attacker it doesn't remember hit it; [constant FAR] if none did, or the attacker is remembered.
const TICKS_SINCE_UNKNOWN_HIT := &"ticks_since_unknown_hit"
## 1 while a swing it was warned of hasn't hit yet.
const INCOMING_ATTACK := &"incoming_attack"
## The tick that swing started.
const INCOMING_ATTACK_TICK := &"incoming_attack_tick"
## The swinging pawn's number.
const INCOMING_ATTACKER := &"incoming_attacker"
## [code]group_distance/<group>[/code]: flat distance to the group's nearest node; [constant FAR] if it has none.
const GROUP_DISTANCE := "group_distance/"
## [code]group_found/<group>[/code]: 1 while the group has a node. Pair it with a "further than" check on the distance.
const GROUP_FOUND := "group_found/"
## [code]action_ready/<action>[/code]: 1 while pressing the action could start an ability.
const ACTION_READY := "action_ready/"
## Names starting with this are times in ticks.
const TICKS_PREFIX := "ticks_"

## The value when there's nothing to measure: larger than any real distance or time, and not INF, so records stay valid JSON.
const FAR := 1.0e12

## How a slot's value is found: KEPT is written by whoever knows it; the rest are worked out at each decision.
enum Kind { KEPT, TARGET_DISTANCE, MOST_AWARE_CERTAIN, MOST_AWARE_UNCERTAIN, TICKS_SINCE_UNKNOWN_HIT, INCOMING_ATTACK,
	INCOMING_ATTACK_TICK, INCOMING_ATTACKER, GROUP_DISTANCE, GROUP_FOUND, ACTION_READY }

# The registry, shared by every pawn: name -> slot, and each slot's kind, parameter and whether it's ticks.
static var _slot_by_name := {}
static var _names: Array[StringName] = []
static var _kinds := PackedInt32Array()
static var _parameters: Array[StringName] = []
static var _in_ticks := PackedByteArray()
static var _ready_slot_of := {} # action -> its action_ready slot
static var _group_nodes := {} # group -> [tick, nodes, tree], shared by every pawn for one tick

## How often a group's nearest node is looked for again, in ticks at 60 a second.
const GROUP_LOOK_AGAIN_TICKS := 120

## The values by slot; 0 where nothing was written or worked out.
var values := PackedFloat64Array()

var _context: AIContextComponent = null
var _decision := 0 # counts decisions; a worked-out value is fresh while its stamp matches
var _tick := 0 # the tick of the decision under way
var _stamps := PackedInt32Array() # per slot, the decision it was last worked out for
var _group_point := {} # group -> the nearest node found
var _group_looked_tick := {} # group -> the tick it was last looked for
var _ready_version := {} # action -> the AbilityManager's readiness_version when last asked


func _init(context: AIContextComponent = null) -> void:
	_context = context


# --- The registry ---


## The slot for an input name, given out on first use.
static func slot_of(input_name: StringName) -> int:
	var known: Variant = _slot_by_name.get(input_name)
	if known != null:
		return known
	var slot := _names.size()
	var kind := Kind.KEPT
	var parameter: StringName = &""
	var text := String(input_name)
	match input_name:
		TARGET_DISTANCE: kind = Kind.TARGET_DISTANCE
		MOST_AWARE_CERTAIN: kind = Kind.MOST_AWARE_CERTAIN
		MOST_AWARE_UNCERTAIN: kind = Kind.MOST_AWARE_UNCERTAIN
		TICKS_SINCE_UNKNOWN_HIT: kind = Kind.TICKS_SINCE_UNKNOWN_HIT
		INCOMING_ATTACK: kind = Kind.INCOMING_ATTACK
		INCOMING_ATTACK_TICK: kind = Kind.INCOMING_ATTACK_TICK
		INCOMING_ATTACKER: kind = Kind.INCOMING_ATTACKER
		_:
			if text.begins_with(GROUP_DISTANCE):
				kind = Kind.GROUP_DISTANCE
				parameter = StringName(text.trim_prefix(GROUP_DISTANCE))
			elif text.begins_with(GROUP_FOUND):
				kind = Kind.GROUP_FOUND
				parameter = StringName(text.trim_prefix(GROUP_FOUND))
			elif text.begins_with(ACTION_READY):
				kind = Kind.ACTION_READY
				parameter = StringName(text.trim_prefix(ACTION_READY))
	_slot_by_name[input_name] = slot
	_names.append(input_name)
	_kinds.append(kind)
	_parameters.append(parameter)
	_in_ticks.append(1 if text.begins_with(TICKS_PREFIX) else 0)
	return slot


## How many names have slots.
static func input_count() -> int:
	return _names.size()


## The name in a slot.
static func name_of(slot: int) -> StringName:
	return _names[slot] if slot >= 0 and slot < _names.size() else &""


## True for a built-in input, worked out at each decision.
static func is_worked_out(slot: int) -> bool:
	return slot >= 0 and slot < _kinds.size() and _kinds[slot] != Kind.KEPT


## A slot's [enum Kind].
static func kind_of(slot: int) -> int:
	return _kinds[slot] if slot >= 0 and slot < _kinds.size() else Kind.KEPT


## The name after a slot's prefix (the group or action); &"" for others.
static func parameter_of(slot: int) -> StringName:
	return _parameters[slot] if slot >= 0 and slot < _parameters.size() else &""


## Every slot's [enum Kind], for the C++ decider.
static func kinds() -> PackedInt32Array:
	return _kinds.duplicate()


## True if the slot's input is a time in ticks.
static func is_ticks(slot: int) -> bool:
	return slot >= 0 and slot < _in_ticks.size() and _in_ticks[slot] == 1




## The conditions for "something half-noticed", shared by Look Toward and Investigate: the most aware entry isn't certain yet, or
## an unknown attacker hit within hit_memory_ticks.
static func half_noticed_conditions(hit_memory_ticks: int) -> Array[AICondition]:
	var either: Array[AICondition] = [
		AICompareCondition.make(MOST_AWARE_UNCERTAIN, AICompareCondition.Comparison.EQUAL, 1.0),
		AICompareCondition.make(TICKS_SINCE_UNKNOWN_HIT, AICompareCondition.Comparison.AT_MOST, hit_memory_ticks),
	]
	var list: Array[AICondition] = [AIAnyCondition.make(either)]
	return list


# --- One pawn's values ---


## Writes a game's own input; it stays until written again.
func set_input(input_name: StringName, amount: float) -> void:
	set_slot(slot_of(input_name), amount)


## Writes a value by slot. A kept input also goes to the pawn's C++ row.
func set_slot(slot: int, amount: float) -> void:
	if values.size() <= slot:
		_grow(slot + 1)
	values[slot] = amount
	var manager := _context.behaviour_manager if _context else null
	if manager and manager.cpp_row >= 0 and AIBehaviourManager.decision_module and _kinds[slot] == Kind.KEPT:
		AIBehaviourManager.decision_module.input_set(manager, slot, amount)


## The value in a slot, working out a built-in one if it hasn't been yet this decision.
func value(slot: int) -> float:
	if slot < 0:
		return 0.0
	if slot >= values.size():
		if slot >= _kinds.size() or _kinds[slot] == Kind.KEPT:
			return 0.0
		_grow(input_count())
	if _kinds[slot] != Kind.KEPT and _stamps[slot] != _decision:
		_work_out(slot)
	return values[slot]


## The value of an input by name.
func value_of(input_name: StringName) -> float:
	return value(slot_of(input_name))


## Starts a decision: built-in inputs are worked out again when next read.
func begin_decision(tick: int) -> void:
	_decision += 1
	_tick = tick


## Works out every listed slot now, for something that needs them all (a decision record, shadow mode).
func fill(slots: PackedInt32Array) -> void:
	for slot in slots:
		value(slot)


func _work_out(slot: int) -> void:
	_stamps[slot] = _decision
	var context := _context
	if context == null or context.pawn == null:
		return
	var tick := _tick
	match _kinds[slot]:
		Kind.TARGET_DISTANCE:
			var index := context.current_target_index()
			values[slot] = _flat_distance(context.memory.last_known_position_at(index)) if index >= 0 else FAR
		Kind.MOST_AWARE_CERTAIN:
			var index := context.most_aware_index()
			values[slot] = 1.0 if index >= 0 and context.memory.is_certain_at(index) else 0.0
		Kind.MOST_AWARE_UNCERTAIN:
			var index := context.most_aware_index()
			values[slot] = 1.0 if index >= 0 and not context.memory.is_certain_at(index) else 0.0
		Kind.TICKS_SINCE_UNKNOWN_HIT:
			var unknown := context.last_hit_tick >= 0 and not context.last_attacker_is_known()
			values[slot] = float(tick - context.last_hit_tick) if unknown else FAR
		Kind.INCOMING_ATTACK:
			values[slot] = 1.0 if context.has_incoming_attack() else 0.0
		Kind.INCOMING_ATTACK_TICK:
			values[slot] = float(context.incoming_start_tick)
		Kind.INCOMING_ATTACKER:
			values[slot] = float(AIContextComponent.number_of(context.incoming_attacker)) if is_instance_valid(context.incoming_attacker) else -1.0
		Kind.GROUP_DISTANCE:
			var point := nearest_in_group(_parameters[slot], tick)
			values[slot] = _flat_distance(point.global_position) if point else FAR
		Kind.GROUP_FOUND:
			values[slot] = 1.0 if nearest_in_group(_parameters[slot], tick) else 0.0
		Kind.ACTION_READY:
			values[slot] = 1.0 if action_ready(_parameters[slot]) else 0.0


func _grow(count: int) -> void:
	if values.size() < count:
		values.resize(count)
		_stamps.resize(count)


## The group's nearest node (null if none), kept for 2 seconds while it exists. Go To Point walks to it.
func nearest_in_group(group: StringName, tick: int) -> Node3D:
	# A freed node can't go in a typed variable, so it's checked as a Variant first.
	var kept: Variant = _group_point.get(group)
	var point: Node3D = kept if is_instance_valid(kept) else null
	var looked: int = _group_looked_tick.get(group, -1)
	if point == null or not point.is_inside_tree() or looked < 0 \
			or tick - looked >= TickDriver.ticks_at_rate(GROUP_LOOK_AGAIN_TICKS):
		point = _find_nearest(group, tick)
		_group_point[group] = point
		_group_looked_tick[group] = tick
	return point


## True if pressing the action could start an ability. Asks the AbilityManager again only after its readiness_version moved on, or
## every time for an action whose readiness follows the body (Jump).
func action_ready(action: StringName) -> bool:
	var context := _context
	var abilities := context.pawn.ability_manager if context and context.pawn else null
	if abilities == null:
		return false
	var known: Variant = _ready_slot_of.get(action)
	if known == null:
		known = slot_of(StringName(ACTION_READY + String(action)))
		_ready_slot_of[action] = known
	var slot: int = known
	if values.size() <= slot:
		_grow(slot + 1)
	var version: int = _ready_version.get(action, -1)
	if version != abilities.readiness_version or abilities.ready_follows_body(action):
		values[slot] = 1.0 if abilities.can_start(action) else 0.0
		_ready_version[action] = abilities.readiness_version
	return values[slot] > 0.5


func _find_nearest(group: StringName, tick: int) -> Node3D:
	var pawn := _context.pawn
	if not pawn.is_inside_tree():
		return null
	var best: Node3D = null
	var best_distance := INF
	for node in _nodes_in_group(pawn.get_tree(), group, tick): # untyped: a freed node can't be typed
		if not is_instance_valid(node):
			continue
		var point := node as Node3D
		if point == null:
			continue
		var distance := _flat_distance(point.global_position)
		if distance < best_distance:
			best = point
			best_distance = distance
	return best


# The group's nodes, asked of the tree once a tick and shared by every pawn.
func _nodes_in_group(tree: SceneTree, group: StringName, tick: int) -> Array:
	var cached: Array = _group_nodes.get(group, [])
	if not cached.is_empty() and cached[0] == tick and cached[2] == tree:
		return cached[1]
	var nodes := tree.get_nodes_in_group(group)
	_group_nodes[group] = [tick, nodes, tree]
	return nodes


# Distance ignoring height, as every AI distance setting is measured.
func _flat_distance(point: Vector3) -> float:
	var offset := point - _context.pawn.global_position
	offset.y = 0.0
	return offset.length()
