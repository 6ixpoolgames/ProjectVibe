# Written by Claude (claude-opus-5-5), 2026-11-09. History: ai/CHANGELOG.md.
## Runs a pawn's AI senses on their turn, and finds the other-team pawns they may notice.
##
## A part on the pawn, added by PawnInitializer, with its senses ([AISenseBase] nodes) as children: SightSense by default. Pawn spec
## section 10.4. Each tick the pawn's AI runs ([method AIContextComponent.run_ai]):
## [br]- Every [member sense_interval_ticks]: a full pass. One shared query finds the pawns of other teams within the longest sense's
##   range, and each sense gets that list. Then memory forgets entries whose fade has ended.
## [br]- Every [member refresh_interval_ticks] in between: each sense refreshes the current target, which for sight is one ray.
## [br]
## Both are offset by the pawn's own number, so a crowd doesn't all sense on the same tick. A pawn running every 2nd or 4th tick still
## gets the passes that fell between its runs (pawn spec 8.21).
## [br]
## Teams: only pawns on another team are candidates. When no pawn of another team is in the game at all (the TeamRegistry module
## says so), the query is skipped, so a crowd that's all on one team, like the stress tests, costs almost nothing here.
## [br]
## [b]With the navcore C++ library[/b], the query uses AIPawnGrid: one grid of every pawn, rebuilt at most once a tick and shared by
## every pawn, which returns the nearest [member max_candidates] first. The grid reads the shared PawnTable (Pawn.get_table()), which
## pawns join themselves, so ties come back in entity-id order (scaling spec step 1). The full pass's search, visibility and line of
## sight run on worker threads as the sensing job (AISensingJob, shared by every pawn; line of sight against SightGeometry), scaling
## spec steps 2 and 4. At the end of each tick, every pawn whose full pass is on its next run asks the job, and the job reads the
## shared table and works while the next tick waits to start. On the pass's tick, the sight sense only records the result. The
## answers are the same as on the main thread; only something that moves a pawn between ticks isn't seen by that pass. A pass with
## no result (a pawn that wasn't due, a test calling full_pass) runs on the main thread. TickJobs.enabled off turns the job off.
## [br]
## [b]Without the library[/b], or with AIMemory.use_native off, it's a physics shape query on the layers in [member candidate_mask]
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

## The pawn this is a part of, or null.
var pawn: Pawn = null

# The grid every pawn shares, built from Pawn's shared table, or null without the C++ library. See _shared_grid.
static var _grid: Object = null
# The sensing job every pawn shares, or null without it (see _shared_job); the managers whose full pass is next tick, collected
# during this tick; and the tick driver whose after_tick starts the job.
static var _job: Object = null
static var _due_next: Array[AISensingManager] = []
# Managers of stepping pawns, by the tick at whose end they ask the job (the tick before their next run), since they don't run in
# between to ask then. tick -> Array of managers.
static var _due_later: Dictionary = {}
static var _job_driver: Node = null

var _senses: Array[AISenseBase] = []
var _use_grid := false # decided once, when ready
var _use_job := false # decided once, when ready
var _asked_for_tick := -1 # the tick at whose end this manager last asked the job, so it asks once
var _sight: SightSense = null # the first sight sense, which the job serves
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
			child.perf_full_name = StringName("ai.sense.%s.full" % child.name)
			child.perf_refresh_name = StringName("ai.sense.%s.refresh" % child.name)
			_senses.append(child)
			if _sight == null and child is SightSense:
				_sight = child
	_query.shape = _sphere
	_use_grid = _shared_grid() != null and AIMemory.use_native
	# get_scheduler() is null with TickJobs.enabled off, even once the shared job exists.
	_use_job = _use_grid and _sight != null and TickJobs.get_scheduler() != null and _shared_job() != null


## Every sense, in tree order.
func get_senses() -> Array[AISenseBase]:
	return _senses.duplicate()


## [method AIContextComponent.run_ai] calls this each tick the pawn's AI runs.
func tick_sensing(tick: int) -> void:
	if pawn == null or pawn.ai_context == null or pawn.ai_context.memory == null or _senses.is_empty():
		return
	var offset := pawn.ai_context.pawn_number() if pawn.ai_context else 0
	var interval := TickDriver.ticks_at_rate(sense_interval_ticks) # written for 60 a second
	# fired_since_last_run, so a pawn running every Nth tick still gets the passes that fell between its runs (pawn spec 8.21). Sight's
	# awareness already fills by the real ticks since its last check.
	if pawn.fired_since_last_run(tick, offset, interval):
		full_pass(tick)
	elif pawn.fired_since_last_run(tick, offset, TickDriver.ticks_at_rate(refresh_interval_ticks)):
		for sense in _senses:
			var started := PerfScopes.begin_detailed() # each sense timed on its own, in detail (PerfScopes)
			sense.refresh(tick)
			PerfScopes.end(sense.perf_refresh_name, started)
	# If its next run (Pawn.next_run_tick) will do a full pass, ask the sensing job for it at the end of the tick before that run, so
	# the job's answer, which is always for the next tick, is for that run. That's this tick for a pawn running every tick. If a
	# stepping pawn's step changes first, it runs on another tick, the answer goes unused, and that pass runs on the main thread.
	if not _use_job:
		return
	var next_run := pawn.next_run_tick(tick)
	if not Pawn.fires_in_run(next_run, next_run - tick, offset, interval):
		return # no full pass on its next run
	# A repeat ask for the same tick is dropped (its step can shrink between runs, which would otherwise ask twice).
	if _asked_for_tick == next_run - 1:
		return
	_asked_for_tick = next_run - 1
	if next_run == tick + 1:
		_due_next.append(self)
	else:
		if not _due_later.has(next_run - 1):
			_due_later[next_run - 1] = []
		_due_later[next_run - 1].append(self)
	if _job_driver == null: # the TickDriver autoload, connected once for every manager
		_job_driver = TickDriver
		_job_driver.after_tick.connect(AISensingManager._start_job)


## One full pass now. [method tick_sensing] calls it on schedule; tests may call it directly.
func full_pass(tick: int) -> void:
	# The job's result for this tick, if it has one. The sight sense uses the job's numbers;
	# any other sense gets the same candidates the search below would have found.
	if _use_job and _job.has_result(pawn, tick):
		if _senses.size() > 1:
			_candidates.assign(_job.get_candidates(pawn, tick))
		for sense in _senses:
			var started := PerfScopes.begin_detailed() # each sense timed on its own, in detail (PerfScopes)
			if sense == _sight:
				_sight.full_pass_prepared(_job, tick)
			else:
				sense.full_pass(_candidates, tick)
			PerfScopes.end(sense.perf_full_name, started)
		_forget_old(tick)
		return
	var search_started := PerfScopes.begin_detailed()
	_find_candidates(tick)
	PerfScopes.end(&"ai.sense.search", search_started)
	for sense in _senses:
		var started := PerfScopes.begin_detailed()
		sense.full_pass(_candidates, tick)
		PerfScopes.end(sense.perf_full_name, started)
	_forget_old(tick)


# Memory drops what has faded away, after each full pass; timed as "ai.memory.forget".
func _forget_old(tick: int) -> void:
	var started := PerfScopes.begin_detailed()
	pawn.ai_context.memory.forget_old(tick)
	PerfScopes.end(&"ai.memory.forget", started)


## The longest range among the senses, in metres.
func get_range() -> float:
	var longest := 0.0
	for sense in _senses:
		longest = maxf(longest, sense.get_range())
	return longest


# The shared grid, from Pawn (which the swing hit checks share), or null without the C++ library. Pawns join its table themselves.
static func _shared_grid() -> Object:
	if _grid == null:
		_grid = Pawn.get_grid()
	return _grid


# The shared sensing job, made on first use, or null without the C++ library or with TickJobs.enabled off.
static func _shared_job() -> Object:
	if _job == null and ClassDB.class_exists(&"AISensingJob") and _shared_grid() != null and TickJobs.get_scheduler() != null:
		_job = ClassDB.instantiate(&"AISensingJob")
		_job.setup(TickJobs.get_scheduler(), _grid)
		_job.set_geometry(SightGeometryFeeder.get_geometry()) # line of sight on the workers too
	return _job


# At the end of every tick (TickDriver.after_tick), asks the job for every pawn whose full pass is next tick, then starts it. Called
# every tick, even with nobody due, so last tick's results are dropped.
static func _start_job(_dt: float, tick: int) -> void:
	var due := _due_next
	_due_next = []
	# Plus the stepping pawns that asked ahead for this tick. Older entries (a rollback, a skipped tick) are dropped.
	if not _due_later.is_empty():
		for at: int in _due_later.keys():
			if at == tick:
				due.append_array(_due_later[at])
			if at <= tick:
				_due_later.erase(at)
	for manager in due:
		if is_instance_valid(manager) and manager.is_inside_tree():
			manager._ask_job()
	_job.start(tick)


# This pawn's request, skipped in the same cases _find_candidates finds nothing, so that pass runs on the main thread and gives the
# same answer.
func _ask_job() -> void:
	if pawn == null or pawn.ai_context == null or pawn.ai_context.memory == null or not pawn.is_inside_tree():
		return
	# A pawn that died during this tick, after it asked: a dead pawn's AI doesn't run (Pawn._tick_input), so the pass won't happen.
	if pawn.is_dead():
		return
	if _nobody_to_find():
		return
	var reach := get_range()
	if reach <= 0.0:
		return
	_sight.ask_job(_job, reach, max_candidates)


func _find_candidates(tick: int) -> void:
	_candidates.clear()
	if _nobody_to_find():
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


# True when no pawn anywhere is on another team, from the TeamRegistry module. Without the module, sensing looks every time.
func _nobody_to_find() -> bool:
	var game_mode: Node = get_node_or_null("/root/GameMode")
	var registry: TeamRegistry = game_mode.team_registry if game_mode else null
	return registry != null and registry.count_not_on_team(pawn.team) == 0
