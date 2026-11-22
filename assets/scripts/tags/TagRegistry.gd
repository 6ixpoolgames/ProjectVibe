# Written by Claude (claude-opus-5-5), 2026-11-04. History: tags/CHANGELOG.md.
## Every tag in the game: turns names like "ability.combat.melee" into bits, so checks are one AND instead of comparing text.
##
## One registry for every kind of tag (tag spec): what an ability is, what an effect is, a pawn's status, the AI's states and stances,
## navigation markers. A tag's first level is its [b]category[/b] (ability, effect, status, ai, nav); code writes tags as [Tags]
## constants ([code]Tags.ABILITY.COMBAT_MELEE[/code]).
## [br]
## Tag bit rules:
## [br]- A tag is a StringName with dot-separated levels; a dot means "inside" (ability.combat is inside ability). Names only.
## [br]- Every level gets its own bit, numbered within its category: ability, ability.combat and ability.combat.melee are three bits
##   of the ability category's 64-bit word.
## [br]- A tag's mask is its own bit plus its parents' bits, so a query for "ability.combat" catches ability.combat.melee with one AND,
##   and never "ability.combatant". Matching is from the root only.
## [br]- A mask belongs to one category: masks of different categories can't be combined or compared (a list that mixes them warns).
## [br]- At most 64 levels per category; extras get no bit (mask 0, match nothing) with a warning.
## [br]
## Every machine must give a tag the same bit, so tags are declared in [TagDeclarationsRes] files (the base file, then any listed in
## the project setting [constant EXTRA_DECLARATIONS_SETTING]), merged and sorted at startup; the netcode handshake compares
## [method content_hash]. A tag nobody declared is added on the spot with a warning (a desync risk online). Queries never add tags.
## [br]
## Renaming: an old name in a declarations file's redirects is read as its new name, with a warning, so old resources, saves and
## replays still load (tools/tags/apply_redirects.py rewrites saved files). A deprecated tag still works, with a warning. Bits are
## never saved: everything saved stores names. A static class, so it works in headless tests.
# REFACTOR: a category past 64 levels gets no more bits. The tag spec plans extra 64-bit words for such a category; the int masks
# every caller uses today assume one word, so that waits until a category nears the limit (tags/CHANGELOG.md).
class_name TagRegistry
extends RefCounted

## The most levels a category has bits for.
const MAX_BITS_PER_CATEGORY := 64
## The base declarations file, always read.
const BASE_DECLARATIONS_PATH := "res://assets/scripts/resources/tag_declarations.tres"
## A project setting listing more declarations files (a game's, a mod's), read after the base one.
const EXTRA_DECLARATIONS_SETTING := "project_base/tags/extra_declaration_files"

static var _bit_of: Dictionary = {}        # StringName tag -> its bit within its category's word
static var _category_tags: Dictionary = {} # StringName category -> Array[StringName], bit order
static var _categories: Array[StringName] = [] # word order: the category with word 0 first
static var _declared: Array[StringName] = []
static var _descriptions: Dictionary = {}  # StringName tag -> its one-line description
static var _redirects: Dictionary = {}     # StringName old name -> StringName new name
static var _deprecated: Dictionary = {}    # StringName tag -> true
static var _frozen := false                # true once bits are handed out; after that, new tags are appended
static var _loaded_files := false
static var _warned: Dictionary = {}


# --- Setup -------------------------------------------------------------------------------------

## Adds tags to the declared list. Call before the registry is first used (at startup);
## the declarations files are read automatically, so most games never call this.
static func declare(tags: Array) -> void:
	for t in tags:
		var tag := normalize(t)
		if tag == &"":
			continue
		if _frozen:
			_add_late(tag, "declared after the registry was already in use")
		elif not _declared.has(tag):
			_declared.append(tag)


## Adds renames: each old name is read as its new name from then on. Most games put them in a declarations file instead.
static func declare_redirects(redirects: Dictionary) -> void:
	for old_name in redirects:
		_redirects[StringName(old_name)] = StringName(redirects[old_name])


## Marks tags deprecated: they still work, with a warning. Most games put them in a declarations file instead.
static func declare_deprecated(tags: Array) -> void:
	for t in tags:
		_deprecated[_clean(t)] = true


## Forgets everything, including that the declarations files were read. For tests, and for
## tools that reload content. Masks stored before a reset are meaningless afterwards.
static func reset(read_declarations_files := true) -> void:
	_bit_of.clear()
	_category_tags.clear()
	_categories.clear()
	_declared.clear()
	_descriptions.clear()
	_redirects.clear()
	_deprecated.clear()
	_warned.clear()
	_frozen = false
	_loaded_files = not read_declarations_files


# --- Queries -----------------------------------------------------------------------------------

## The tag's own bit within its category's word, or -1 if it has none (empty tag, or past the 64 limit).
static func bit_of(tag) -> int:
	var t := normalize(tag)
	if t == &"":
		return -1
	_ensure_ready()
	if not _bit_of.has(t):
		_add_late(t, "not declared")
	return _bit_of.get(t, -1)


## Just the tag's own bit as a mask (no parents). Use for lockouts and resistances: "lock ability.combat" = own_bit(ability.combat).
static func own_bit(tag) -> int:
	var b := bit_of(tag)
	return 0 if b < 0 else 1 << b


## The tag's bit plus its parents' bits. This is what an ability stores as its category_mask, and a nav marker as its mask.
static func mask_of(tag) -> int:
	var t := normalize(tag)
	if t == &"":
		return 0
	var mask := 0
	var path := ""
	for level in String(t).split("."):
		path = level if path == "" else path + "." + level
		mask |= own_bit(StringName(path))
	return mask


## OR of several tags' own bits, all of one category. Use for a list like locks_out = [ability.combat, ability.movement].
static func mask_of_list(tags: Array) -> int:
	_warn_if_mixed(tags)
	var mask := 0
	for t in tags:
		mask |= own_bit(t)
	return mask


## OR of several tags' full masks, parents included, all of one category. Use for an ability's category plus extra_categories, an
## effect's tags, or a pawn's nav capabilities.
static func full_mask_of_list(tags: Array) -> int:
	_warn_if_mixed(tags)
	var mask := 0
	for t in tags:
		mask |= mask_of(t)
	return mask


## True if something with this mask answers to the query tag (matched from the root: "ability.combat" matches
## ability.combat.melee, "melee" doesn't). The mask must be of the query tag's category. Never adds tags: an unknown tag matches nothing.
static func matches(mask: int, query_tag) -> bool:
	var t := normalize(query_tag)
	_ensure_ready()
	if not _bit_of.has(t):
		return false
	return (mask & (1 << _bit_of[t])) != 0


## True if the tag has a bit already (declared, or added at runtime). Never adds it.
static func has_tag(tag) -> bool:
	_ensure_ready()
	return _bit_of.has(normalize(tag))


## A tag's category: its first level (&"ability" for ability.combat.melee). &"" for an empty tag.
static func category_of(tag) -> StringName:
	var t := String(normalize(tag))
	var dot := t.find(".")
	return StringName(t if dot < 0 else t.substr(0, dot))


## Every category, in word order.
static func get_categories() -> Array[StringName]:
	_ensure_ready()
	return _categories.duplicate()


## The word a category's bits are in (its place in [method get_categories]), or -1 for an unknown category. For records that keep
## one word per category, such as a pawn's owned tags.
static func word_of(category) -> int:
	_ensure_ready()
	return _categories.find(StringName(category))


## Tag names for the bits in a mask of this category, in bit order. For debug text.
static func names_of(mask: int, category) -> Array[StringName]:
	_ensure_ready()
	var out: Array[StringName] = []
	var listed: Array = _category_tags.get(StringName(category), [])
	for i in listed.size():
		if mask & (1 << i):
			out.append(listed[i])
	return out


## How many tags have a bit, in every category.
static func get_tag_count() -> int:
	_ensure_ready()
	return _bit_of.size()


## All tags with a bit, category by category in word order, each category's in bit order.
static func get_tags() -> Array[StringName]:
	_ensure_ready()
	var out: Array[StringName] = []
	for category in _categories:
		out.append_array(_category_tags[category])
	return out


## A tag's one-line description from its declaration, or "".
static func description_of(tag) -> String:
	_ensure_ready()
	return _descriptions.get(normalize(tag), "")


## True if the tag is declared deprecated: it still works, with a warning, until it's removed.
static func is_deprecated(tag) -> bool:
	_ensure_ready()
	return _deprecated.has(normalize(tag))


## A number that is the same on two machines only if they assign the same bits.
## The netcode handshake compares it (netcode spec section 11.2).
static func content_hash() -> int:
	return ",".join(PackedStringArray(get_tags())).hash()


## Every tag the declarations files declare, with each one's parent levels, sorted: the list a tag dropdown offers
## (addons/tag_picker). Only tags of these categories, or every tag with none given; deprecated tags are left out. It only reads the
## files, so it changes nothing here: safe in the editor, and before or after the registry is in use.
static func read_declared_tags(categories: Array = []) -> Array[StringName]:
	var all := {}
	var deprecated := {}
	for res in _declaration_files():
		for tag in res.deprecated:
			deprecated[_clean(tag)] = true
		for t in res.tags:
			var tag := _clean(t)
			if not categories.is_empty() and not categories.has(category_of(tag)):
				continue
			var level_path := ""
			for level in String(tag).split(".", false):
				level_path = level if level_path == "" else level_path + "." + level
				all[StringName(level_path)] = true
	var out: Array[StringName] = []
	for tag in all.keys():
		if not deprecated.has(tag):
			out.append(tag)
	out.sort_custom(func(a, b): return String(a) < String(b))
	return out


## Cleans up a tag name: trims spaces, drops empty levels, and follows a redirect from an old name (warning once). Returns &"" for
## nothing usable.
static func normalize(tag) -> StringName:
	var t := _clean(tag)
	if _redirects.has(t):
		var renamed: StringName = _redirects[t]
		_warn_once(t, "[TagRegistry] '%s' is an old tag name, read as '%s'. Rewrite saved files with tools/tags/apply_redirects.py." % [t, renamed])
		return renamed
	if _deprecated.has(t):
		_warn_once(t, "[TagRegistry] tag '%s' is deprecated: %s" % [t, _descriptions.get(t, "see the tag declarations")])
	return t


# --- Internals ---------------------------------------------------------------------------------

static func _clean(tag) -> StringName:
	if tag == null:
		return &""
	var parts := PackedStringArray()
	for p in String(tag).split("."):
		var s := p.strip_edges()
		if s != "":
			parts.append(s)
	return StringName(".".join(parts))


# First real use: read the declarations files (once), then number every declared level, category by category in sorted order.
static func _ensure_ready() -> void:
	if _frozen:
		return
	if not _loaded_files:
		_loaded_files = true
		_read_declaration_files()
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


# The base file, then the extra ones the project setting lists.
static func _declaration_files() -> Array[TagDeclarationsRes]:
	var paths: Array = [BASE_DECLARATIONS_PATH]
	paths.append_array(ProjectSettings.get_setting(EXTRA_DECLARATIONS_SETTING, []))
	var out: Array[TagDeclarationsRes] = []
	for path: String in paths:
		if path == "" or not ResourceLoader.exists(path):
			continue # escape clause: no file, its tags are simply undeclared
		var res = load(path)
		if res is TagDeclarationsRes:
			out.append(res)
		else:
			push_warning("[TagRegistry] %s is not a TagDeclarationsRes; no tags declared from it" % path)
	return out


static func _read_declaration_files() -> void:
	for res in _declaration_files():
		for old_name in res.redirects:
			_redirects[_clean(old_name)] = _clean(res.redirects[old_name])
		for t in res.deprecated:
			_deprecated[_clean(t)] = true
		for t in res.tags:
			var tag := _clean(t)
			if tag == &"":
				continue
			_descriptions[tag] = res.tags[t]
			if not _declared.has(tag):
				_declared.append(tag)


# Adds a tag (and any missing parent levels) after startup numbering.
static func _add_late(tag: StringName, why: String) -> void:
	_ensure_ready()
	var path := ""
	for level in String(tag).split("."):
		path = level if path == "" else path + "." + level
		var t := StringName(path)
		if _bit_of.has(t) or _warned.has(t):
			continue
		_warn_once(t, "[TagRegistry] tag '%s' %s; added on the spot. Declare it in the tag declarations so multiplayer peers agree." % [t, why])
		_assign(t)


static func _assign(tag: StringName) -> void:
	var category := category_of(tag)
	if not _category_tags.has(category):
		_category_tags[category] = [] as Array[StringName]
		_categories.append(category)
	var listed: Array[StringName] = _category_tags[category]
	if listed.size() >= MAX_BITS_PER_CATEGORY:
		_warn_once(tag, "[TagRegistry] more than %d levels in the '%s' category; '%s' gets no bit and matches nothing." % [MAX_BITS_PER_CATEGORY, category, tag])
		return
	_bit_of[tag] = listed.size()
	listed.append(tag)


# Masks of different categories share bit numbers, so a list that mixes them would be wrong.
static func _warn_if_mixed(tags: Array) -> void:
	if tags.size() < 2:
		return
	var first := category_of(tags[0])
	for t in tags:
		if category_of(t) != first:
			_warn_once(StringName("mixed:" + ",".join(PackedStringArray(tags))), "[TagRegistry] a tag list mixes categories (%s); a mask holds one category's tags." % [tags])
			return


static func _warn_once(key: StringName, message: String) -> void:
	if _warned.has(key):
		return
	_warned[key] = true
	push_warning(message)
