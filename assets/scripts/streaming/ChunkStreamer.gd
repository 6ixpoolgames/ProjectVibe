## Written by Claude (claude-opus-5-5), 2026-11-06: loads terrain chunks around every active StreamingSource and
## unloads the ones nothing needs any more, without stalling the game.
##
## How to use it:
##   1. On the TerrainGenerator, turn build_on_start off.
##   2. Add this node to the scene and set its terrain.
##   3. Add a StreamingSource to whatever should keep the world loaded.
## To see it working, open streaming_sample.tscn. The tests and stress test are in tests/.
##
## How the ground is always there: the chunks directly under a source are built immediately, right before each tick, and
## ignore the budget. That costs a few milliseconds at most, and only when something has appeared or teleported somewhere new.
## Everything further out comes through the budget below. So a pawn with a source has ground on its very first tick.
##
## How it stays smooth: building a chunk is split into small steps (TerrainGenerator.build_chunk_step), and each frame
## this runs steps until max_ms_per_frame is used up. A slower machine finishes chunks later, but its frames stay short.
##
## In multiplayer, each machine runs its own streamer and loads what it needs: the server around every player, and a client
## around its own pawn. They don't send terrain to each other, because the same settings build the same ground on every
## machine. See StreamingSource and tests/net_streaming_selftest.gd.
##
## How it avoids reloading the same chunk over and over: a chunk loads within a source's load_distance, but only unloads
## past load_distance + unload_margin. So walking back and forth along that line doesn't keep rebuilding it.
##
## What happens in odd cases (all checked in tests/chunk_streaming_selftest.gd):
##   - No terrain set: it warns once and does nothing.
##   - No active sources: everything stays loaded, unless hold_when_no_sources is off. A player respawning or
##     changing pawns shouldn't make the world vanish.
##   - More chunks wanted than the limit: the nearest ones win, and it warns once.
##   - A slow chunk: at least one step runs every frame, however small the budget.
##   - No TickDriver: the ground check still runs once per physics frame.
##
## Not handled yet:
##   - It serves one terrain. Props or other things that load by chunk would need it to serve more.
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
## How far past load_distance a chunk stays loaded, in metres, so that hovering around the edge doesn't rebuild it.
@export_range(0.0, 1000.0, 1.0, "or_greater") var unload_margin := 64.0
## The most chunks that may be loaded per active source. A safety limit against running out of memory.
# Claude 2026-11-07: per source instead of one total, because a server needs chunks around every player. At the defaults,
# a source wants about 37 chunks, so a total of 256 would have run out at about 7 players spread far apart.
@export_range(1, 4096, 1, "or_greater") var max_chunks_per_source := 256
## How often to check where the sources are, in seconds. Shorter reacts faster and costs more.
@export_range(0.0, 2.0, 0.01, "or_greater") var refresh_seconds := 0.2
## With no active sources, keeps every chunk loaded. Off: they all unload.
@export var hold_when_no_sources := true

## The nearest a chunk edge can be to a source before the next chunk is built straight away, in metres.
const MIN_GROUND_REACH := 2.0
## More than this between two checks, in metres, counts as a jump instead of movement. That's 480 m/s at 60 ticks a second.
const MAX_PREDICTED_MOVE := 8.0

# GDScript note: Array[Vector2i] is a list that can only hold chunk positions.
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
var _driver: Node = null


func _init() -> void:
	# Claude 2026-11-07: before TickDriver's -100, so ground exists before anything ticks in a physics frame.
	process_physics_priority = -200


func _ready() -> void:
	if terrain == null:
		# GDScript note: "as" gives null when the parent isn't a terrain, rather than an error.
		terrain = get_parent() as TerrainGenerator
	# Claude 2026-11-07: a snapshot can teleport a pawn during before_tick. This connects after NetworkSession, so it runs
	# after that and before the tick's movement.
	_driver = get_node_or_null("/root/TickDriver")
	if _driver:
		_driver.before_tick.connect(_on_before_tick)
		_driver.rollback_state_loaded.connect(_on_rollback_state_loaded)


## How things stand right now, as numbers for tests, stress runs and on-screen displays.
func get_stats() -> Dictionary:
	return {
		"queued": _build_queue.size() + (1 if _has_current_build else 0),
		"unload_queued": _unload_queue.size(),
		"last_frame_ms": _last_frame_usec / 1000.0,
		"worst_frame_ms": _worst_frame_usec / 1000.0,
		"worst_step_ms": _worst_step_usec / 1000.0,
		"total_loaded": _total_loaded,
		"total_unloaded": _total_unloaded,
		"urgent_builds": _urgent_builds,
	}


## Checks the sources now, instead of waiting for the next refresh.
func refresh_now() -> void:
	_refresh_timer = 0.0
	_refresh()


func _physics_process(_delta: float) -> void:
	_build_ground_under_sources()


func _on_before_tick(_dt: float, _tick: int) -> void:
	_build_ground_under_sources()


## A correction may have just moved a pawn somewhere new, and the replay's ticks are about to move it from there.
func _on_rollback_state_loaded(_from_tick: int) -> void:
	_build_ground_under_sources()


# --- The ground guarantee ---


## Builds, right now, any missing chunk a source is over or could step into before the next check.
# Claude 2026-11-07: replaces the old rule that a pawn over a missing chunk held still. The owner's rule is that the ground
# gets generated first, instead of working around its absence. When nothing is missing, this only costs a few lookups.
func _build_ground_under_sources() -> void:
	if not is_instance_valid(terrain) or not terrain.is_inside_tree() or not terrain.is_node_ready():
		return
	for node in get_tree().get_nodes_in_group(StreamingSource.GROUP):
		var source := node as StreamingSource
		if source == null or not source.counts_on_this_machine():
			continue
		# Near a chunk's edge, the next chunk has to be there too. How near depends on how fast the source is moving. A move
		# past MAX_PREDICTED_MOVE is a jump, such as a teleport: it says nothing about where the next step goes.
		var moved := source.distance_moved_since_last_check()
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
	chunk_loaded.emit(key)


func _process(delta: float) -> void:
	# GDScript note: is_instance_valid is false for a freed object, which a plain null check wouldn't catch.
	if not is_instance_valid(terrain) or not terrain.is_inside_tree():
		if not _warned_no_terrain:
			_warned_no_terrain = true
			push_warning("ChunkStreamer: no terrain to stream, so this does nothing. Set its terrain.")
		return

	var frame_started := Time.get_ticks_usec()
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
	# GDScript note: sort_custom sorts with a function you give it, which says whether a goes before b. "func(a, b):"
	# makes a small function right here. It can read _scores because it belongs to this object.
	_build_queue.sort_custom(func(a: Vector2i, b: Vector2i) -> bool: return _scores[a] < _scores[b])

	_unload_queue.clear()
	for key in terrain.get_loaded_chunks():
		if not _scores.has(key):
			_unload_queue.append(key)
	# The chunk being built may no longer be wanted, such as after a fast source turns back.
	if _has_current_build and not _scores.has(_current_build):
		terrain.unload_chunk(_current_build)
		_has_current_build = false


func _active_sources() -> Array[StreamingSource]:
	var sources: Array[StreamingSource] = []
	for node in get_tree().get_nodes_in_group(StreamingSource.GROUP):
		var source := node as StreamingSource
		# Claude 2026-11-07: asks the source, so a client skips other players' pawns.
		if source != null and source.counts_on_this_machine():
			sources.append(source)
	return sources


## Gives every chunk near a source a score: its distance from the source minus that source's load_distance. Negative
## is inside load_distance, and lower is more urgent. A chunk near several sources keeps its lowest score.
func _score_chunks(sources: Array[StreamingSource]) -> Dictionary:
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
				var score := _distance_to_chunk(x, z, chunk_x, chunk_z, size) - source.load_distance
				if score <= unload_margin:
					var key := Vector2i(chunk_x, chunk_z)
					if not scores.has(key) or score < scores[key]:
						scores[key] = score
	return scores


## How far a point is from the nearest edge of a chunk, as seen from above. It's 0 when the point is over the chunk.
func _distance_to_chunk(x: float, z: float, chunk_x: int, chunk_z: int, size: float) -> float:
	var start_x := chunk_x * size
	var start_z := chunk_z * size
	var away_x := maxf(maxf(start_x - x, 0.0), x - (start_x + size))
	var away_z := maxf(maxf(start_z - z, 0.0), z - (start_z + size))
	return sqrt(away_x * away_x + away_z * away_z)


## Keeps only the most urgent chunks if there are more than the limit.
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
		# GDScript note: pop_front removes the first item and gives it back.
		_current_build = _build_queue.pop_front()
		# Claude 2026-11-07: the ground check may have built it already, since this list was made.
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
