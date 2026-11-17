# Written by Claude (claude-opus-5-5), 2026-11-17. History: ai/CHANGELOG.md.
## One pawn's AI inputs: the numbers its behaviours' conditions read, such as the distance to its target.
##
## Scaling spec 6.2. A behaviour says when it may run with conditions ([AICondition]): plain data such as "target_distance at most
## 2.5". Conditions never call into game code; they read numbers from here. That's what lets the same decision be made in C++
## (AIBatchDecider) from a table of these numbers, without calling back into GDScript for every behaviour.
## [br]
## Every input has a name and a slot. The slot is its place in [member values], the same for every pawn in the match, so a whole
## crowd's inputs line up as one table. Slots are given out the first time a name is asked for ([method slot_of]).
## [br]
## Two kinds of input:
## [br]- [b]Worked out[/b] at most once per decision, from what the AI already knows: the built-in names below. Each is worked out the
##   first time a condition reads it in a decision ([method begin_decision], [method value]), so a decision pays only for the inputs
##   the behaviours it actually judges read, as the early stop allows. The C++ decider and decision records need them all, so for
##   those every input the brain reads is worked out ([method fill]).
## [br]- [b]Kept[/b]: any other name. Whatever knows the value writes it when it changes ([method set_input]), and it stays until written
##   again. This is how a game adds its own, such as a morale value its game mode keeps up to date.
## [br]
## Names that begin with [code]ticks_[/code] are times in ticks. A condition's value for them is written for 60 ticks a second and
## converted to the match's rate, like every AI setting counted in ticks.
## [br]
## The built-in inputs:
## [br]- [code]target_distance[/code]: flat distance (ignoring height) to where the AI last knew its target to be. [constant FAR] with
##   no target.
## [br]- [code]most_aware_certain[/code]: 1 if the entry it's most aware of in memory is certain, else 0.
## [br]- [code]most_aware_uncertain[/code]: 1 if there's such an entry and it isn't certain yet, else 0.
## [br]- [code]ticks_since_unknown_hit[/code]: ticks since an attacker it doesn't remember hit it. [constant FAR] if that never happened,
##   or the attacker is remembered.
## [br]- [code]incoming_attack[/code]: 1 while a swing it was warned of hasn't hit yet. [code]incoming_attack_tick[/code]: the tick that
##   swing started. [code]incoming_attacker[/code]: the swinging pawn's number.
## [br]- [code]group_distance/<group>[/code]: flat distance to the nearest node in that group, such as
##   [code]group_distance/rally_point[/code]. The nearest node is looked for again every 2 seconds. [constant FAR] if there's none,
##   so pair a "further than" check with [code]group_found/<group>[/code], 1 while the group has a node.
## [br]- [code]action_ready/<action>[/code]: 1 while pressing that action could start an ability ([method AbilityManager.can_start]).
##   Worked out again only when the AbilityManager says something that affects it changed ([member AbilityManager.readiness_version]).
## [br]
## How to use it:
## [codeblock]
## pawn.ai_context.inputs.set_input(&"morale", 0.4)                  # a game's own input, kept until written again
## pawn.ai_context.inputs.value_of(AIInputs.TARGET_DISTANCE)         # read one (worked out at the last decision)
## AIInputs.slot_of(&"morale")                                       # its slot, for reading values directly
## [/codeblock]
class_name AIInputs
extends RefCounted

## The built-in inputs' names. Code uses these constants, never the text, so a typo fails to compile.
const TARGET_DISTANCE := &"target_distance"
const MOST_AWARE_CERTAIN := &"most_aware_certain"
const MOST_AWARE_UNCERTAIN := &"most_aware_uncertain"
const TICKS_SINCE_UNKNOWN_HIT := &"ticks_since_unknown_hit"
const INCOMING_ATTACK := &"incoming_attack"
const INCOMING_ATTACK_TICK := &"incoming_attack_tick"
const INCOMING_ATTACKER := &"incoming_attacker"
## The start of the inputs that take a name after them.
const GROUP_DISTANCE := "group_distance/"
const GROUP_FOUND := "group_found/"
const ACTION_READY := "action_ready/"
## Names that begin with this are times in ticks (see the class description).
const TICKS_PREFIX := "ticks_"

## What an input is when there's nothing to measure: no target, never hit. Bigger than any real distance or time, so "at most"
## conditions fail and "at least" ones pass. Not INF, so records of decisions stay valid JSON.
const FAR := 1.0e12

## How a slot's value is found. KEPT: written by whoever knows it; the rest are worked out at each decision.
enum Kind { KEPT, TARGET_DISTANCE, MOST_AWARE_CERTAIN, MOST_AWARE_UNCERTAIN, TICKS_SINCE_UNKNOWN_HIT, INCOMING_ATTACK,
	INCOMING_ATTACK_TICK, INCOMING_ATTACKER, GROUP_DISTANCE, GROUP_FOUND, ACTION_READY }

# The registry, shared by every pawn: name -> slot, and each slot's kind, the name after its prefix, and whether it's a time in ticks.
# GDScript note: "static var" is one value for the whole class, not one per object.
static var _slot_by_name := {}
static var _names: Array[StringName] = []
static var _kinds := PackedInt32Array()
static var _parameters: Array[StringName] = []
static var _in_ticks := PackedByteArray()
static var _ready_slot_of := {} # action -> its action_ready/<action> slot, so a check doesn't build the name each time
static var _group_nodes := {} # group -> [the tick it was asked for, the group's nodes then], shared by every pawn

## How often a group's nearest node is looked for again, in ticks at 60 a second.
const GROUP_LOOK_AGAIN_TICKS := 120

## The values, one per slot. Slots no one has written or worked out yet are 0. May be shorter than [method input_count] until a new
## name's first use; [method value] reads 0 past the end.
var values := PackedFloat64Array()

var _context: AIContextComponent = null
var _decision := 0 # counts decisions; a worked-out value is fresh while its stamp matches
var _tick := 0 # the tick of the decision under way
var _stamps := PackedInt32Array() # per slot, the decision it was last worked out for
var _group_point := {} # group -> the nearest Node3D found
var _group_looked_tick := {} # group -> the tick it was last looked for
var _ready_version := {} # action -> the AbilityManager's readiness_version when it was last worked out


func _init(context: AIContextComponent = null) -> void:
	_context = context


# --- The registry ---


## The slot for an input name, given out the first time the name is asked for. Built-in names and the two prefixes are worked out
## at decisions; any other name is a kept input.
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


## How many input names have slots so far.
static func input_count() -> int:
	return _names.size()


## The name in a slot.
static func name_of(slot: int) -> StringName:
	return _names[slot] if slot >= 0 and slot < _names.size() else &""


## True if the slot's value is worked out at each decision, false for a kept input.
static func is_worked_out(slot: int) -> bool:
	return slot >= 0 and slot < _kinds.size() and _kinds[slot] != Kind.KEPT


## A slot's [enum Kind].
static func kind_of(slot: int) -> int:
	return _kinds[slot] if slot >= 0 and slot < _kinds.size() else Kind.KEPT


## The name after a slot's prefix, such as the group of group_distance/rally_point; &"" for the others.
static func parameter_of(slot: int) -> StringName:
	return _parameters[slot] if slot >= 0 and slot < _parameters.size() else &""


## Every slot's [enum Kind], for the C++ decider, which works out the memory-based ones itself (scaling spec 6.2, step 5d).
static func kinds() -> PackedInt32Array:
	return _kinds.duplicate()


## True if the C++ decider works this slot's input out itself from the pawn's C++ memory and facts (the target distance, the most
## aware entry, the last hit, the swing coming). The rest (group distances, actions, a game's own) come from here.
static func cpp_works_out(slot: int) -> bool:
	if slot < 0 or slot >= _kinds.size():
		return false
	var kind := _kinds[slot]
	return kind != Kind.KEPT and kind != Kind.GROUP_DISTANCE and kind != Kind.GROUP_FOUND and kind != Kind.ACTION_READY


## True if the slot's input is a time in ticks (its name begins with [constant TICKS_PREFIX]).
static func is_ticks(slot: int) -> bool:
	return slot >= 0 and slot < _in_ticks.size() and _in_ticks[slot] == 1


## The input names the inspector suggests for a condition: the built-ins, then every name given a slot so far.
static func suggested_names() -> PackedStringArray:
	var names := PackedStringArray([TARGET_DISTANCE, MOST_AWARE_CERTAIN, MOST_AWARE_UNCERTAIN, TICKS_SINCE_UNKNOWN_HIT, INCOMING_ATTACK,
		INCOMING_ATTACK_TICK, INCOMING_ATTACKER, GROUP_DISTANCE + "rally_point", GROUP_FOUND + "rally_point", ACTION_READY + "primary"])
	for input_name in _names:
		if not names.has(String(input_name)):
			names.append(String(input_name))
	return names


## The conditions for "something half-noticed" ([method AIContextComponent.point_of_interest]): the most aware entry isn't certain
## yet, or an attacker the AI doesn't remember hit it within hit_memory_ticks (at 60 a second). Either will do. Look Toward and
## Investigate both use it, so the two react to the same things.
static func half_noticed_conditions(hit_memory_ticks: int) -> Array[AICondition]:
	var either: Array[AICondition] = [
		AICompareCondition.make(MOST_AWARE_UNCERTAIN, AICompareCondition.Comparison.EQUAL, 1.0),
		AICompareCondition.make(TICKS_SINCE_UNKNOWN_HIT, AICompareCondition.Comparison.AT_MOST, hit_memory_ticks),
	]
	var list: Array[AICondition] = [AIAnyCondition.make(either)]
	return list


# --- One pawn's values ---


## Writes a kept input. Use it for a game's own inputs; the built-in ones are worked out at each decision and would be overwritten.
func set_input(input_name: StringName, value: float) -> void:
	set_slot(slot_of(input_name), value)


## Writes a value by slot. A kept input also goes into the pawn's row in the C++ decider, when it decides there.
func set_slot(slot: int, value: float) -> void:
	if values.size() <= slot:
		_grow(slot + 1)
	values[slot] = value
	var manager := _context.behaviour_manager if _context else null
	if manager and manager.cpp_row >= 0 and AIBehaviourManager.decision_module and _kinds[slot] == Kind.KEPT:
		AIBehaviourManager.decision_module.input_set(manager, slot, value)


## The value in a slot: a kept one as last written (0 if never), a worked-out one worked out now if it hasn't been yet this decision.
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


## The value of an input by name. See [method value].
func value_of(input_name: StringName) -> float:
	return value(slot_of(input_name))


## Starts a decision at this tick: every worked-out input is worked out again the first time it's read. The behaviour manager calls
## it at the start of each decision.
func begin_decision(tick: int) -> void:
	_decision += 1
	_tick = tick


## Works out every listed slot now (the kept ones are left alone), for something that needs them all: the C++ decider's row, or a
## decision record. The behaviour manager calls it with the slots its behaviours' conditions read.
func fill(slots: PackedInt32Array) -> void:
	for slot in slots:
		value(slot)


# Works out one input for the decision under way, and stamps it fresh.
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


# Makes room for this many slots, in both the values and their stamps.
func _grow(count: int) -> void:
	if values.size() < count:
		values.resize(count) # GDScript note: resize fills the new places with 0
		_stamps.resize(count)


## The nearest node in a group, kept while it's still there and looked for again every 2 seconds in case a nearer one has appeared,
## rather than asking the tree for the whole group at every decision. Null if the group is empty. Go To Point walks to it. The group's
## list is asked of the tree once a tick and shared by every pawn looking that tick.
func nearest_in_group(group: StringName, tick: int) -> Node3D:
	var point: Node3D = _group_point.get(group)
	var looked: int = _group_looked_tick.get(group, -1)
	if point == null or not is_instance_valid(point) or not point.is_inside_tree() or looked < 0 \
			or tick - looked >= TickDriver.ticks_at_rate(GROUP_LOOK_AGAIN_TICKS):
		point = _find_nearest(group, tick)
		_group_point[group] = point
		_group_looked_tick[group] = tick
	return point


## True if pressing this action could start an ability now. Asks the AbilityManager again only when its
## [member AbilityManager.readiness_version] has moved on, or when an ability on the action can change its mind without telling it
## ([member AbilityBase.ready_follows_body], such as Jump needing the ground).
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
			continue # freed since the list was made, earlier this tick
		var point := node as Node3D
		if point == null:
			continue
		var distance := _flat_distance(point.global_position)
		if distance < best_distance:
			best = point
			best_distance = distance
	return best


# The group's nodes, asked of the tree at most once a tick and shared by every pawn.
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
