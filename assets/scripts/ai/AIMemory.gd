## Written by Claude (claude-opus-5-5), 2026-11-09: what a pawn's AI has sensed, and how aware of each thing it is. A part on the pawn,
## added by PawnInitializer. Pawn spec section 10.5.
##
## One entry per sensed entity, holding:
##   - where it was last seen (its last known position) and the tick it was last seen
##   - awareness_when_seen: awareness at that sighting, from 0 to 1
##   - certain: set the first time awareness reaches 1, cleared when the entry is forgotten
##   - threat: a number game mechanics add to (damage dealt, say). 0 in t0; target selection reads it
##   - the tick it was last checked by a sense, seen or not, so the next sighting's gain counts the right number of ticks
## Claude 2026-11-09: the entries and the loops over them live in a store: AIMemoryStore in the navcore C++ library when it's
## available, or AIMemoryStoreGD, the same thing in GDScript. This node keeps every setting, the signals and the functions below, and
## passes calls on, so nothing else needs to know which store runs (pawn spec 10.11). AIMemory.use_native = false forces GDScript.
##
## How awareness moves:
##   - A sense adds gain each time it sees the entity (record_sighting), up to 1.
##   - Seeing an entity that's already certain refills it to 1 at once.
##   - Claude 2026-11-09: sightings close together (continuous_sighting_ticks) with no unseen check between them count as one look,
##     so awareness doesn't fade between them; it only fades while the entity isn't seen.
##   - While it isn't seen, it stays full for a delay, then fades by a FadeProfile:
##     awareness now = awareness_when_seen × uncertain_fade.value_at(ticks since seen − uncertain_fade_delay_ticks).
##     uncertain_fade and uncertain_fade_delay_ticks are for uncertain entries; certain_fade and certain_fade_delay_ticks for certain
##     ones. With the default straight lines, an entry is forgotten delay + fade ticks after it was last seen, whatever its awareness
##     was.
##   - Nothing drains in the background: awareness is worked out when something asks. An entry is forgotten once its fade has
##     ended (forget_old, called by the sensing manager on each full pass), or when its entity is freed.
##
## It asks the context for a decision when an entity is first sensed and when an entry becomes certain, so the AI reacts on that
## tick rather than at its next decision.
##
## How to use it (indexes stay valid until the next forget_old, so use them within one tick):
##   var i := pawn.ai_memory.find(entity)          # -1 when it isn't remembered
##   pawn.ai_memory.awareness_at(i, tick)
##   pawn.ai_memory.is_certain_at(i)
##   pawn.ai_memory.last_known_position_at(i)
##   pawn.ai_memory.ticks_since_seen_at(i, tick)
##   pawn.ai_memory.add_threat(entity, 5.0)
##   pawn.ai_memory.is_native()                    # true when the C++ store runs
##   entity_became_certain(entity), entity_forgotten(entity)
class_name AIMemory
extends Node

## Sent when an entry first reaches full awareness.
signal entity_became_certain(entity: Node3D)
## Sent when an entry is forgotten.
signal entity_forgotten(entity: Node3D)

## Claude 2026-11-09: ticks an entry that isn't certain stays at full awareness after it was last seen, before its fade starts. So a
## glimpse that just reached Alert keeps the pawn Alert long enough to look and walk over. 300 is 5 s.
@export_range(0, 36000, 1, "or_greater") var uncertain_fade_delay_ticks := 300:
	set(value):
		uncertain_fade_delay_ticks = value
		_configure()
## How awareness fades for uncertain entries, once uncertain_fade_delay_ticks have passed. Empty: a straight line to nothing over 300
## ticks.
@export var uncertain_fade: FadeProfile:
	set(value):
		uncertain_fade = value
		_configure()
## Claude 2026-11-09: the same delay for certain entries. Longer keeps a pawn searching longer after losing sight of an enemy.
@export_range(0, 36000, 1, "or_greater") var certain_fade_delay_ticks := 0:
	set(value):
		certain_fade_delay_ticks = value
		_configure()
## How awareness fades for certain entries, once certain_fade_delay_ticks have passed. Empty: a straight line to nothing over 1200
## ticks (20 s).
@export var certain_fade: FadeProfile:
	set(value):
		certain_fade = value
		_configure()
## Two sightings with no unseen check between them, at most this many ticks apart, count as one continuous look, so awareness
## doesn't fade between them. Keep it at least as long as the senses' gap between checks.
@export_range(0, 600, 1, "or_greater") var continuous_sighting_ticks := 30:
	set(value):
		continuous_sighting_ticks = value
		_configure()

## Claude 2026-11-09: off, every AIMemory made from now on uses the GDScript store even where the C++ library is available. For tests
## that compare the two, and for checking a suspected C++ problem. Read once, when each memory is made.
static var use_native := true

const _FADE_PROFILE_SCRIPT := preload("res://assets/scripts/ai/FadeProfile.gd")

var pawn: Pawn = null

# AIMemoryStore (C++) or AIMemoryStoreGD: the same functions either way. Untyped, because the C++ class only exists when the library
# loads.
var _store: Object = null
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


func is_certain_at(index: int) -> bool:
	return _store.is_certain_at(index)


func last_known_position_at(index: int) -> Vector3:
	return _store.last_known_position_at(index)


func ticks_since_seen_at(index: int, tick: int) -> int:
	return _store.ticks_since_seen_at(index, tick)


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


## Adds threat to an entity's entry, if it's remembered. Game mechanics call this, such as damage dealt (step 10).
func add_threat(entity: Object, amount: float) -> void:
	_store.add_threat(entity, amount)


## Forgets entries whose fade has ended or whose entity is gone. The sensing manager calls this on each full pass.
func forget_old(tick: int) -> void:
	# Claude 2026-11-09: settings again first, because the C++ store copies a FadeProfile's settings: edits made inside a profile while
	# the game runs reach it here, on the next full pass.
	_configure()
	var forgotten: PackedInt64Array = _store.forget_old(tick)
	for id in forgotten:
		var entity := instance_from_id(id) as Node3D if is_instance_id_valid(id) else null
		if entity:
			entity_forgotten.emit(entity)


## The entry with the highest awareness now, or -1. Ties go to the nearer last known position, then the lower id.
func most_aware_index(tick: int) -> int:
	return _store.most_aware_index(pawn.global_position if pawn else Vector3.ZERO, tick)


## Forgets everything.
func clear() -> void:
	_store.clear()


## Claude 2026-11-09: SightSense calls this after a sight check: wakes a decision for a new entry, and sends entity_became_certain.
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
	_store.configure_fades(uncertain_fade, uncertain_fade_delay_ticks, _is_custom(uncertain_fade),
			certain_fade, certain_fade_delay_ticks, _is_custom(certain_fade), continuous_sighting_ticks)


# A profile whose script isn't FadeProfile itself may override value_at(), so the C++ store calls it rather than doing the maths.
static func _is_custom(profile: FadeProfile) -> bool:
	return profile.get_script() != _FADE_PROFILE_SCRIPT


static func _straight_line(ticks: int) -> FadeProfile:
	var profile := FadeProfile.new()
	profile.mode = FadeProfile.Mode.LINEAR
	profile.fade_ticks = ticks
	return profile
