# Written by Claude (claude-opus-5-5), 2026-11-07. History: controllers/CHANGELOG.md.
## Turns action names like &"jump" into bits, so an input command carries every held action in one int.
##
## One int is much smaller than a list of names on the network, and "is jump held?" is one AND. Every machine must give an action the
## same bit, so the game lists its actions in resources/input_actions.tres (an InputActionsRes) and each gets the bit of its place in
## the list; the list is part of NetworkSession's content hash. An unlisted action is added with a warning offline, and gets no bit
## (never held) in a network session. Past 64 actions the extras get no bit.
## [br]
## A static class, not an autoload, so it works in headless tests. Design: pawn spec 5.
class_name InputActions
extends RefCounted

const MAX_ACTIONS := 64
const LIST_PATH := "res://assets/scripts/resources/input_actions.tres"

static var _index_of: Dictionary = {} # StringName action -> its bit's index
static var _actions: Array[StringName] = [] # index -> action
static var _loaded := false
static var _warned: Dictionary = {}


## The mask with this action's bit, or 0 for a blank name.
static func mask_of(action: StringName) -> int:
	_ensure_loaded()
	# The fast path. Pawns call this every tick, so a known name returns at once, without building a new string.
	var index: Variant = _index_of.get(action)
	if index != null:
		return 1 << index
	var clean := _clean(action)
	if clean == &"":
		return 0
	if not _index_of.has(clean):
		_add(clean, true)
	return 1 << _index_of[clean] if _index_of.has(clean) else 0


## The mask with all these actions' bits.
static func mask_of_list(actions: Array) -> int:
	var mask := 0
	for action in actions:
		mask |= mask_of(action)
	return mask


## Every listed action's bit. The server uses it to throw away bits a client made up.
static func all_listed_mask() -> int:
	_ensure_loaded()
	# An int is 64 bits, so 1 << 64 doesn't fit: -1 has every bit set.
	return -1 if _actions.size() >= 64 else (1 << _actions.size()) - 1


## The names of the actions in a mask, for debug readouts.
static func names_in(mask: int) -> Array[StringName]:
	_ensure_loaded()
	var names: Array[StringName] = []
	for index in _actions.size():
		if mask & (1 << index):
			names.append(_actions[index])
	return names


## Every action, in bit order.
static func get_actions() -> Array[StringName]:
	_ensure_loaded()
	return _actions.duplicate()


# --- Internals ---


static func _ensure_loaded() -> void:
	if _loaded:
		return
	_loaded = true
	if not ResourceLoader.exists(LIST_PATH):
		push_warning("InputActions: there's no action list at %s, so actions get bits in the order they're first used. Make the file (an InputActionsRes) so every machine agrees." % LIST_PATH)
		return
	var res = load(LIST_PATH)
	if not res is InputActionsRes:
		push_warning("InputActions: %s isn't an InputActionsRes, so actions get bits in the order they're first used." % LIST_PATH)
		return
	for action in res.actions:
		_add(_clean(action), false)


static func _add(action: StringName, late: bool) -> void:
	if action == &"" or _index_of.has(action):
		return
	if _actions.size() >= MAX_ACTIONS:
		_warn_once(action, "InputActions: more than %d actions, so '%s' gets no bit and is never held." % [MAX_ACTIONS, action])
		return
	if late and _is_online():
		_warn_once(action, "InputActions: '%s' isn't in %s, and a network session is running, so it gets no bit and is never held. Add it to the list. Check the spelling too." % [action, LIST_PATH])
		return
	if late:
		_warn_once(action, "InputActions: '%s' isn't in %s, so it was added as bit %d. Add it to the list, or it won't work online. Check the spelling too." % [action, LIST_PATH, _actions.size()])
	_index_of[action] = _actions.size()
	_actions.append(action)


## True while this machine is a server or a client. A static class has no node of its own, so it asks the tree.
static func _is_online() -> bool:
	var tree := Engine.get_main_loop() as SceneTree
	var session: Node = tree.root.get_node_or_null("NetworkSession") if tree else null
	return session != null and (session.is_server() or session.is_client())


static func _clean(action: Variant) -> StringName:
	return StringName(String(action).strip_edges())


static func _warn_once(action: StringName, message: String) -> void:
	if _warned.has(action):
		return
	_warned[action] = true
	push_warning(message)
