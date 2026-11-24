# Written by Claude (claude-opus-5-5), 2026-11-15. History: replay/CHANGELOG.md.
## Replay channel 5, "gameplay": what happened, as events.
##
## The same events the AI debug timeline lists, for every pawn, plus freezes, possession and falls; each event's id is the pawn it
## happened to. The kinds: hit, hit_blocked, died, ability_started, ability_cancelled, step_started, step_finished, ai_state,
## ai_behaviour, ai_target, frozen, unfrozen, possessed, released and fell. The data of each is listed in the replay README.
## Reading: only [code]state["events"][/code], this tick's events; nothing lasts.
## Design: replay spec 3, pawn spec 8.20 and 16.7.
class_name ReplayGameplayChannel
extends ReplayEventChannel

const ID := 5

var _per_pawn := {} # replay id -> Array of [Signal, Callable] connected for that pawn
var _global: Array = [] # [Signal, Callable] connected to GameMode modules and kill floors
var _kill_floors := {} # instance id -> true, for those already connected


func _init() -> void:
	channel_id = ID
	channel_name = "gameplay"
	version = 1


func begin(for_recorder: ReplayRecorder) -> void:
	super(for_recorder)
	var game_mode: Node = for_recorder.get_node_or_null("/root/GameMode")
	if game_mode:
		var activation: AIActivationManager = game_mode.ai_activation_manager
		if activation:
			_connect_global(activation.ai_deactivated, func(pawn: Node3D) -> void: _pawn_event("frozen", pawn))
			_connect_global(activation.ai_activated, func(pawn: Node3D) -> void: _pawn_event("unfrozen", pawn))
		var possession: PossessionCoordinator = game_mode.possession_coordinator
		if possession:
			_connect_global(possession.possessed, func(peer: int, pawn: Pawn) -> void: _pawn_event("possessed", pawn, {"peer": peer}))
			_connect_global(possession.released, func(peer: int, pawn: Pawn) -> void: _pawn_event("released", pawn, {"peer": peer}))
	_find_kill_floors()


func end() -> void:
	for connections: Array in _per_pawn.values():
		_disconnect_all(connections)
	_per_pawn.clear()
	_disconnect_all(_global)
	_global.clear()
	_kill_floors.clear()
	super()


func write_tick(tick: int, out: StreamPeerBuffer, keyframe: bool) -> void:
	if keyframe:
		_find_kill_floors() # a level can add one later; once a second is often enough
	super(tick, out, keyframe)


func pawn_added(pawn: Pawn, id: int) -> void:
	var connections: Array = []
	if pawn.ability_manager: # hits, death, abilities and their steps
		_connect(connections, pawn.ability_manager.hit_received, func(hit: HitInfo) -> void:
			add_event("hit", id, {"attacker": recorder.get_replay_id(hit.attacker) if recorder else 0, "ability": _name_of(hit.ability),
				"damage": hit.damage_dealt}))
		# A hit that arrived but was blocked (parried, invulnerable, dead), with who sent it and why.
		_connect(connections, pawn.ability_manager.hit_blocked, func(hit: HitInfo, reason: StringName) -> void:
			add_event("hit_blocked", id, {"by": recorder.get_replay_id(hit.attacker) if recorder and is_instance_valid(hit.attacker) else 0,
				"reason": String(reason)}))
		_connect(connections, pawn.ability_manager.died, func(_who: Pawn, hit: HitInfo) -> void:
			add_event("died", id, {"killer": recorder.get_replay_id(hit.attacker) if recorder and hit else 0}))
		_connect(connections, pawn.ability_manager.ability_started, func(ability: AbilityBase) -> void:
			if not ability is ReceiveHitAbility: # it starts on every hit, which the hit events already record
				add_event("ability_started", id, {"ability": _name_of(ability)}))
		_connect(connections, pawn.ability_manager.ability_cancelled, func(ability: AbilityBase, by: AbilityBase) -> void:
			add_event("ability_cancelled", id, {"ability": _name_of(ability), "by": _name_of(by)}))
		# Steps of a stepped ability (pawn spec 8.20).
		_connect(connections, pawn.ability_manager.step_started, func(ability: AbilityBase, step: AbilityStep) -> void:
			add_event("step_started", id, {"ability": _name_of(ability), "step": _name_of(step)}))
		_connect(connections, pawn.ability_manager.step_finished, func(ability: AbilityBase, step: AbilityStep, reason: String) -> void:
			add_event("step_finished", id, {"ability": _name_of(ability), "step": _name_of(step), "reason": reason}))
	if pawn.ai_context and pawn.ai_context.state_manager: # the AI's parts are reached through its context
		_connect(connections, pawn.ai_context.state_manager.state_changed, func(old: AIStateBase, new: AIStateBase, reason: String) -> void:
			add_event("ai_state", id, {"from": _name_of(old), "to": _name_of(new), "reason": reason}))
	if pawn.ai_context and pawn.ai_context.behaviour_manager:
		_connect(connections, pawn.ai_context.behaviour_manager.behaviour_changed,
			func(old: AIBehaviourBase, new: AIBehaviourBase, reason: String) -> void:
				add_event("ai_behaviour", id, {"from": _name_of(old), "to": _name_of(new), "reason": reason}))
	if pawn.ai_context and pawn.ai_context.target_selector:
		_connect(connections, pawn.ai_context.target_selector.target_changed, func(old: Node3D, new: Node3D, reason: String) -> void:
			add_event("ai_target", id, {"from": recorder.get_replay_id(old) if recorder else 0,
				"to": recorder.get_replay_id(new) if recorder else 0, "reason": reason}))
	_per_pawn[id] = connections


func pawn_removed(_pawn: Pawn, id: int) -> void:
	var connections: Variant = _per_pawn.get(id)
	if connections != null:
		_disconnect_all(connections)
		_per_pawn.erase(id)


func _pawn_event(kind: String, pawn: Node, data: Dictionary = {}) -> void:
	if recorder:
		add_event(kind, recorder.get_replay_id(pawn), data)


func _find_kill_floors() -> void:
	if recorder == null or not recorder.is_inside_tree():
		return
	for node in recorder.get_tree().get_nodes_in_group(KillFloor.GROUP):
		var kill_floor := node as KillFloor
		if kill_floor and not _kill_floors.has(kill_floor.get_instance_id()):
			_kill_floors[kill_floor.get_instance_id()] = true
			_connect_global(kill_floor.pawn_fell, func(pawn: Pawn, report: String) -> void: _pawn_event("fell", pawn, {"report": report}))


func _connect(list: Array, which: Signal, callable: Callable) -> void:
	which.connect(callable)
	list.append([which, callable])


func _connect_global(which: Signal, callable: Callable) -> void:
	_connect(_global, which, callable)


static func _disconnect_all(list: Array) -> void:
	for pair: Array in list:
		var which: Signal = pair[0]
		# A freed object's signal needn't be disconnected: its connections went with it.
		if not which.is_null() and is_instance_valid(which.get_object()) and which.is_connected(pair[1]):
			which.disconnect(pair[1])


static func _name_of(thing: Object) -> String:
	return String(thing.name) if is_instance_valid(thing) and thing is Node else ""
