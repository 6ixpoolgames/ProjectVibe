## Written by Claude (claude-opus-5-5), 2026-11-10: effect type tags, such as damage.elemental.fire, turned into bits (pawn spec 8.11).
## What KIND of effect something is: resistances, immunities and "remove every poison" go by these. The owner's design: a separate
## tag set from the abilities' (TagRegistry), so each has its own 64 bits.
##
## The same rules as TagRegistry and NavTags, in a separate copy as NavTags is, so working code doesn't change:
##   - A tag is a name with dot-separated levels. A dot means "inside": damage.elemental.fire is inside damage.elemental, which is
##     inside damage.
##   - Every level gets its own bit. damage, damage.elemental and damage.elemental.fire are three bits.
##   - A tag's MASK holds its own bit plus its parents' bits. So a resistance to "damage.elemental" catches fire and frost with one
##     AND, and never catches "damaged" (whole levels only).
##   - The game lists its tags in a declarations file (resources/effect_tag_declarations.tres), and they're sorted and numbered at
##     startup, the same on every machine.
##
## Code writes tags as the constants below (EffectTags.DAMAGE_PHYSICAL), never as text, so a misspelling is an error when the script
## is checked. Designers pick them from dropdowns (addons/tag_picker). A constant here must be declared in the file:
## effects/tests/effect_selftest checks it.
##
## What happens in odd cases (checked in effects/tests/effect_selftest.gd):
##   - Empty or blank tag: no bit, mask 0, matches nothing. Never an error.
##   - A tag nobody declared: added on the spot with a one-time warning. Fine offline; machines may disagree online, which is what
##     the warning is for. Questions (has_tag) never add tags.
##   - More than 64 levels: the extra ones get no bit, match nothing, and warn once.
##   - No declarations file: everything still works, and every tag just counts as undeclared.
##
# GDScript note: everything here is static, so nobody makes an EffectTags object: call EffectTags.mask_of(...) on the class.
class_name EffectTags
extends RefCounted

# --- The declared tags, as constants for code ------------------------------------------------------

const DAMAGE := &"damage"
const DAMAGE_PHYSICAL := &"damage.physical"
const DAMAGE_ELEMENTAL := &"damage.elemental"
const DAMAGE_ELEMENTAL_FIRE := &"damage.elemental.fire"
const DAMAGE_ELEMENTAL_FROST := &"damage.elemental.frost"
const DAMAGE_POISON := &"damage.poison"
const HEAL := &"heal"
const BUFF := &"buff"
const BUFF_COMBO := &"buff.combo"
const DEBUFF := &"debuff"
const DEBUFF_SLOW := &"debuff.slow"

const MAX_BITS := 64
## The file read by default. A game can point somewhere else with the project setting below.
const DEFAULT_DECLARATIONS_PATH := "res://assets/scripts/resources/effect_tag_declarations.tres"
const DECLARATIONS_SETTING := "project_base/effects/tag_declarations_path"

static var _bit_of: Dictionary = {}      # tag name -> its bit number. Every level is a tag of its own.
static var _tags: Array[StringName] = [] # bit number -> tag name
static var _declared: Array[StringName] = []
static var _frozen := false              # true once bits are handed out. After that, new tags go on the end.
static var _loaded_file := false
static var _warned: Dictionary = {}


# --- Setup -------------------------------------------------------------------------------------

## Adds tags to the declared list. The file is read automatically, so most games never call this. Call it at startup.
static func declare(tags: Array) -> void:
	for raw_tag in tags:
		var tag := normalize(raw_tag)
		if tag == &"":
			continue
		if _frozen:
			_add_late(tag, "declared after EffectTags was already in use")
		elif not _declared.has(tag):
			_declared.append(tag)


## Forgets everything, including that the file was read. For tests. Masks saved before a reset mean nothing afterwards.
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
	return _bit_of.get(clean_tag, -1)


## Just the tag's own bit as a mask, with no parents. A resistance to damage.elemental is stored as this: it catches every effect
## whose mask has that bit, which is every effect tagged damage.elemental or anything inside it.
static func own_bit(tag) -> int:
	var bit := bit_of(tag)
	return 0 if bit < 0 else 1 << bit


## The tag's bit plus its parents' bits. What an effect stores for each of its tags.
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


## Several tags' full masks together, parents included. An effect's tags as one mask.
static func full_mask_of_list(tags: Array) -> int:
	var mask := 0
	for tag in tags:
		mask |= mask_of(tag)
	return mask


# --- Questions -----------------------------------------------------------------------------------

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


## All tags in bit order. A copy.
static func get_tags() -> Array[StringName]:
	_ensure_ready()
	return _tags.duplicate()


## Every tag the declarations file declares, with each one's parent levels, sorted: the list a tag dropdown offers
## (addons/tag_picker). It only reads the file, so it's safe in the editor and changes nothing here.
static func read_declared_tags() -> Array[StringName]:
	var out: Array[StringName] = []
	var path: String = ProjectSettings.get_setting(DECLARATIONS_SETTING, DEFAULT_DECLARATIONS_PATH)
	if path == "" or not ResourceLoader.exists(path):
		return out
	var loaded = load(path)
	if not loaded is TagDeclarationsRes:
		return out
	var all := {}
	for raw_tag in loaded.tags:
		var level_path := ""
		for level in String(normalize(raw_tag)).split(".", false):
			level_path = level if level_path == "" else level_path + "." + level
			all[StringName(level_path)] = true
	for tag in all.keys():
		out.append(tag)
	out.sort_custom(func(a, b): return String(a) < String(b))
	return out


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

## On first real use: reads the file (once), then numbers every declared level in sorted order, so every machine agrees.
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
			all_levels[StringName(path)] = true
	var sorted_levels: Array = all_levels.keys()
	sorted_levels.sort_custom(func(a, b): return String(a) < String(b))
	_frozen = true
	for tag in sorted_levels:
		_assign(tag)


static func _read_declarations_file() -> void:
	var path: String = ProjectSettings.get_setting(DECLARATIONS_SETTING, DEFAULT_DECLARATIONS_PATH)
	if path == "" or not ResourceLoader.exists(path):
		return
	var loaded = load(path)
	if loaded is TagDeclarationsRes:
		for raw_tag in loaded.tags:
			var tag := normalize(raw_tag)
			if tag != &"" and not _declared.has(tag):
				_declared.append(tag)
	else:
		push_warning("[EffectTags] %s is not a TagDeclarationsRes; no effect tags declared" % path)


static func _add_late(tag: StringName, why: String) -> void:
	_ensure_ready()
	var path := ""
	for level in String(tag).split("."):
		path = level if path == "" else path + "." + level
		var level_tag := StringName(path)
		if _bit_of.has(level_tag) or _warned.has(level_tag):
			continue
		if _tags.size() < MAX_BITS:
			_warn_once(level_tag, "[EffectTags] tag '%s' %s; added as bit %d. Declare it in the effect tag declarations so multiplayer machines agree." % [level_tag, why, _tags.size()])
		_assign(level_tag)


static func _assign(tag: StringName) -> void:
	if _tags.size() >= MAX_BITS:
		_warn_once(tag, "[EffectTags] more than %d tag levels; '%s' gets no bit and matches nothing." % [MAX_BITS, tag])
		return
	_bit_of[tag] = _tags.size()
	_tags.append(tag)


static func _warn_once(tag: StringName, message: String) -> void:
	if _warned.has(tag):
		return
	_warned[tag] = true
	push_warning(message)
