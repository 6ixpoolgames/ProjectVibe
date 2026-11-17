# Written by Claude (claude-opus-5-5), 2026-11-09. History: ai/CHANGELOG.md.
## What a pawn's AI has sensed, and how aware of each thing it is: awareness that rises when seen and fades when not.
##
## A part on the pawn, added by PawnInitializer. Pawn spec section 10.5. One entry per sensed entity, holding:
## [br]- where it was last seen (its last known position) and the tick it was last seen
## [br]- awareness_when_seen: awareness at that sighting, from 0 to 1
## [br]- certain: set the first time awareness reaches 1, cleared when the entry is forgotten
## [br]- threat: a number game mechanics add to; damage dealt to this pawn adds [member threat_per_damage] a point (the
##   EffectManager). Target selection reads it
## [br]- the tick it was last checked by a sense, seen or not, so the next sighting's gain counts the right number of ticks
## [br]
## The entries and the loops over them live in a store: AIMemoryStore in the navcore C++ library when it's available, or
## [AIMemoryStoreGD], the same thing in GDScript. This node keeps every setting, the signals and the functions below, and passes calls
## on, so nothing else needs to know which store runs (pawn spec 10.11). [member use_native] off forces GDScript.
## [br]
## How awareness moves:
## [br]- A sense adds gain each time it sees the entity ([method record_sighting]), up to 1.
## [br]- Seeing an entity that's already certain refills it to 1 at once.
## [br]- Sightings close together ([member continuous_sighting_ticks]) with no unseen check between them count as one look, so
##   awareness doesn't fade between them; it only fades while the entity isn't seen. Reading it between checks says the same: while
##   the last check saw it, at most continuous_sighting_ticks ago, it's held. It starts to fade (counted from when it was last seen)
##   once a check misses it, or once that long passes with no check at all.
## [br]- While it isn't seen, it stays full for a delay, then fades by a [FadeProfile]:
##   awareness now = awareness_when_seen × uncertain_fade.value_at(ticks since seen − uncertain_fade_delay_ticks).
##   [member uncertain_fade] and [member uncertain_fade_delay_ticks] are for uncertain entries; [member certain_fade] and
##   [member certain_fade_delay_ticks] for certain ones. With the default straight lines, an entry is forgotten delay + fade ticks after
##   it was last seen, whatever its awareness was.
## [br]- Nothing drains in the background: awareness is worked out when something asks. An entry is forgotten once its fade has
##   ended ([method forget_old], called by the sensing manager on each full pass), or when its entity is freed or dies.
## [br]
## It asks the context for a decision when an entity is first sensed and when an entry becomes certain, so the AI reacts on that
## tick rather than at its next decision.
## [br]
## How to use it (indexes stay valid until the next forget_old, so use them within one tick):
## [codeblock]
## var i := pawn.ai_context.memory.find(entity)   # -1 when it isn't remembered
## pawn.ai_context.memory.awareness_at(i, tick)
## pawn.ai_context.memory.is_certain_at(i)
## pawn.ai_context.memory.last_known_position_at(i)
## pawn.ai_context.memory.ticks_since_seen_at(i, tick)
## pawn.ai_context.memory.add_threat(entity, 5.0)
## pawn.ai_context.memory.is_native()             # true when the C++ store runs
## [/codeblock]
## Signals: [signal entity_became_certain], [signal entity_forgotten].
class_name AIMemory
extends Node

## Sent when an entry first reaches full awareness.
signal entity_became_certain(entity: Node3D)
## Sent when an entry is forgotten.
signal entity_forgotten(entity: Node3D)

## Ticks an entry that isn't certain stays at full awareness after it was last seen, before its fade starts. So a
## glimpse that just reached Alert keeps the pawn Alert long enough to look and walk over. 300 is 5 s.
@export_range(0, 36000, 1, "or_greater") var uncertain_fade_delay_ticks := 300:
	set(value):
		uncertain_fade_delay_ticks = value
		_configure()
## How awareness fades for uncertain entries, once uncertain_fade_delay_ticks have passed. Empty: a straight line to nothing over 300
## ticks.
@export var uncertain_fade: FadeProfile:
	set(value):
		_listen_to(uncertain_fade, value)
		uncertain_fade = value
		_configure()
## The same delay for certain entries. Longer keeps a pawn searching longer after losing sight of an enemy.
@export_range(0, 36000, 1, "or_greater") var certain_fade_delay_ticks := 0:
	set(value):
		certain_fade_delay_ticks = value
		_configure()
## How awareness fades for certain entries, once certain_fade_delay_ticks have passed. Empty: a straight line to nothing over 1200
## ticks (20 s).
@export var certain_fade: FadeProfile:
	set(value):
		_listen_to(certain_fade, value)
		certain_fade = value
		_configure()
## Two sightings with no unseen check between them, at most this many ticks apart, count as one continuous look, so awareness
## doesn't fade between them. Keep it at least as long as the senses' gap between checks.
@export_range(0, 600, 1, "or_greater") var continuous_sighting_ticks := 30:
	set(value):
		continuous_sighting_ticks = value
		_configure()

## Threat added to an attacker's entry for each health point of damage it does to this pawn (the EffectManager adds it). Target
## selection weighs threat, so whoever hurts the pawn most tends to become its target.
@export var threat_per_damage := 0.01

## Off, every AIMemory made from now on uses the GDScript store even where the C++ library is available. For tests
## that compare the two, and for checking a suspected C++ problem. Read once, when each memory is made.
static var use_native := true

const _FADE_PROFILE_SCRIPT := preload("res://assets/scripts/ai/FadeProfile.gd")

## The pawn this is a part of, or null.
var pawn: Pawn = null

# AIMemoryStore (C++) or AIMemoryStoreGD: the same functions either way. Untyped, because the C++ class only exists when the library
# loads.
var _store: Object = null
var _fades_dirty := true # a fade profile was edited, so the store's copy needs its settings again
var _configured_rate := -1 # the tick rate the store's copy was made at
var _native := false


func _init() -> void:
	set_process(false)
	set_physics_process(false)
	_native = use_native and ClassDB.class_exists(&"AIMemoryStore")
	_store = ClassDB.instantiate(&"AIMemoryStore") if _native else AIMemoryStoreGD.new()


func _enter_tree() -> void:
	pawn = get_parent() as Pawn
	if pawn == null:
		push_warning("AIMemory: its parent isn't a Pawn, so nothing will sense anything for it.")


func _ready() -> void:
	# GDScript note: a Resource export can't have a .new() default in the inspector, so the defaults are made here when empty.
	if uncertain_fade == null:
		uncertain_fade = _straight_line(300) # after uncertain_fade_delay_ticks
	if certain_fade == null:
		certain_fade = _straight_line(1200)
	_configure()


## True when the C++ store runs.
func is_native() -> bool:
	return _native


## The store itself, for SightSense and AITargetSelector, which hand it whole loops.
func get_store() -> Object:
	return _store


## How many entries there are.
func entry_count() -> int:
	return _store.entry_count()


## The entry for this entity, or -1.
func find(entity: Object) -> int:
	return _store.find(entity)


## The entity of an entry, or null if it's been freed.
func entity_at(index: int) -> Node3D:
	return _store.entity_at(index) as Node3D


## Awareness of an entry at this tick, faded since it was last seen.
func awareness_at(index: int, tick: int) -> float:
	return _store.awareness_at(index, tick)


## True if the entry has reached full awareness since it was first sensed.
func is_certain_at(index: int) -> bool:
	return _store.is_certain_at(index)


## Where the entry's entity was last seen.
func last_known_position_at(index: int) -> Vector3:
	return _store.last_known_position_at(index)


## Ticks since the entry's entity was last seen.
func ticks_since_seen_at(index: int, tick: int) -> int:
	return _store.ticks_since_seen_at(index, tick)


## The entry's threat (see [method add_threat]).
func threat_at(index: int) -> float:
	return _store.threat_at(index)


## Ticks since a sense last checked this entity, or fallback if it isn't remembered.
func ticks_since_checked(entity: Object, tick: int, fallback: int) -> int:
	return _store.ticks_since_checked(entity, tick, fallback)


## A sense saw this entity at this tick. gain is added to its awareness; a certain entry refills to 1.
func record_sighting(entity: Node3D, gain: float, tick: int, position: Vector3) -> void:
	var bits: int = _store.record_sighting(entity, gain, tick, position)
	_announce(bits & 1 != 0, [entity] if bits & 2 else [])


## A sense checked this entity at this tick and didn't see it.
func record_check(entity: Object, tick: int) -> void:
	_store.record_check(entity, tick)


## Adds threat to an entity's entry, if it's remembered; threat never goes below 0. Game mechanics call this, such as damage dealt.
func add_threat(entity: Object, amount: float) -> void:
	_store.add_threat(entity, amount)


## Forgets entries whose fade has ended or whose entity is gone. The sensing manager calls this on each full pass.
func forget_old(tick: int) -> void:
	# The C++ store copies a FadeProfile's settings, so they go to it again when a profile announced an edit (changed) or the tick
	# rate changed; otherwise the copy it has is right.
	if _fades_dirty or TickDriver.get_tick_rate() != _configured_rate:
		_configure()
	var forgotten: PackedInt64Array = _store.forget_old(tick)
	for id in forgotten:
		var entity := instance_from_id(id) as Node3D if is_instance_id_valid(id) else null
		if entity:
			entity_forgotten.emit(entity)


## The entry with the highest awareness now, or -1. Ties go to the nearer last known position, then the lower id.
func most_aware_index(tick: int) -> int:
	return _store.most_aware_index(pawn.global_position if pawn else Vector3.ZERO, tick)


## The C++ memory store (AIMemoryStore), or null when the GDScript one runs. The C++ decider reads it directly for the pawn's inputs.
func native_store() -> Object:
	return _store if _native else null


## Forgets everything.
func clear() -> void:
	_store.clear()


## SightSense calls this after a sight check: wakes a decision for a new entry, and sends entity_became_certain.
func announce_sight_results(results: Array) -> void:
	_announce(results[0], results[1])


# --- Internals ---


func _announce(added: bool, became_certain: Array) -> void:
	if added or not became_certain.is_empty():
		if pawn and pawn.ai_context:
			pawn.ai_context.request_decision()
	for entity in became_certain:
		entity_became_certain.emit(entity)


# Passes the fade settings to the store. Runs whenever one changes, so the inspector or code can tune them while the game runs.
func _configure() -> void:
	if _store == null or uncertain_fade == null or certain_fade == null:
		return
	_fades_dirty = false
	_configured_rate = TickDriver.get_tick_rate()
	# The delays and continuous_sighting_ticks are written for 60 ticks a second, and go to the store at this match's rate (scaling
	# spec step 6). The C++ store converts the profiles' own tick settings the same way as FadeProfile does.
	if _store.has_method(&"set_tick_rate"):
		_store.set_tick_rate(TickDriver.get_tick_rate())
	_store.configure_fades(uncertain_fade, TickDriver.ticks_at_rate(uncertain_fade_delay_ticks), _is_custom(uncertain_fade),
			certain_fade, TickDriver.ticks_at_rate(certain_fade_delay_ticks), _is_custom(certain_fade), TickDriver.ticks_at_rate(continuous_sighting_ticks))


# Listens to the profile now in use for edits made while the game runs (FadeProfile sends changed), and stops listening to the old.
func _listen_to(old: FadeProfile, new: FadeProfile) -> void:
	if old and old.changed.is_connected(_on_fade_edited):
		old.changed.disconnect(_on_fade_edited)
	if new and not new.changed.is_connected(_on_fade_edited):
		new.changed.connect(_on_fade_edited)


func _on_fade_edited() -> void:
	_fades_dirty = true


# A profile whose script isn't FadeProfile itself may override value_at(), so the C++ store calls it rather than doing the maths.
static func _is_custom(profile: FadeProfile) -> bool:
	return profile.get_script() != _FADE_PROFILE_SCRIPT


# A LINEAR FadeProfile from full to nothing over this many ticks: the default fades.
static func _straight_line(ticks: int) -> FadeProfile:
	var profile := FadeProfile.new()
	profile.mode = FadeProfile.Mode.LINEAR
	profile.fade_ticks = ticks
	return profile
