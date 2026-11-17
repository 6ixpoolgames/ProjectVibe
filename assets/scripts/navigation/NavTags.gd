# Written by Claude (claude-opus-5-5), 2026-11-06. History: navigation/CHANGELOG.md.
## Navigation's own tag names and bits (nav spec 21.3).
##
## Turns names like "link.jump" into bits, so nav and AI check tags with one AND instead of comparing text. Abilities have their own
## tags ([TagRegistry]); each system gets its own 64 bits. A tag is a name with dot-separated levels, and each level has its own bit:
## a tag's mask is its own bit plus its parents', so a search for "link" finds link.jump but never "linkage".
## [br]
## In multiplayer every machine must give a tag the same bit, so the game lists its tags in a declarations file and NavTags sorts and
## numbers them at startup, identically everywhere. An undeclared tag is added on the spot with a one-time warning (machines may
## disagree online); declaring after use counts as undeclared, since sorting again would change stored masks. Past 64 levels, tags get
## no bit and match nothing. Searches never add tags.
# REFACTOR: the same rules as TagRegistry, copied on purpose when it was written. One tag-set class used twice (abilities, nav)
# would halve the code and the tests. See CHANGELOG.md.
# @tool lets this run in the editor, so NavMarkerNode can warn about an undeclared tag there.
@tool
class_name NavTags
extends RefCounted

const MAX_BITS := 64
## The file read by default. A game can point somewhere else with the project setting below.
const DEFAULT_DECLARATIONS_PATH := "res://assets/scripts/resources/nav_tag_declarations.tres"
const DECLARATIONS_SETTING := "project_base/nav/tag_declarations_path"

static var _bit_of: Dictionary = {}      # tag name -> its bit number. Every level is a tag of its own.
static var _tags: Array[StringName] = [] # bit number -> tag name, so the reverse of _bit_of
static var _declared: Array[StringName] = [] # tags listed so far, before numbering
static var _frozen := false              # true once bits are handed out. After that, new tags go on the end.
static var _loaded_file := false         # so the declarations file is only read once
static var _warned: Dictionary = {}      # tags already warned about, so each warning shows only once


# --- Setup -------------------------------------------------------------------------------------

## Adds tags to the declared list. The file is read automatically, so most games never call this.
## If you do, call it at startup, before anything uses NavTags.
static func declare(tags: Array) -> void:
	for raw_tag in tags:
		var tag := normalize(raw_tag)
		if tag == &"":
			continue
		if _frozen:
			_add_late(tag, "declared after NavTags was already in use")
		elif not _declared.has(tag):
			_declared.append(tag)


## Forgets everything, including that the file was read. For tests and tools that reload content.
## Masks saved before a reset mean nothing afterwards.
static func reset(read_declarations_file := true) -> void:
	_bit_of.clear()
	_tags.clear()
	_declared.clear()
	_warned.clear()
	_frozen = false
	_loaded_file = not read_declarations_file


# --- Turning names into bits ---------------------------------------------------------------------

## The tag's own bit number, or -1 if it has none (empty tag, or past the 64 limit).
static func bit_of(tag) -> int:
	var clean_tag := normalize(tag)
	if clean_tag == &"":
		return -1
	_ensure_ready()
	if not _bit_of.has(clean_tag):
		_add_late(clean_tag, "not declared")
	return _bit_of.get(clean_tag, -1) # the second value is what comes back if the key isn't there


## Just the tag's own bit as a mask, with no parents. For a "forbidden" list: forbidding link.door shouldn't forbid all of link.
static func own_bit(tag) -> int:
	var bit := bit_of(tag)
	return 0 if bit < 0 else 1 << bit


## The tag's bit plus its parents' bits. This is what a marker stores, so a search for any level finds it.
static func mask_of(tag) -> int:
	var clean_tag := normalize(tag)
	if clean_tag == &"":
		return 0
	var mask := 0
	var path := ""
	for level in String(clean_tag).split("."):
		path = level if path == "" else path + "." + level
		mask |= own_bit(StringName(path))
	return mask


## Several tags' own bits together. For a list like forbidden = [link.door, area.hazard].
static func mask_of_list(tags: Array) -> int:
	var mask := 0
	for tag in tags:
		mask |= own_bit(tag)
	return mask


## Several tags' full masks together, parents included. For a pawn's capabilities, such as
## [link.jump, link.climb], because a link's mask includes its parents' bits and has to fit inside this.
static func full_mask_of_list(tags: Array) -> int:
	var mask := 0
	for tag in tags:
		mask |= mask_of(tag)
	return mask


# --- Questions -----------------------------------------------------------------------------------

## True if something with this mask answers to the search tag, from the first level: "link" and "link.jump" find link.jump, "jump"
## doesn't. Never adds tags: an unknown tag matches nothing.
static func matches(mask: int, search_tag) -> bool:
	var clean_tag := normalize(search_tag)
	_ensure_ready()
	if not _bit_of.has(clean_tag):
		return false
	return (mask & (1 << _bit_of[clean_tag])) != 0


## True if the tag has a bit already. Never adds it.
static func has_tag(tag) -> bool:
	_ensure_ready()
	return _bit_of.has(normalize(tag))


## The tag names for the bits in a mask, in bit order. For debug text.
static func names_of(mask: int) -> Array[StringName]:
	_ensure_ready()
	var names: Array[StringName] = []
	for bit in _tags.size():
		if mask & (1 << bit):
			names.append(_tags[bit])
	return names


static func get_tag_count() -> int:
	_ensure_ready()
	return _tags.size()


## All tags in bit order. It's a copy, so changing it can't damage the real list.
static func get_tags() -> Array[StringName]:
	_ensure_ready()
	return _tags.duplicate()


## A number that matches on two machines only if they give every tag the same bit.
## The multiplayer handshake compares it (NetworkSession.content_hash).
static func content_hash() -> int:
	_ensure_ready()
	return ",".join(PackedStringArray(_tags)).hash()


## Cleans up a tag name: trims spaces and drops empty levels. Returns &"" if nothing usable is left.
static func normalize(tag) -> StringName:
	if tag == null:
		return &""
	var levels := PackedStringArray()
	for level in String(tag).split("."):
		var clean_level := level.strip_edges()
		if clean_level != "":
			levels.append(clean_level)
	return StringName(".".join(levels))


# --- Internals -----------------------------------------------------------------------------------

## On first real use: reads the file (once), then numbers every declared level in sorted order.
## Sorting is what makes every machine agree, whatever order the tags were declared in.
static func _ensure_ready() -> void:
	if _frozen:
		return
	if not _loaded_file:
		_loaded_file = true
		_read_declarations_file()
	var all_levels := {}
	for tag in _declared:
		var path := ""
		for level in String(tag).split("."):
			path = level if path == "" else path + "." + level
			all_levels[StringName(path)] = true # a Dictionary used as a set, so each level appears once
	var sorted_levels: Array = all_levels.keys()
	sorted_levels.sort_custom(func(a, b): return String(a) < String(b))
	_frozen = true
	for tag in sorted_levels:
		_assign(tag)


static func _read_declarations_file() -> void:
	var path: String = ProjectSettings.get_setting(DECLARATIONS_SETTING, DEFAULT_DECLARATIONS_PATH)
	if path == "" or not ResourceLoader.exists(path):
		return # no file is allowed: every tag simply counts as undeclared
	var loaded = load(path)
	if loaded is TagDeclarationsRes:
		for raw_tag in loaded.tags:
			var tag := normalize(raw_tag)
			if tag != &"" and not _declared.has(tag):
				_declared.append(tag)
	else:
		push_warning("[NavTags] %s is not a TagDeclarationsRes; no nav tags declared" % path)


## Adds a tag, and any parent levels it's missing, after the startup numbering.
static func _add_late(tag: StringName, why: String) -> void:
	_ensure_ready()
	var path := ""
	for level in String(tag).split("."):
		path = level if path == "" else path + "." + level
		var level_tag := StringName(path)
		if _bit_of.has(level_tag) or _warned.has(level_tag):
			continue
		if _tags.size() < MAX_BITS:
			_warn_once(level_tag, "[NavTags] tag '%s' %s; added as bit %d. Declare it in the nav tag declarations so multiplayer machines agree." % [level_tag, why, _tags.size()])
		_assign(level_tag)


static func _assign(tag: StringName) -> void:
	if _tags.size() >= MAX_BITS:
		_warn_once(tag, "[NavTags] more than %d tag levels; '%s' gets no bit and matches nothing." % [MAX_BITS, tag])
		return
	_bit_of[tag] = _tags.size()
	_tags.append(tag)


static func _warn_once(tag: StringName, message: String) -> void:
	if _warned.has(tag):
		return
	_warned[tag] = true
	push_warning(message)
