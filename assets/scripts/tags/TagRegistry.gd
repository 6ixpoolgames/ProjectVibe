# Written by Claude (claude-opus-5-5), 2026-11-04. History: tags/CHANGELOG.md.
## The ability tags: turns tag names like "combat.melee.sword" into bits, so checks are one AND instead of comparing text.
##
## The shared tag registry (pawn spec 7.1, netcode spec 13). Abilities carry tags, and lockouts, interrupts and the AI's
## [code]action_for_tag[/code] ask by them. Code writes them as [Tags] constants.
## [br]
## Tag bit rules:
## [br]- A tag is a StringName with dot-separated levels; a dot means sub-category (combat.melee is inside combat). Names only.
## [br]- Every level gets its own bit: combat, combat.melee and combat.melee.sword are three bits.
## [br]- A tag's mask is its own bit plus its parents' bits, so a query for "combat" catches combat.melee.sword with one AND, and
##   never "combatant". Matching is from the root only: "combat.melee" matches combat.melee.sword, "sword" doesn't.
## [br]- At most 64 levels; extras get no bit (mask 0, match nothing) with a warning.
## [br]
## Every machine must give a tag the same bit, so the game declares its tags in a TagDeclarationsRes (resources/tag_declarations.tres)
## and the registry sorts and numbers them at startup; the netcode handshake compares [method content_hash]. A tag nobody declared is
## added on the spot with a warning (a desync risk online). Queries never add tags. A static class, so it works in headless tests.
# REFACTOR: NavTags (navigation/) and EffectTags (effects/) are copies of these rules, made on purpose so working code didn't change.
# One tag-set class, used once per tag set, would be one place to fix and test, and a game's own tag set would come free (reusable).
class_name TagRegistry
extends RefCounted

const MAX_BITS := 64
## Where declarations are read from. Override with the project setting below if the file lives elsewhere.
const DEFAULT_DECLARATIONS_PATH := "res://assets/scripts/resources/tag_declarations.tres"
const DECLARATIONS_SETTING := "project_base/tags/declarations_path"

static var _bit_of: Dictionary = {}      # StringName tag -> bit index (every level is a tag of its own)
static var _tags: Array[StringName] = [] # bit index -> tag
static var _declared: Array[StringName] = []
static var _frozen := false              # true once bits are handed out; after that, new tags are appended
static var _loaded_file := false
static var _warned: Dictionary = {}


# --- Setup -------------------------------------------------------------------------------------

## Adds tags to the declared list. Call before the registry is first used (at startup);
## the declarations file is read automatically, so most games never call this.
static func declare(tags: Array) -> void:
	for t in tags:
		var tag := normalize(t)
		if tag == &"":
			continue
		if _frozen:
			_add_late(tag, "declared after the registry was already in use")
		elif not _declared.has(tag):
			_declared.append(tag)


## Forgets everything, including that the declarations file was read. For tests, and for
## tools that reload content. Masks stored before a reset are meaningless afterwards.
static func reset(read_declarations_file := true) -> void:
	_bit_of.clear()
	_tags.clear()
	_declared.clear()
	_warned.clear()
	_frozen = false
	_loaded_file = not read_declarations_file


# --- Queries -----------------------------------------------------------------------------------

## The tag's own bit index, or -1 if it has none (empty tag, or past the 64 limit).
static func bit_of(tag) -> int:
	var t := normalize(tag)
	if t == &"":
		return -1
	_ensure_ready()
	if not _bit_of.has(t):
		_add_late(t, "not declared")
	return _bit_of.get(t, -1)


## Just the tag's own bit as a mask (no parents). Use for lockouts and queries: "lock combat" = own_bit(combat).
static func own_bit(tag) -> int:
	var b := bit_of(tag)
	return 0 if b < 0 else 1 << b


## The tag's bit plus its parents' bits. This is what an ability stores as its category_mask.
static func mask_of(tag) -> int:
	var t := normalize(tag)
	if t == &"":
		return 0
	var mask := 0
	var levels := String(t).split(".")
	var path := ""
	for level in levels:
		path = level if path == "" else path + "." + level
		mask |= own_bit(StringName(path))
	return mask


## OR of several tags' own bits. Use for a list like locks_out = [combat, movement].
static func mask_of_list(tags: Array) -> int:
	var mask := 0
	for t in tags:
		mask |= own_bit(t)
	return mask


## OR of several tags' full masks. Use for an ability's category plus extra_categories.
static func category_mask_of_list(tags: Array) -> int:
	var mask := 0
	for t in tags:
		mask |= mask_of(t)
	return mask


## True if something with this category mask answers to the query tag (matched from the root:
## "combat" and "combat.melee" match combat.melee.sword; "sword" does not).
## A query never adds tags: an unknown tag simply matches nothing.
static func matches(category_mask: int, query_tag) -> bool:
	var t := normalize(query_tag)
	_ensure_ready()
	if not _bit_of.has(t):
		return false
	return (category_mask & (1 << _bit_of[t])) != 0


## True if the tag has a bit already (declared, or added at runtime). Never adds it.
static func has_tag(tag) -> bool:
	_ensure_ready()
	return _bit_of.has(normalize(tag))


## Tag names for the bits in a mask, in bit order. For debug text.
static func names_of(mask: int) -> Array[StringName]:
	_ensure_ready()
	var out: Array[StringName] = []
	for i in _tags.size():
		if mask & (1 << i):
			out.append(_tags[i])
	return out


## How many tags have a bit.
static func get_tag_count() -> int:
	_ensure_ready()
	return _tags.size()


## All tags in bit order.
static func get_tags() -> Array[StringName]:
	_ensure_ready()
	return _tags.duplicate()


## A number that is the same on two machines only if they assign the same bits.
## The netcode handshake compares it (netcode spec section 11.2).
static func content_hash() -> int:
	_ensure_ready()
	return ",".join(PackedStringArray(_tags)).hash()


## Every tag the declarations file declares, with each one's parent levels, sorted: the list a tag dropdown offers
## (addons/tag_picker). It only reads the file, so it changes nothing here: safe in the editor, and before or after the registry is
## in use. Tags declared from code (declare()) aren't in it.
static func read_declared_tags() -> Array[StringName]:
	var out: Array[StringName] = []
	var path: String = ProjectSettings.get_setting(DECLARATIONS_SETTING, DEFAULT_DECLARATIONS_PATH)
	if path == "" or not ResourceLoader.exists(path):
		return out
	var res = load(path)
	if not res is TagDeclarationsRes:
		return out
	var all := {}
	for t in res.tags:
		var tag := normalize(t)
		var level_path := ""
		for level in String(tag).split(".", false):
			level_path = level if level_path == "" else level_path + "." + level
			all[StringName(level_path)] = true
	for tag in all.keys():
		out.append(tag)
	out.sort_custom(func(a, b): return String(a) < String(b))
	return out


## Cleans up a tag name: trims spaces, drops empty levels. Returns &"" for nothing usable.
static func normalize(tag) -> StringName:
	if tag == null:
		return &""
	var parts := PackedStringArray()
	for p in String(tag).split("."):
		var s := p.strip_edges()
		if s != "":
			parts.append(s)
	return StringName(".".join(parts))


# --- Internals ---------------------------------------------------------------------------------

# First real use: read the declarations file (once), then number every declared level in sorted order.
static func _ensure_ready() -> void:
	if _frozen:
		return
	if not _loaded_file:
		_loaded_file = true
		_read_declarations_file()
	var all := {}
	for tag in _declared:
		var path := ""
		for level in String(tag).split("."):
			path = level if path == "" else path + "." + level
			all[StringName(path)] = true
	var sorted: Array = all.keys()
	sorted.sort_custom(func(a, b): return String(a) < String(b))
	_frozen = true
	for tag in sorted:
		_assign(tag)


static func _read_declarations_file() -> void:
	var path: String = ProjectSettings.get_setting(DECLARATIONS_SETTING, DEFAULT_DECLARATIONS_PATH)
	if path == "" or not ResourceLoader.exists(path):
		return # escape clause: no file, every tag is simply undeclared
	var res = load(path)
	if res is TagDeclarationsRes:
		for t in res.tags:
			var tag := normalize(t)
			if tag != &"" and not _declared.has(tag):
				_declared.append(tag)
	else:
		push_warning("[TagRegistry] %s is not a TagDeclarationsRes; no tags declared" % path)


# Adds a tag (and any missing parent levels) after startup numbering.
static func _add_late(tag: StringName, why: String) -> void:
	_ensure_ready()
	var path := ""
	for level in String(tag).split("."):
		path = level if path == "" else path + "." + level
		var t := StringName(path)
		if _bit_of.has(t) or _warned.has(t):
			continue
		if _tags.size() < MAX_BITS:
			_warn_once(t, "[TagRegistry] tag '%s' %s; added as bit %d. Declare it in the tag declarations so multiplayer peers agree." % [t, why, _tags.size()])
		_assign(t)


static func _assign(tag: StringName) -> void:
	if _tags.size() >= MAX_BITS:
		_warn_once(tag, "[TagRegistry] more than %d tag levels; '%s' gets no bit and matches nothing." % [MAX_BITS, tag])
		return
	_bit_of[tag] = _tags.size()
	_tags.append(tag)


static func _warn_once(tag: StringName, message: String) -> void:
	if _warned.has(tag):
		return
	_warned[tag] = true
	push_warning(message)
