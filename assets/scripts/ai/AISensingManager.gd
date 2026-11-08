## Written by Claude (claude-opus-5-5), 2026-11-09: runs a pawn's AI senses on their turn. A part on the pawn, added by
## PawnInitializer, with its senses (AISenseBase nodes) as children: SightSense by default. Pawn spec section 10.4.
##
## Each tick the pawn's AI runs (Pawn._tick_ai), in this order:
##   - Every sense_interval_ticks: a full pass. One shared query finds the pawns of other teams within the longest sense's range,
##     and each sense gets that list. Then memory forgets entries whose fade has ended.
##   - Every refresh_interval_ticks in between: each sense refreshes the current target, which for sight is one ray.
## Both are offset by the pawn's own number, so a crowd doesn't all sense on the same tick.
##
## Teams: only pawns on another team are candidates. When no pawn of another team is in the tree at all, the query is skipped,
## so a crowd that's all on one team, like the stress tests, costs almost nothing here.
##
## The query is a physics shape query on the layers in candidate_mask (pawns are on layer 2), so it's cheap however many pawns
## exist. It returns at most max_candidates, nearest not guaranteed.
##
## C++ later (pawn spec 10.1): this pass grows with pawns × candidates, so it's the first candidate for porting, and for background
## threads after that.
class_name AISensingManager
extends Node

## Ticks between full passes: 10 is six a second at 60 ticks a second.
@export_range(1, 600, 1, "or_greater") var sense_interval_ticks := 10
## Ticks between cheap refreshes of what's already in memory.
@export_range(1, 600, 1, "or_greater") var refresh_interval_ticks := 5
## Physics layers the shared query looks on. Pawns are on layer 2.
@export_flags_3d_physics var candidate_mask := 2
## The most pawns one query returns.
@export_range(1, 256, 1, "or_greater") var max_candidates := 32

var pawn: Pawn = null

var _senses: Array[AISenseBase] = []
var _candidates: Array[Pawn] = [] # reused every pass
# Reused for every query, so a pass makes no new query objects.
var _query := PhysicsShapeQueryParameters3D.new()
var _sphere := SphereShape3D.new()


func _init() -> void:
	set_process(false)
	set_physics_process(false)


func _enter_tree() -> void:
	pawn = get_parent() as Pawn
	if pawn == null:
		push_warning("AISensingManager: its parent isn't a Pawn, so it senses nothing.")


func _ready() -> void:
	_senses.clear()
	for child in get_children():
		if child is AISenseBase:
			child.manager = self
			child.pawn = pawn
			_senses.append(child)
	_query.shape = _sphere


## Every sense, in tree order.
func get_senses() -> Array[AISenseBase]:
	return _senses.duplicate()


## The pawn calls this each tick its AI runs.
func tick_sensing(tick: int) -> void:
	if pawn == null or pawn.ai_memory == null or _senses.is_empty():
		return
	var offset := pawn.ai_context.pawn_number() if pawn.ai_context else 0
	if posmod(tick + offset, sense_interval_ticks) == 0:
		full_pass(tick)
	elif posmod(tick + offset, refresh_interval_ticks) == 0:
		for sense in _senses:
			sense.refresh(tick)


## One full pass now. The pawn's tick calls it on schedule; tests may call it directly.
func full_pass(tick: int) -> void:
	_find_candidates()
	for sense in _senses:
		sense.full_pass(_candidates, tick)
	pawn.ai_memory.forget_old(tick)


## The longest range among the senses, in metres.
func get_range() -> float:
	var longest := 0.0
	for sense in _senses:
		longest = maxf(longest, sense.get_range())
	return longest


func _find_candidates() -> void:
	_candidates.clear()
	if Pawn.count_pawns_not_on_team(pawn.team) == 0:
		return # nobody on another team anywhere: nothing to find
	var reach := get_range()
	if reach <= 0.0 or not pawn.is_inside_tree():
		return
	_sphere.radius = reach
	_query.transform = Transform3D(Basis.IDENTITY, pawn.global_position)
	_query.collision_mask = candidate_mask
	_query.collide_with_areas = false
	for hit in pawn.get_world_3d().direct_space_state.intersect_shape(_query, max_candidates):
		var other := hit.collider as Pawn
		if other and other != pawn and other.team != pawn.team:
			_candidates.append(other)
