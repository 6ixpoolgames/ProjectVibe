# Written by Claude (claude-opus-5-5), 2026-11-22. History: tags/CHANGELOG.md.
## The tags a pawn owns right now, counted: what a [TagQuery] asks about ("is it in combat, dead, out of ammo?"). Tag spec 3.
##
## A part on the pawn, added by PawnInitializer; [code]pawn.owned_tags[/code]. A tag is owned while its count is above 0, and owning a
## tag owns its parents too ([code]ability.combat.melee[/code] answers to [code]ability.combat[/code]). Two kinds of adding:
## [br]- [b]Sources:[/b] the pawn's parts say which tags they add now, and each new list replaces their last ([method set_source]). A
## running timed ability adds its category and extra categories, held effects their tags, the Death ability [code]status.dead[/code],
## the AI state manager its state's tag. Those follow state that already rolls back, so they're set again when a rollback loads it.
## [br]- [b]Loose tags:[/b] what game code adds itself ([method add], [method remove]). Counted, pushed to the state store and rolled
## back, so a client's prediction agrees with the server.
## [codeblock]
## pawn.owned_tags.add(&"status.burning")          # a loose tag; remove() it as many times as it was added
## pawn.owned_tags.has(Tags.STATUS.DEAD)           # owned, or a tag under it is
## query.matches(pawn.owned_tags)                  # a TagQuery: all of / any of / none of
## [/codeblock]
class_name OwnedTags
extends Node

## A tag became owned (owned true) or stopped being owned. Only for the tag itself, not its parents. Fires during a rollback too.
signal changed(tag: StringName, owned: bool)

## The pawn it belongs to (its parent), or null outside a pawn.
var pawn: Pawn = null
## Loose tags and their counts, {tag: count}: rolled back (a pushed entry in the pawn's TickStateComponent). Change them with
## [method add] and [method remove]; setting the whole list is for rollback and snapshots.
var loose_counts: Dictionary:
	get:
		return _loose
	set(value):
		_load_loose(value)

var _loose := {}   # StringName tag -> count
var _counts := {}  # StringName tag -> count over every source and the loose tags
var _sources := {} # source key -> Array[StringName], what that source adds now
var _words := PackedInt64Array() # one word per category, owned tags with their parents; worked out again when ownership changes
var _words_dirty := false
var _words_generation := -1 # TagRegistry.generation the words were worked out for
var _tick_state: TickStateComponent = null
var _state_key := ""


func _init() -> void:
	set_process(false)
	set_physics_process(false)


func _enter_tree() -> void:
	pawn = get_parent() as Pawn
	# It tells its pawn it's here, before any part's _ready; the first OwnedTags a pawn has is the one it uses.
	if pawn and not is_instance_valid(pawn.owned_tags):
		pawn.owned_tags = self


# The loose tags roll back: listed with the pawn's TickStateComponent before the first tick, pushed when they change.
func _ready() -> void:
	if pawn == null:
		return
	var key := "%s:loose_counts" % String(pawn.get_path_to(self))
	for child in pawn.get_children():
		if child is TickStateComponent:
			var entries: Array[String] = [key + " pushed"]
			if child.add_state_properties(entries):
				_tick_state = child
				_state_key = key
			break


# --- Asking -------------------------------------------------------------------------------------


## True if this tag, or a tag under it, is owned. Never adds a tag: one that was never declared or owned is never owned.
func has(tag: StringName) -> bool:
	var t := TagRegistry.normalize(tag)
	var bit := TagRegistry.known_bit_of(t)
	var word := TagRegistry.word_of(TagRegistry.category_of(t))
	var words := get_words()
	return bit >= 0 and word >= 0 and word < words.size() and words[word] & (1 << bit) != 0


## How many times this exact tag is owned now, over every source and the loose tags (not counting tags under it).
func count_of(tag: StringName) -> int:
	return _counts.get(TagRegistry.normalize(tag), 0)


## True if the query passes for these tags: the same as [code]query.matches(self)[/code]. A null query passes.
func matches(query: TagQuery) -> bool:
	return query == null or query.matches(self)


## Every tag owned now (not their parents), sorted. For readouts and tests.
func get_owned() -> Array[StringName]:
	var out: Array[StringName] = []
	for tag: StringName in _counts:
		out.append(tag)
	out.sort_custom(func(a, b): return String(a) < String(b))
	return out


## The owned tags as bits: one word per category, in [method TagRegistry.get_categories] order, parents included. Don't change it.
func get_words() -> PackedInt64Array:
	if _words_dirty or _words_generation != TagRegistry.generation:
		_rebuild_words()
	return _words


# --- Loose tags ---------------------------------------------------------------------------------


## Adds a loose tag (count times). Rolled back; remove it as many times as it was added. An undeclared tag is added to the registry
## with a warning, as anywhere.
func add(tag: StringName, count := 1) -> void:
	var t := TagRegistry.normalize(tag)
	if t == &"" or count <= 0:
		return
	_loose[t] = _loose.get(t, 0) + count
	_change(t, count)
	_push_loose()


## Takes a loose tag away (count times, at most as many as were added). Tags from sources can't be removed here.
func remove(tag: StringName, count := 1) -> void:
	var t := TagRegistry.normalize(tag)
	var had: int = _loose.get(t, 0)
	if had <= 0 or count <= 0:
		return
	var taken := mini(count, had)
	if had == taken:
		_loose.erase(t)
	else:
		_loose[t] = had - taken
	_change(t, -taken)
	_push_loose()


## How many times this loose tag was added and not yet removed.
func loose_count_of(tag: StringName) -> int:
	return _loose.get(TagRegistry.normalize(tag), 0)


# --- Sources ------------------------------------------------------------------------------------


## For the pawn's parts: the tags this source adds now, replacing what it added before. source is anything that names it (the part
## itself, or a name); an empty list takes its tags away. A tag listed twice counts twice. Not rolled back here: a source sets its tags
## again from its own state when a rollback loads it.
func set_source(source: Variant, tags: Array) -> void:
	var old: Array = _sources.get(source, [])
	var new: Array[StringName] = []
	for tag in tags:
		var t := TagRegistry.normalize(tag)
		if t != &"":
			new.append(t)
	if old == new:
		return
	if new.is_empty():
		_sources.erase(source)
	else:
		_sources[source] = new
	for t: StringName in old:
		_change(t, -1)
	for t: StringName in new:
		_change(t, 1)


## Takes away every tag this source adds.
func clear_source(source: Variant) -> void:
	set_source(source, [])


# --- Internals ----------------------------------------------------------------------------------


func _change(tag: StringName, delta: int) -> void:
	var before: int = _counts.get(tag, 0)
	var after := before + delta
	if after > 0:
		_counts[tag] = after
	else:
		_counts.erase(tag)
	if (before > 0) != (after > 0):
		_words_dirty = true
		changed.emit(tag, after > 0)


func _rebuild_words() -> void:
	_words_dirty = false
	_words_generation = TagRegistry.generation
	_words.resize(TagRegistry.get_categories().size())
	_words.fill(0)
	for tag: StringName in _counts:
		var mask := TagRegistry.mask_of(tag) # an owned tag is real: one nobody declared is added, with a warning
		var word := TagRegistry.word_of(TagRegistry.category_of(tag))
		if word < 0:
			continue
		if word >= _words.size(): # its category was added by the line above
			var at := _words.size()
			_words.resize(word + 1)
			for i in range(at, _words.size()):
				_words[i] = 0
		_words[word] |= mask


func _push_loose() -> void:
	if _tick_state:
		_tick_state.push_value(_state_key, _loose)


# A rollback or a snapshot set the loose tags: count the difference, and keep a copy of our own.
func _load_loose(value: Dictionary) -> void:
	var old := _loose
	_loose = value.duplicate()
	for tag in old:
		var t := StringName(tag)
		var delta: int = int(_loose.get(t, 0)) - int(old[tag])
		if delta != 0:
			_change(t, delta)
	for tag in _loose:
		var t := StringName(tag)
		if not old.has(t):
			_change(t, int(_loose[tag]))
