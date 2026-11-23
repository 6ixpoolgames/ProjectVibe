# Written by Claude (claude-opus-5-5), 2026-11-22. History: tags/CHANGELOG.md.
## A yes/no question about a pawn's owned tags: all of these, any of those, none of the others (tag spec 4).
##
## All three lists must pass. A tag in a list covers the tags under it: [code]none_of = [status][/code] fails for a pawn that owns
## [code]status.dead[/code]. An empty query always passes. Ask it with [method matches] ([code]query.matches(pawn.owned_tags)[/code]):
## it's compiled to one mask per category word the first time, so asking costs a few ANDs. A tag nobody has declared can't be owned:
## in [member all_of] it makes the query fail, in the other two it counts for nothing. Edit a list by assigning a new one (a setter
## notices), not by appending to it.
## [codeblock]
## var calm := TagQuery.make([], [], [Tags.AI.STATE_COMBAT, Tags.STATUS.DEAD])   # not in combat, not dead
## if calm.matches(pawn.owned_tags): ...
## [/codeblock]
class_name TagQuery
extends Resource

## Every one of these must be owned (or a tag under it): "only when".
@export var all_of: Array[StringName] = []:
	set(value):
		all_of = value
		_compiled_generation = -1
## At least one of these must be owned (or a tag under it): "when this or that". Empty passes.
@export var any_of: Array[StringName] = []:
	set(value):
		any_of = value
		_compiled_generation = -1
## None of these may be owned (nor a tag under them): "not when".
@export var none_of: Array[StringName] = []:
	set(value):
		none_of = value
		_compiled_generation = -1

# The lists as one mask per category word, worked out on first use and again when the registry changes (a reset, or a tag added late).
var _all := PackedInt64Array()
var _any := PackedInt64Array()
var _none := PackedInt64Array()
var _impossible := false # all_of names a tag with no bit, which nothing can own
var _needs_any := false
var _compiled_generation := -1
var _compiled_tag_count := -1
static var _shared := {} # shared()'s queries, by their lists as text


## A query made in code, for tests and for game code that builds one on the fly.
static func make(all: Array = [], any: Array = [], none: Array = []) -> TagQuery:
	var query := TagQuery.new()
	query.all_of = _typed(all)
	query.any_of = _typed(any)
	query.none_of = _typed(none)
	return query


## True if the owned tags pass all three lists. A null owner owns nothing: only a query with an empty all_of and any_of passes.
func matches(owned: OwnedTags) -> bool:
	return matches_words(owned.get_words() if owned else PackedInt64Array())


## The same as [method matches], for owned tags given as one word per category, in [method TagRegistry.get_categories] order.
func matches_words(words: PackedInt64Array) -> bool:
	_compile_if_needed()
	if _impossible:
		return false
	var any_hit := not _needs_any
	for i in _all.size():
		var word: int = words[i] if i < words.size() else 0
		if word & _all[i] != _all[i] or word & _none[i] != 0:
			return false
		if word & _any[i] != 0:
			any_hit = true
	return any_hit


## The query compiled, for C++ (the AI decider) and saved records: the three lists by name, and as one word per category in
## [method TagRegistry.get_categories] order (all, any, none), with impossible (all_of names a tag nothing can own).
func describe_words() -> Dictionary:
	_compile_if_needed()
	return {"all_of": _names(all_of), "any_of": _names(any_of), "none_of": _names(none_of),
		"all": _all.duplicate(), "any": _any.duplicate(), "none": _none.duplicate(), "impossible": _impossible}


## Owned tag names as one word per category, parents included, as [method OwnedTags.get_words] gives them: for a saved list of owned
## tags read back in another run, where the bits may differ.
static func words_of(tags: Array) -> PackedInt64Array:
	var words := _empty_words(TagRegistry.get_categories().size())
	for tag in tags:
		var t := TagRegistry.normalize(tag)
		var mask := TagRegistry.mask_of(t)
		var word := TagRegistry.word_of(TagRegistry.category_of(t))
		if word >= words.size(): # a category added by mask_of
			words.resize(word + 1)
		if word >= 0:
			words[word] |= mask
	return words


## A query made once and shared, for a script's built-in default (every behaviour of a kind reads the same one). Don't change it:
## assign a new query instead.
static func shared(all: Array = [], any: Array = [], none: Array = []) -> TagQuery:
	var key := "%s|%s|%s" % [all, any, none]
	var query: TagQuery = _shared.get(key)
	if query == null:
		query = make(all, any, none)
		_shared[key] = query
	return query


## True if every list is empty: the query passes for anyone.
func is_empty() -> bool:
	return all_of.is_empty() and any_of.is_empty() and none_of.is_empty()


## The query as text, for readouts and logs: "all of [..], any of [..], none of [..]", leaving out empty lists.
func describe() -> String:
	var parts := PackedStringArray()
	if not all_of.is_empty():
		parts.append("all of %s" % [all_of])
	if not any_of.is_empty():
		parts.append("any of %s" % [any_of])
	if not none_of.is_empty():
		parts.append("none of %s" % [none_of])
	return ", ".join(parts) if not parts.is_empty() else "anything"


func _compile_if_needed() -> void:
	var tag_count := TagRegistry.get_tag_count()
	if _compiled_generation == TagRegistry.generation and _compiled_tag_count == tag_count:
		return
	_compiled_generation = TagRegistry.generation
	_compiled_tag_count = tag_count
	var words := TagRegistry.get_categories().size()
	_all = _empty_words(words)
	_any = _empty_words(words)
	_none = _empty_words(words)
	_impossible = false
	_needs_any = not any_of.is_empty()
	for tag in all_of:
		if not _add_bit(_all, tag):
			_impossible = true
	for tag in any_of:
		_add_bit(_any, tag)
	for tag in none_of:
		_add_bit(_none, tag)


# Sets the tag's own bit in its category's word. False if it has no bit (never declared nor owned). Queries never add tags.
static func _add_bit(words: PackedInt64Array, tag: StringName) -> bool:
	var bit := TagRegistry.known_bit_of(tag)
	var word := TagRegistry.word_of(TagRegistry.category_of(TagRegistry.normalize(tag)))
	if bit < 0 or word < 0 or word >= words.size():
		return false
	words[word] |= 1 << bit
	return true


static func _empty_words(count: int) -> PackedInt64Array:
	var words := PackedInt64Array()
	words.resize(count)
	words.fill(0)
	return words


static func _names(tags: Array[StringName]) -> Array:
	var out: Array = []
	for tag in tags:
		out.append(String(tag))
	return out


static func _typed(tags: Array) -> Array[StringName]:
	var out: Array[StringName] = []
	for tag in tags:
		out.append(StringName(tag))
	return out
