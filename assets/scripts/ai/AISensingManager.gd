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
## Claude 2026-11-09: the query uses AIPawnGrid from the navcore C++ library when it's available: one grid of every pawn, rebuilt at
## most once a tick and shared by every pawn, which returns the nearest max_candidates first. Claude 2026-11-09 (scaling spec step 1):
## the grid reads the shared PawnTable (Pawn.get_table()), which pawns join themselves, so ties come back in entity-id order.
## Claude 2026-11-09 (scaling spec step 2): with the library, the full pass's search and visibility run on worker threads, as the
## sensing job (AISensingJob, shared by every pawn). At the end of each tick, every pawn whose full pass is next tick asks the job,
## and the job reads the shared table and works while the next tick waits to start. On the pass's tick, the sight sense takes the
## result and casts only the rays (Claude 2026-11-09, step 4: now the job tests line of sight too, against SightGeometry, so a pass on
## the main thread only records). The answers are the same as the old way; only something that moves
## a pawn between ticks isn't seen by that pass. A pass with no result (a pawn that wasn't due, a test calling full_pass) runs the
## old way. TickJobs.enabled off turns the job off.
## Without the library, or with AIMemory.use_native off, it's a physics shape query on the layers in candidate_mask
## (pawns are on layer 2), which returns at most max_candidates, nearest not guaranteed. The sight checks themselves run in the
## pawn's memory store (pawn spec 10.11).
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

# Claude 2026-11-09: the grid every pawn shares, built from Pawn's shared table, or null without the C++ library. See _shared_grid.
static var _grid: Object = null
# Claude 2026-11-09 (scaling spec step 2): the sensing job every pawn shares, or null without it (see _shared_job); the managers
# whose full pass is next tick, collected during this tick; and the tick driver whose after_tick starts the job.
static var _job: Object = null
static var _due_next: Array[AISensingManager] = []
static var _job_driver: Node = null

var _senses: Array[AISenseBase] = []
var _use_grid := false # decided once, when ready
var _use_job := false # Claude 2026-11-09 (step 2): decided once, when ready
var _sight: SightSense = null # Claude 2026-11-09 (step 2): the first sight sense, which the job serves
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
	_sight = null
	for child in get_children():
		if child is AISenseBase:
			child.manager = self
			child.pawn = pawn
			_senses.append(child)
			if _sight == null and child is SightSense:
				_sight = child
	_query.shape = _sphere
	_use_grid = _shared_grid() != null and AIMemory.use_native # Claude 2026-11-09: was _grid, made by track_pawn
	# Claude 2026-11-09 (step 2): get_scheduler() is null with TickJobs.enabled off, even once the shared job exists.
	_use_job = _use_grid and _sight != null and TickJobs.get_scheduler() != null and _shared_job() != null


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
	# Claude 2026-11-09 (scaling spec step 2): if next tick is a full pass, ask the sensing job for it at the end of this tick.
	if _use_job and posmod(tick + 1 + offset, sense_interval_ticks) == 0:
		_due_next.append(self)
		if _job_driver == null and pawn._driver:
			_job_driver = pawn._driver
			_job_driver.after_tick.connect(AISensingManager._start_job)


## One full pass now. The pawn's tick calls it on schedule; tests may call it directly.
func full_pass(tick: int) -> void:
	# Claude 2026-11-09 (scaling spec step 2): the job's result for this tick, if it has one. The sight sense uses the job's numbers;
	# any other sense gets the same candidates the search below would have found.
	if _use_job and _job.has_result(pawn, tick):
		if _senses.size() > 1:
			_candidates.assign(_job.get_candidates(pawn, tick))
		for sense in _senses:
			if sense == _sight:
				_sight.full_pass_prepared(_job, tick)
			else:
				sense.full_pass(_candidates, tick)
		pawn.ai_memory.forget_old(tick)
		return
	_find_candidates(tick)
	for sense in _senses:
		sense.full_pass(_candidates, tick)
	pawn.ai_memory.forget_old(tick)


## The longest range among the senses, in metres.
func get_range() -> float:
	var longest := 0.0
	for sense in _senses:
		longest = maxf(longest, sense.get_range())
	return longest


## Claude 2026-11-09 (scaling spec step 1): the shared grid, made on first use from Pawn's shared table, or null without the C++
## library. It replaces track_pawn and untrack_pawn: pawns join the table themselves.
static func _shared_grid() -> Object:
	if _grid == null and ClassDB.class_exists(&"AIPawnGrid") and Pawn.get_table() != null:
		_grid = ClassDB.instantiate(&"AIPawnGrid")
		_grid.set_table(Pawn.get_table())
	return _grid


## Claude 2026-11-09 (scaling spec step 2): the shared sensing job, made on first use, or null without the C++ library or with
## TickJobs.enabled off.
static func _shared_job() -> Object:
	if _job == null and ClassDB.class_exists(&"AISensingJob") and _shared_grid() != null and TickJobs.get_scheduler() != null:
		_job = ClassDB.instantiate(&"AISensingJob")
		_job.setup(TickJobs.get_scheduler(), _grid)
		_job.set_geometry(SightGeometryFeeder.get_geometry()) # Claude 2026-11-09 (step 4): rays on the workers too
	return _job


## Claude 2026-11-09 (scaling spec step 2): at the end of every tick (TickDriver.after_tick), asks the job for every pawn whose full
## pass is next tick, then starts it. Called every tick, even with nobody due, so last tick's results are dropped.
static func _start_job(_dt: float, tick: int) -> void:
	var due := _due_next
	_due_next = []
	for manager in due:
		if is_instance_valid(manager) and manager.is_inside_tree():
			manager._ask_job()
	_job.start(tick)


# Claude 2026-11-09 (step 2): this pawn's request, skipped in the same cases _find_candidates finds nothing, so that pass runs the
# old way and gives the same answer.
func _ask_job() -> void:
	if pawn == null or pawn.ai_memory == null or not pawn.is_inside_tree():
		return
	# A pawn that died during this tick, after it asked: a dead pawn's AI doesn't run (Pawn._tick_input), so the pass won't happen.
	if pawn.is_dead():
		return
	if Pawn.count_pawns_not_on_team(pawn.team) == 0:
		return
	var reach := get_range()
	if reach <= 0.0:
		return
	_sight.ask_job(_job, reach, max_candidates)


func _find_candidates(tick: int) -> void:
	_candidates.clear()
	if Pawn.count_pawns_not_on_team(pawn.team) == 0:
		return # nobody on another team anywhere: nothing to find
	var reach := get_range()
	if reach <= 0.0 or not pawn.is_inside_tree():
		return
	if _use_grid:
		# GDScript note: assign copies the grid's plain Array into the typed one, checking each item is a Pawn.
		_candidates.assign(_grid.query(pawn.global_position, reach, pawn.team, pawn, max_candidates, tick))
		return
	_sphere.radius = reach
	_query.transform = Transform3D(Basis.IDENTITY, pawn.global_position)
	_query.collision_mask = candidate_mask
	_query.collide_with_areas = false
	for hit in pawn.get_world_3d().direct_space_state.intersect_shape(_query, max_candidates):
		var other := hit.collider as Pawn
		if other and other != pawn and other.team != pawn.team:
			_candidates.append(other)
