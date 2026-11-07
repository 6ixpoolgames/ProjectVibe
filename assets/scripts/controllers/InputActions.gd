## Written by Claude (claude-opus-5-5), 2026-11-07: turns action names like &"jump" into bits, so an input command can carry every held
## action in one int. Pawn spec section 5.
##
## Why bits: an input command goes over the network every tick, and one int is much smaller than a list of names. Checking "is jump
## held?" is one AND.
##
## Why a declared list: in multiplayer every machine must give the same action the same bit. So the game lists its actions in
## resources/input_actions.tres (an InputActionsRes), and each one gets the bit of its place in that list, the same everywhere.
##
## What happens in odd cases (all checked in tests/input_actions_selftest.gd):
##   - No list file: a warning, and the list starts empty. Each action used is then added as it's first seen, with its own warning.
##     Claude 2026-11-07: there used to be a copy of the list in code for this case. It's gone, so the file is the only place the
##     list lives, and the two can't drift apart.
##   - An action nobody listed, used at runtime: added at the end with a one-time warning. A typo such as &"Jump" shows up the same way.
##     Claude 2026-11-07, from the audit of 6df1464: only offline. While a network session is running it gets no bit (it's never
##     held), with a one-time warning, because two machines adding names in a different order would disagree on what a bit means.
##     The list itself is part of NetworkSession's content hash, so machines with different lists can't connect.
##   - Empty or blank name: no bit (0). Never an error.
##   - More than 64 actions: the extra ones get no bit, with a warning.
##
## A static class, not an autoload, so it works in headless tests. TagRegistry works the same way.
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
	# Claude 2026-11-07: the fast path. Pawns call this every tick, so a known name returns at once, without building a new string.
	var index: Variant = _index_of.get(action)
	if index != null:
		return 1 << index
	var clean := _clean(action)
	if clean == &"":
		return 0
	if not _index_of.has(clean):
		_add(clean, true)
	# GDScript note: "a if condition else b" is GDScript's one-line if. 1 << n is the number with only bit n set.
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
	# GDScript note: ints are 64 bits, so 1 << 64 doesn't fit. -1 has every bit set.
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


## Forgets everything, so the next use reads the list again. For tests.
static func reset() -> void:
	_index_of.clear()
	_actions.clear()
	_warned.clear()
	_loaded = false


## Uses this list instead of the file. For tests.
static func use_list(actions: Array) -> void:
	reset()
	_loaded = true
	for action in actions:
		_add(_clean(action), false)


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


## Claude 2026-11-07: true while this machine is a server or a client. A static class has no node of its own, so it asks the tree.
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
