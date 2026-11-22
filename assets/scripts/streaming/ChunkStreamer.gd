# Written by Claude (claude-opus-5-5), 2026-11-06. History: streaming/CHANGELOG.md.
## Loads terrain chunks around every streaming source, and unloads the ones nothing needs any more, without stalling the game.
##
## Add it to the scene and set its [member terrain] (a [WorldCoordinator] does this, and turns off the terrain's [code]build_on_start[/code]),
## then add a [StreamingSource] to whatever should keep the world loaded; a pawn that does is a source itself. Building a chunk is
## split into steps ([method TerrainGenerator.build_chunk_step]) and each frame runs steps until [member max_ms_per_frame] is used up,
## so a slower machine finishes chunks later but its frames stay short. The chunks directly under a source are built at once, right
## before each tick, outside the budget, so a pawn has ground on its first tick. A chunk loads within a source's load_distance and only
## unloads past load_distance + [member unload_margin]. Each machine runs its own streamer; terrain isn't sent, since the same
## settings build the same ground. Design: streaming spec (docs/streaming/STREAMING_SPEC.md).
## [br]With the tick driver running, chunks land on ticks (state store spec 13.12): what's wanted is decided on ticks, each new chunk
## gets a landing tick ([member landing_delay_ticks] on, no more than [member max_landings_per_tick] a tick), building stops just
## before publishing (its points, collision and nav), and it's published before its landing tick runs, finishing it first if it
## isn't done. So the same start lands the same ground on the same ticks on any machine; each landing goes in the [LandingLog].
class_name ChunkStreamer
extends Node

## Sent when a chunk is completely built, including its collision.
signal chunk_loaded(key: Vector2i)
## Sent when a chunk has been removed.
signal chunk_unloaded(key: Vector2i)

## The terrain to load chunks for. If it's empty and this node's parent is a terrain, it uses the parent.
@export var terrain: TerrainGenerator
## How long this may spend per frame, in milliseconds. At least one step always runs, so one step can go over.
@export_range(0.0, 16.0, 0.1, "or_greater") var max_ms_per_frame := 2.0
## How far past a source's load_distance a chunk stays loaded, in metres, so that hovering around the edge doesn't rebuild it.
@export_range(0.0, 1000.0, 1.0, "or_greater") var unload_margin := 64.0
## The most chunks loaded per active source, a safety limit against running out of memory. Per source because a server needs chunks
## around every player. At the defaults a source wants about 37 chunks.
@export_range(1, 4096, 1, "or_greater") var max_chunks_per_source := 256
## How often to check where the sources are, in seconds. Shorter reacts faster and costs more.
@export_range(0.0, 2.0, 0.01, "or_greater") var refresh_seconds := 0.2
## With no active sources, keeps every chunk loaded. Off: they all unload.
@export var hold_when_no_sources := true
## With the tick driver: ticks from when a chunk is wanted to when it lands, written for 60 ticks a second. Long enough for a
## machine to build it in the background; a machine that hasn't by then finishes it on that tick (a hitch).
@export_range(0, 600, 1, "or_greater") var landing_delay_ticks := 30
## With the tick driver: the most chunks landing on one tick, so a burst of new chunks is spread over ticks.
@export_range(1, 64, 1, "or_greater") var max_landings_per_tick := 2

## The nearest a chunk edge can be to a source before the next chunk is built straight away, in metres.
const MIN_GROUND_REACH := 2.0
## More than this between two checks, in metres, counts as a jump instead of movement. That's 480 m/s at 60 ticks a second.
const MAX_PREDICTED_MOVE := 8.0

var _build_queue: Array[Vector2i] = [] # chunks to build, most urgent first
var _unload_queue: Array[Vector2i] = []
var _current_build := Vector2i.ZERO # the chunk being built, which is finished before starting another
var _has_current_build := false
var _scores := {} # Vector2i -> how far outside a source's load_distance the chunk is, negative when inside
var _refresh_timer := 0.0
var _warned_no_terrain := false
var _warned_too_many := false

# Numbers for get_stats.
var _last_frame_usec := 0
var _worst_frame_usec := 0
var _worst_step_usec := 0
var _total_loaded := 0
var _total_unloaded := 0
var _urgent_builds := 0
var _landing_waits := 0 # chunks that weren't built by their landing tick, so the tick finished them
var _driver: Node = null
var _landing_tick := {} # Vector2i -> the tick it lands on (with the tick driver)
var _landings_on := {} # tick -> how many chunks land on it
var _next_refresh_tick := -1


func _init() -> void:
	# Before TickDriver's -100, so ground exists before anything ticks in a physics frame.
	process_physics_priority = -200


func _ready() -> void:
	if terrain == null:
		terrain = get_parent() as TerrainGenerator
	# A snapshot can teleport a pawn during before_tick. This connects after NetworkSession, so it runs after that and before the
	# tick's movement.
	_driver = get_node_or_null("/root/TickDriver")
	if _driver:
		_driver.before_tick.connect(_on_before_tick)
		_driver.rollback_state_loaded.connect(_on_rollback_state_loaded)
	# With the tick driver running, the check before each tick is the one that matters; the per-frame one is for when it isn't.


## How things stand right now, as numbers for tests, stress runs and on-screen displays.
func get_stats() -> Dictionary:
	return {
		"queued": _build_queue.size() + (1 if _has_current_build else 0) + _landing_tick.size(), # scheduled ones too, until they land
		"unload_queued": _unload_queue.size(),
		"last_frame_ms": _last_frame_usec / 1000.0,
		"worst_frame_ms": _worst_frame_usec / 1000.0,
		"worst_step_ms": _worst_step_usec / 1000.0,
		"total_loaded": _total_loaded,
		"total_unloaded": _total_unloaded,
		"urgent_builds": _urgent_builds,
		"scheduled": _landing_tick.size(),
		"landing_waits": _landing_waits,
	}


## Checks the sources now, instead of waiting for the next refresh. With the tick driver, before the next tick.
func refresh_now() -> void:
	_refresh_timer = 0.0
	if _on_ticks():
		_next_refresh_tick = -1
	else:
		_refresh()


## The tick a chunk is due to land on, or -1 if none is scheduled.
func get_landing_tick(key: Vector2i) -> int:
	return _landing_tick.get(key, -1)


func _physics_process(_delta: float) -> void:
	if not _on_ticks():
		_timed_ground_check()


func _on_before_tick(_dt: float, tick: int) -> void:
	_timed_ground_check()
	var started := PerfScopes.begin()
	_land_on_tick(tick)
	PerfScopes.end(&"streaming.landings", started)


# True while chunks land on ticks: the tick driver is running.
func _on_ticks() -> bool:
	return _driver != null and _driver.active


# Timed for diagnostics (PerfScopes) in one place, so whichever of the two above runs is the one timed.
func _timed_ground_check() -> void:
	var started := PerfScopes.begin()
	_build_ground_under_sources()
	PerfScopes.end(&"streaming.ground_under_sources", started)


# A correction may have just moved a pawn somewhere new, and the replay's ticks are about to move it from there.
func _on_rollback_state_loaded(_from_tick: int) -> void:
	_build_ground_under_sources()


# --- The ground guarantee ---


# Builds, right now, any missing chunk a source is over or could step into before the next check. The ground is generated first,
# instead of working around its absence. When nothing is missing, this only costs a few lookups.
func _build_ground_under_sources() -> void:
	if not is_instance_valid(terrain) or not terrain.is_inside_tree() or not terrain.is_node_ready():
		return
	for node in get_tree().get_nodes_in_group(StreamingSource.GROUP):
		# Any source, read through the source contract (StreamingSource.gd).
		var source := node as Node3D
		if source == null or not source.counts_on_this_machine():
			continue
		# Near a chunk's edge, the next chunk has to be there too. How near depends on how fast the source is moving. A move
		# past MAX_PREDICTED_MOVE is a jump, such as a teleport: it says nothing about where the next step goes.
		var moved: float = source.distance_moved_since_last_check()
		var reach := maxf(moved * 2.0, MIN_GROUND_REACH) if moved <= MAX_PREDICTED_MOVE else MIN_GROUND_REACH
		var at := source.global_position
		for corner: Vector3 in [Vector3(-reach, 0.0, -reach), Vector3(reach, 0.0, -reach), Vector3(-reach, 0.0, reach), Vector3(reach, 0.0, reach)]:
			var key := terrain.chunk_of(at + corner)
			if not terrain.has_chunk(key):
				_build_now(key)


func _build_now(key: Vector2i) -> void:
	terrain.load_chunk(key)
	if _has_current_build and _current_build == key:
		_has_current_build = false
	_urgent_builds += 1
	_total_loaded += 1
	if _on_ticks():
		# Asked for and landed on the same tick, before it runs.
		_unschedule(key)
		LandingLog.note(LandingLog.CHUNK, LandingLog.chunk_key(key), _driver.tick)
	chunk_loaded.emit(key)


# --- Landing on ticks (with the tick driver) ---


# Before each tick: what's wanted (every refresh_seconds), the chunks due now, then at most one unload.
func _land_on_tick(tick: int) -> void:
	if not _on_ticks() or not is_instance_valid(terrain) or not terrain.is_inside_tree():
		return
	if tick >= _next_refresh_tick:
		_next_refresh_tick = tick + maxi(1, roundi(refresh_seconds * _driver.get_tick_rate()))
		_refresh_on_tick(tick)
	var due: Array[Vector2i] = []
	for key: Vector2i in _landing_tick:
		if _landing_tick[key] <= tick:
			due.append(key)
	due.sort_custom(func(a: Vector2i, b: Vector2i) -> bool: return _landing_order(a, b))
	for key in due:
		if terrain.has_chunk(key):
			_unschedule(key)
			continue
		if not terrain.is_chunk_ready_to_publish(key):
			_landing_waits += 1
		terrain.load_chunk(key) # publishes it, finishing it first if it isn't ready (the wait)
		_unschedule(key)
		_total_loaded += 1
		LandingLog.note(LandingLog.CHUNK, LandingLog.chunk_key(key), tick)
		chunk_loaded.emit(key)
	if not _unload_queue.is_empty():
		_unload_next()


# The refresh on a tick: new chunks get landing ticks, in order of urgency; scheduled ones no longer wanted are dropped; loaded ones
# no longer wanted queue to unload.
func _refresh_on_tick(tick: int) -> void:
	var sources := _active_sources()
	if sources.is_empty() and hold_when_no_sources:
		_unload_queue.clear()
		return
	_scores = _score_chunks(sources)
	_apply_chunk_limit(maxi(sources.size(), 1) * max_chunks_per_source)
	for key: Vector2i in _landing_tick.keys():
		if not _scores.has(key):
			_unschedule(key)
			terrain.unload_chunk(key) # what was built of it
	var fresh: Array[Vector2i] = []
	for key: Vector2i in _scores:
		if _scores[key] <= 0.0 and not terrain.has_chunk(key) and not _landing_tick.has(key):
			fresh.append(key)
	fresh.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		return _scores[a] < _scores[b] if _scores[a] != _scores[b] else (a.x < b.x if a.x != b.x else a.y < b.y))
	var earliest: int = tick + _driver.ticks_at_rate(landing_delay_ticks)
	for key in fresh:
		var landing := earliest
		while _landings_on.get(landing, 0) >= max_landings_per_tick:
			landing += 1
		_landings_on[landing] = _landings_on.get(landing, 0) + 1
		_landing_tick[key] = landing
	_unload_queue.clear()
	for key in terrain.get_loaded_chunks():
		if not _scores.has(key):
			_unload_queue.append(key)
	_unload_queue.sort_custom(func(a: Vector2i, b: Vector2i) -> bool: return a.x > b.x if a.x != b.x else a.y > b.y) # popped from the back


func _unschedule(key: Vector2i) -> void:
	if not _landing_tick.has(key):
		return
	var landing: int = _landing_tick[key]
	_landing_tick.erase(key)
	_landings_on[landing] = _landings_on.get(landing, 1) - 1
	if _landings_on[landing] <= 0:
		_landings_on.erase(landing)


# One step of a scheduled chunk, up to publishing; true once it's ready to land.
func _build_scheduled_step(key: Vector2i) -> bool:
	return terrain.build_chunk_step(key, true)


# Landing order: by landing tick, then by chunk.
func _landing_order(a: Vector2i, b: Vector2i) -> bool:
	if _landing_tick[a] != _landing_tick[b]:
		return _landing_tick[a] < _landing_tick[b]
	return a.x < b.x if a.x != b.x else a.y < b.y


# In frames, with the tick driver: build the scheduled chunks up to publishing, soonest landing first, under the budget.
func _build_scheduled(frame_started: int) -> void:
	var waiting: Array[Vector2i] = []
	for key: Vector2i in _landing_tick:
		if not terrain.is_chunk_ready_to_publish(key) and not terrain.has_chunk(key):
			waiting.append(key)
	if waiting.is_empty():
		return
	waiting.sort_custom(func(a: Vector2i, b: Vector2i) -> bool: return _landing_order(a, b))
	var budget_usec := int(max_ms_per_frame * 1000.0)
	var did_a_step := false
	for key in waiting:
		while not did_a_step or Time.get_ticks_usec() - frame_started < budget_usec:
			var step_started := Time.get_ticks_usec()
			var ready := _build_scheduled_step(key)
			_finish_step(step_started)
			did_a_step = true
			if ready:
				break
		if did_a_step and Time.get_ticks_usec() - frame_started >= budget_usec:
			return


func _process(delta: float) -> void:
	var started := PerfScopes.begin() # timed for diagnostics (PerfScopes)
	_stream_chunks(delta)
	PerfScopes.end(&"streaming.chunks", started)


# The work itself, timed by _process.
func _stream_chunks(delta: float) -> void:
	if not is_instance_valid(terrain) or not terrain.is_inside_tree():
		if not _warned_no_terrain:
			_warned_no_terrain = true
			push_warning("ChunkStreamer: no terrain to stream, so this does nothing. Set its terrain.")
		return

	var frame_started := Time.get_ticks_usec()
	if _on_ticks():
		# What's wanted, landings and unloads happen on ticks (_land_on_tick); frames only build.
		_build_scheduled(frame_started)
		_last_frame_usec = Time.get_ticks_usec() - frame_started
		_worst_frame_usec = maxi(_worst_frame_usec, _last_frame_usec)
		return
	_refresh_timer -= delta
	if _refresh_timer <= 0.0:
		_refresh_timer = refresh_seconds
		_refresh()

	# One unload per frame at most, then build. Standing ground matters more than freeing memory, so unloading never
	# holds up a build for long.
	if not _unload_queue.is_empty():
		var step_started := Time.get_ticks_usec()
		_unload_next()
		_finish_step(step_started)

	var budget_usec := int(max_ms_per_frame * 1000.0)
	# Always at least one step. Otherwise a budget that's too small would mean nothing ever loads.
	var did_a_step := false
	while _has_build_work() and (not did_a_step or Time.get_ticks_usec() - frame_started < budget_usec):
		var step_started := Time.get_ticks_usec()
		_build_next_step()
		_finish_step(step_started)
		did_a_step = true

	_last_frame_usec = Time.get_ticks_usec() - frame_started
	_worst_frame_usec = maxi(_worst_frame_usec, _last_frame_usec)


# --- Working out what should be loaded ---


func _refresh() -> void:
	var sources := _active_sources()
	if sources.is_empty() and hold_when_no_sources:
		_build_queue.clear()
		_unload_queue.clear()
		return

	_scores = _score_chunks(sources)
	_apply_chunk_limit(maxi(sources.size(), 1) * max_chunks_per_source)

	_build_queue.clear()
	for key: Vector2i in _scores:
		# A score above 0 is past load_distance: it may stay if it's loaded, but it isn't worth loading.
		if _scores[key] <= 0.0 and not terrain.has_chunk(key) and not (_has_current_build and key == _current_build):
			_build_queue.append(key)
	# Sorts by score, nearest first. The function can read _scores because it belongs to this object.
	_build_queue.sort_custom(func(a: Vector2i, b: Vector2i) -> bool: return _scores[a] < _scores[b])

	_unload_queue.clear()
	for key in terrain.get_loaded_chunks():
		if not _scores.has(key):
			_unload_queue.append(key)
	# The chunk being built may no longer be wanted, such as after a fast source turns back.
	if _has_current_build and not _scores.has(_current_build):
		terrain.unload_chunk(_current_build)
		_has_current_build = false


# Node3D, not StreamingSource: pawns are sources too (the source contract, StreamingSource.gd).
func _active_sources() -> Array[Node3D]:
	var sources: Array[Node3D] = []
	for node in get_tree().get_nodes_in_group(StreamingSource.GROUP):
		var source := node as Node3D
		# Asks the source, so a client skips other players' pawns.
		if source != null and source.counts_on_this_machine():
			sources.append(source)
	return sources


# Gives every chunk near a source a score: its distance from the source minus that source's load_distance. Negative
# is inside load_distance, and lower is more urgent. A chunk near several sources keeps its lowest score.
func _score_chunks(sources: Array[Node3D]) -> Dictionary:
	var scores := {}
	var origin := terrain.global_position
	var size := terrain.chunk_size
	# However large a source asks for, don't visit more squares than this. It's what stops a huge load_distance with a
	# tiny chunk_size from freezing the game before the limit below can apply.
	var longest_reach := size * ceilf(sqrt(float(max_chunks_per_source)))
	for source in sources:
		var reach := minf(source.load_distance + unload_margin, longest_reach)
		var x := source.global_position.x - origin.x
		var z := source.global_position.z - origin.z
		for chunk_z in range(floori((z - reach) / size), floori((z + reach) / size) + 1):
			for chunk_x in range(floori((x - reach) / size), floori((x + reach) / size) + 1):
				var score: float = _distance_to_chunk(x, z, chunk_x, chunk_z, size) - source.load_distance
				if score <= unload_margin:
					var key := Vector2i(chunk_x, chunk_z)
					if not scores.has(key) or score < scores[key]:
						scores[key] = score
	return scores


# How far a point is from the nearest edge of a chunk, as seen from above. It's 0 when the point is over the chunk.
func _distance_to_chunk(x: float, z: float, chunk_x: int, chunk_z: int, size: float) -> float:
	var start_x := chunk_x * size
	var start_z := chunk_z * size
	var away_x := maxf(maxf(start_x - x, 0.0), x - (start_x + size))
	var away_z := maxf(maxf(start_z - z, 0.0), z - (start_z + size))
	return sqrt(away_x * away_x + away_z * away_z)


# Keeps only the most urgent chunks if there are more than the limit.
func _apply_chunk_limit(limit: int) -> void:
	if _scores.size() <= limit:
		return
	var keys: Array = _scores.keys()
	keys.sort_custom(func(a: Vector2i, b: Vector2i) -> bool: return _scores[a] < _scores[b])
	# Only warn if chunks inside load_distance are being cut, not just ones in the unload margin.
	if _scores[keys[limit]] <= 0.0 and not _warned_too_many:
		_warned_too_many = true
		push_warning("ChunkStreamer: sources want more than the limit (%d). Keeping the nearest. Raise max_chunks_per_source, or lower load_distance. Shown once." % limit)
	for i in range(limit, keys.size()):
		_scores.erase(keys[i])


# --- Doing the work ---


func _has_build_work() -> bool:
	return _has_current_build or not _build_queue.is_empty()


func _build_next_step() -> void:
	if not _has_current_build:
		_current_build = _build_queue.pop_front()
		# The ground check may have built it already, since this list was made.
		if terrain.has_chunk(_current_build):
			return
		_has_current_build = true
	if terrain.build_chunk_step(_current_build):
		_has_current_build = false
		_total_loaded += 1
		chunk_loaded.emit(_current_build)


func _unload_next() -> void:
	var key: Vector2i = _unload_queue.pop_back()
	terrain.unload_chunk(key)
	_total_unloaded += 1
	chunk_unloaded.emit(key)


func _finish_step(step_started: int) -> void:
	_worst_step_usec = maxi(_worst_step_usec, Time.get_ticks_usec() - step_started)
