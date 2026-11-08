## Written by Claude (claude-opus-5-5), 2026-11-09: what a pawn's AI has sensed, and how aware of each thing it is. A part on the pawn,
## added by PawnInitializer. Pawn spec section 10.5.
##
## One entry per sensed entity, holding:
##   - where it was last seen (its last known position) and the tick it was last seen
##   - awareness_when_seen: awareness at that sighting, from 0 to 1
##   - certain: set the first time awareness reaches 1, cleared when the entry is forgotten
##   - threat: a number game mechanics add to (damage dealt, say). 0 in t0; target selection reads it
##   - the tick it was last checked by a sense, seen or not, so the next sighting's gain counts the right number of ticks
## The entries are kept as packed arrays, one per field, rather than an object per entry, so a crowd of AI pawns makes no objects
## and a port to C++ would be mechanical (pawn spec 10.1).
##
## How awareness moves:
##   - A sense adds gain each time it sees the entity (record_sighting), up to 1.
##   - Seeing an entity that's already certain refills it to 1 at once.
##   - Claude 2026-11-09: sightings close together (continuous_sighting_ticks) with no unseen check between them count as one look,
##     so awareness doesn't fade between them; it only fades while the entity isn't seen.
##   - While it isn't seen, it stays full for a delay, then fades by a FadeProfile:
##     awareness now = awareness_when_seen × uncertain_fade.value_at(ticks since seen − uncertain_fade_delay_ticks).
##     uncertain_fade and uncertain_fade_delay_ticks are for uncertain entries; certain_fade and certain_fade_delay_ticks for certain ones. With the
##     default straight lines, an entry is forgotten delay + fade ticks after it was last seen, whatever its awareness was.
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
##   entity_became_certain(entity), entity_forgotten(entity)
class_name AIMemory
extends Node

## Sent when an entry first reaches full awareness.
signal entity_became_certain(entity: Node3D)
## Sent when an entry is forgotten.
signal entity_forgotten(entity: Node3D)

## Claude 2026-11-09: ticks an entry that isn't certain stays at full awareness after it was last seen, before its fade starts. So a
## glimpse that just reached Alert keeps the pawn Alert long enough to look and walk over. 300 is 5 s.
@export_range(0, 36000, 1, "or_greater") var uncertain_fade_delay_ticks := 300
## How awareness fades for uncertain entries, once uncertain_fade_delay_ticks have passed. Empty: a straight line to nothing over 300 ticks.
@export var uncertain_fade: FadeProfile
## Claude 2026-11-09: the same delay for certain entries. Longer keeps a pawn searching longer after losing sight of an enemy.
@export_range(0, 36000, 1, "or_greater") var certain_fade_delay_ticks := 0
## How awareness fades for certain entries, once certain_fade_delay_ticks have passed. Empty: a straight line to nothing over 1200
## ticks (20 s).
@export var certain_fade: FadeProfile
## Two sightings with no unseen check between them, at most this many ticks apart, count as one continuous look, so awareness
## doesn't fade between them. Keep it at least as long as the senses' gap between checks.
@export_range(0, 600, 1, "or_greater") var continuous_sighting_ticks := 30

var pawn: Pawn = null

# One value per entry, all in the same order.
var _ids := PackedInt64Array() # the entity's instance id
var _last_known := PackedVector3Array()
var _last_seen := PackedInt64Array()
var _last_checked := PackedInt64Array()
var _awareness_when_seen := PackedFloat32Array()
var _certain := PackedByteArray()
var _threat := PackedFloat32Array()
# Instance id -> index, so find() doesn't search every entry. At 32 entries ai_stress barely saw a difference, but it keeps find()
# cheap however many entries a game has.
var _index_of := {}


func _init() -> void:
	set_process(false)
	set_physics_process(false)


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


## How many entries there are.
func entry_count() -> int:
	return _ids.size()


## The entry for this entity, or -1.
func find(entity: Object) -> int:
	if entity == null:
		return -1
	return _index_of.get(entity.get_instance_id(), -1)


## The entity of an entry, or null if it's been freed.
func entity_at(index: int) -> Node3D:
	var id := _ids[index]
	# GDScript note: instance_from_id gives back the object for an id, but only if it still exists, which is_instance_id_valid checks.
	return instance_from_id(id) as Node3D if is_instance_id_valid(id) else null


## Awareness of an entry at this tick, faded since it was last seen.
func awareness_at(index: int, tick: int) -> float:
	# GDScript note: value_at of a negative tick count is full, so the delay needs no special case.
	if _certain[index]:
		return _awareness_when_seen[index] * certain_fade.value_at(tick - _last_seen[index] - certain_fade_delay_ticks)
	return _awareness_when_seen[index] * uncertain_fade.value_at(tick - _last_seen[index] - uncertain_fade_delay_ticks)


func is_certain_at(index: int) -> bool:
	return _certain[index] != 0


func last_known_position_at(index: int) -> Vector3:
	return _last_known[index]


func ticks_since_seen_at(index: int, tick: int) -> int:
	return tick - _last_seen[index]


func threat_at(index: int) -> float:
	return _threat[index]


## Ticks since a sense last checked this entity, or fallback if it isn't remembered.
func ticks_since_checked(entity: Object, tick: int, fallback: int) -> int:
	var i := find(entity)
	return fallback if i < 0 else tick - _last_checked[i]


## A sense saw this entity at this tick. gain is added to its awareness; a certain entry refills to 1.
func record_sighting(entity: Node3D, gain: float, tick: int, position: Vector3) -> void:
	var i := find(entity)
	if i < 0:
		_ids.append(entity.get_instance_id())
		_last_known.append(position)
		_last_seen.append(tick)
		_last_checked.append(tick)
		_awareness_when_seen.append(0.0)
		_certain.append(0)
		_threat.append(0.0)
		i = _ids.size() - 1
		_index_of[_ids[i]] = i
		_wake_decision()
	# Fading only counts while it isn't seen: if the last check saw it too, not long ago, it was in view all along, so nothing faded
	# in between.
	var in_view_all_along := _last_checked[i] == _last_seen[i] and tick - _last_seen[i] <= continuous_sighting_ticks
	var before := _awareness_when_seen[i] if in_view_all_along else awareness_at(i, tick)
	var now := 1.0 if _certain[i] else minf(1.0, before + gain)
	_last_known[i] = position
	_last_seen[i] = tick
	_last_checked[i] = tick
	_awareness_when_seen[i] = now
	if now >= 1.0 and not _certain[i]:
		_certain[i] = 1
		entity_became_certain.emit(entity)
		_wake_decision()


## A sense checked this entity at this tick and didn't see it.
func record_check(entity: Object, tick: int) -> void:
	var i := find(entity)
	if i >= 0:
		_last_checked[i] = tick


## Adds threat to an entity's entry, if it's remembered. Game mechanics call this, such as damage dealt (step 10).
func add_threat(entity: Object, amount: float) -> void:
	var i := find(entity)
	if i >= 0:
		_threat[i] = maxf(0.0, _threat[i] + amount)


## Forgets entries whose fade has ended or whose entity is gone. The sensing manager calls this on each full pass.
func forget_old(tick: int) -> void:
	var i := _ids.size() - 1
	while i >= 0: # backwards, so removing one doesn't move the ones still to check
		var lasts := certain_fade_delay_ticks + certain_fade.ends_after() if _certain[i] else uncertain_fade_delay_ticks + uncertain_fade.ends_after()
		var entity := entity_at(i)
		if entity == null or tick - _last_seen[i] >= lasts:
			_remove(i)
			if entity:
				entity_forgotten.emit(entity)
		i -= 1


## The entry with the highest awareness now, or -1. Ties go to the nearer last known position, then the lower id.
func most_aware_index(tick: int) -> int:
	var best := -1
	var best_awareness := -1.0
	var best_distance := INF
	var from := pawn.global_position if pawn else Vector3.ZERO
	for i in _ids.size():
		var awareness := awareness_at(i, tick)
		var distance := from.distance_squared_to(_last_known[i])
		if awareness > best_awareness + 0.000001 \
				or (absf(awareness - best_awareness) <= 0.000001 and (distance < best_distance or (distance == best_distance and _ids[i] < _ids[best]))):
			best = i
			best_awareness = awareness
			best_distance = distance
	return best


## Forgets everything.
func clear() -> void:
	for i in range(_ids.size() - 1, -1, -1):
		_remove(i)


# --- Internals ---


func _remove(i: int) -> void:
	_index_of.erase(_ids[i])
	# Every entry after this one moves down a place.
	for later in range(i + 1, _ids.size()):
		_index_of[_ids[later]] = later - 1
	_ids.remove_at(i)
	_last_known.remove_at(i)
	_last_seen.remove_at(i)
	_last_checked.remove_at(i)
	_awareness_when_seen.remove_at(i)
	_certain.remove_at(i)
	_threat.remove_at(i)


func _wake_decision() -> void:
	if pawn and pawn.ai_context:
		pawn.ai_context.request_decision()


static func _straight_line(ticks: int) -> FadeProfile:
	var profile := FadeProfile.new()
	profile.mode = FadeProfile.Mode.LINEAR
	profile.fade_ticks = ticks
	return profile
