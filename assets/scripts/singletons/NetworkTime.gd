## Written by Claude (claude-opus-5-5), 2026-11-04: the tick driver (netcode spec section 3), offline version.
## Autoload "NetworkTime". Every machine runs it, online and offline. All gameplay simulation runs inside its
## numbered, fixed-length ticks, in a fixed phase order, instead of in each node's own _process/_physics_process.
## Nothing is networked yet; this is the foundation the abilities and, later, the netcode are built on.
##
## How an entity takes part:
##   NetworkTime.register(self)    # usually done by the nexus at spawn
##   NetworkTime.unregister(self)  # or just get freed; freed participants are dropped automatically
## and implements any of these (all optional; a participant only gets the calls it has):
##   func _tick_input(dt: float, tick: int) -> void      # phase 1: controllers write this tick's input command
##   func _tick_capture_input(tick: int) -> void         # phase 2: save the input for replay (usually TickStateComponent)
##   func _tick_simulate(dt: float, tick: int) -> void   # phase 3: abilities, movement, move_and_slide
##   func _tick_record(tick: int) -> void                # phase 4: predicted parts save their state
## dt is ALWAYS the fixed tick length, never the frame's delta.
## Gotcha: if a participant also defines _physics_process (e.g. as a fallback when there's no driver), turn it off
## with set_physics_process(false) in _ready, not _enter_tree. Godot switches it on at ready, and the object
## would then tick twice. Example: assets/scripts/samples/TickSamplePawn.gd. # Claude 2026-11-04: found while building the sample
##
## One tick runs:
##   before_tick signal -> every _tick_input -> every _tick_capture_input -> every _tick_simulate -> every _tick_record -> after_tick signal
## A frame runs as many ticks as the elapsed time covers (usually exactly one), wrapped in before_tick_loop / after_tick_loop.
##
## Rules and corner cases (all checked in tests/tick_driver_selftest.gd):
##   - Order within a phase: lower `order` first (register's second argument, default 0); equal order keeps
##     registration order. Online, the nexus will pass the entity id so every machine runs the same order.
##   - Registering twice changes nothing (the first registration stands). Unregistering an unknown object is a no-op.
##   - Registering DURING a tick takes effect from the next tick. Unregistering during a tick stops its calls
##     immediately (a pawn despawned mid-tick isn't simulated or recorded afterwards).
##   - A freed participant is skipped and dropped, never called.
##   - Spiral of death: at most max_ticks_per_frame ticks per frame. Time beyond that is dropped (the game
##     slows down instead of freezing) and counted in dropped_ticks.
##   - tick_factor scales how fast ticks happen (time dilation, later). Always 1.0 offline and on the server.
##   - A frame running more than one tick (dilation, catching up, or a tick_rate above the physics rate) calls each
##     participant's optional _sync_collision() between its ticks, so bodies collide with each other's latest positions,
##     as they would with one tick per frame. Frames with one tick pay nothing. step() is for tests, and doesn't do this.
##     Only entities with a TickStateComponent get this; a body moved by anything else stays out of date until the step.
##   - active = false pauses ticking; nothing builds up while paused.
##   - Runs in _physics_process, so physics queries are safe during ticks. Default tick_rate = the project's
##     physics rate, so offline it's exactly one tick per physics frame.
##   - move_and_slide scales velocity by Godot's physics delta, not by our tick. If tick_rate differs from the
##     physics rate, a motor multiplies velocity by physics_factor before move_and_slide and divides after.
##
## Rollback (Claude 2026-11-04, netcode spec section 3.5). rollback(from_tick) puts predicted participants back to how
## they ended from_tick, then replays every later tick up to the last finished one. A participant is predicted if it has
## _rollback_load(tick) -> bool, _rollback_input(tick), _rollback_simulate(dt, tick) and _tick_record(tick).
## TickStateComponent provides all four, so entities normally just add that node. Rules, also tested:
##   - While replaying: is_resimulating() is true (cosmetic effects must check it), NetworkTime.tick reads as the tick
##     being replayed, and the tick_rng() rolls repeat exactly. Input phases don't run; saved inputs are restored instead.
##   - Everything not predicted stays where it is during the replay, the standard accepted inaccuracy. The exception is
##     an entity whose TickStateComponent is in FOLLOW_SERVER mode: it stands on server data, estimates past it on its velocity,
##     then returns to where it was.
##   - Each replaying participant's optional _rollback_finished() runs once the replay is over, before after_rollback.
##   - When two or more participants replay, each one's optional _sync_collision() runs after loading and after each
##     replayed tick, so physics bodies collide with each other's replayed positions rather than their final ones.
##   - Allowed between ticks or from before_tick (where the netcode will apply snapshots). During the phases, or
##     during another replay, it warns and returns false.
##   - With physics bodies, call it during the physics frame (before_tick is). Outside it, move_and_slide uses the
##     rendered frame's delta instead, so replayed movement would be the wrong length.
##   - A participant that no longer has from_tick keeps its current state and sits the replay out.
##   - Returns false if nothing could be loaded or from_tick is in the future. No side effects then.
extends Node
class_name NetworkTimeSingleton

signal before_tick_loop
signal before_tick(dt: float, tick: int)
signal after_tick(dt: float, tick: int)
signal after_tick_loop
signal after_rollback(from_tick: int, to_tick: int) # Claude 2026-11-04: rollback added

const TICK_RATE_SETTING := "project_base/network/tick_rate"

## Ticks per second. 0 (default) = use the project's physics rate.
@export var tick_rate: int = 0:
	set(value):
		tick_rate = value
		_refresh_rate()
## Most ticks one frame may run (stops a slow frame from causing ever more ticks).
@export var max_ticks_per_frame: int = 6
## False pauses ticking.
@export var active: bool = true

## Current tick number: the last tick that ran. Starts at 0 before any tick.
var tick: int = 0
## Time dilation multiplier. 1.0 offline; adjusted on clients once netcode exists.
var tick_factor: float = 1.0
## Ticks skipped by the max_ticks_per_frame limit, for diagnostics.
var dropped_ticks: int = 0

var _rate: int = 60
var _accumulator: float = 0.0
var _resimulating := false
var _in_tick := false
var _in_phases := false           # inside a tick's phases; rollback isn't allowed then
var _removed_now: Dictionary = {} # unregistered during the current tick
var _tick_random := RandomNumberGenerator.new()

var _entries: Array = []      # [{object, order, seq}] sorted by order, then seq
var _input: Array = []        # participants per phase, rebuilt when the registry changes
var _capture: Array = []
var _simulate: Array = []
var _record: Array = []
var _predicted: Array = []    # participants that can be rolled back
var _syncing: Array = []      # participants that can update the collision world straight away
var _dirty := false
var _seq := 0


func _init() -> void:
	process_priority = -100 # tick before other nodes' own processing
	process_physics_priority = -100
	_refresh_rate()


func _physics_process(delta: float) -> void:
	if active:
		advance(delta)


# --- Registry ----------------------------------------------------------------------------------

## Adds a participant. `order`: lower runs first within each phase.
func register(participant: Object, order: int = 0) -> void:
	if participant == null or _find(participant) >= 0:
		return
	_entries.append({"object": participant, "order": order, "seq": _seq})
	_seq += 1
	_dirty = true


func unregister(participant: Object) -> void:
	var i := _find(participant)
	if i >= 0:
		_entries.remove_at(i)
		_dirty = true
		if _in_tick:
			_removed_now[participant] = true


func is_registered(participant: Object) -> bool:
	return _find(participant) >= 0


func get_participant_count() -> int:
	return _entries.size()


# --- Time --------------------------------------------------------------------------------------

## Feeds elapsed time in and runs the ticks it covers. Called every physics frame while active;
## tests call it directly.
func advance(elapsed: float) -> void:
	var dt := get_tick_dt()
	_accumulator += elapsed * tick_factor
	if _accumulator < dt:
		return
	before_tick_loop.emit()
	var ran := 0
	while _accumulator >= dt and ran < max_ticks_per_frame:
		# Claude 2026-11-04: a later tick in this frame must see where the last one left things. Without this, two pawns
		# touching diverged from a one-tick-per-frame run by up to 21 cm in testing (netcode spec section 4.2).
		if ran > 0:
			_sync_collision_world()
		_run_tick(dt)
		_accumulator -= dt
		ran += 1
	if _accumulator >= dt: # hit the limit: drop the rest so we don't fall further behind
		var skipped := int(_accumulator / dt)
		dropped_ticks += skipped
		_accumulator -= skipped * dt
	after_tick_loop.emit()


## Runs exactly one tick now, whatever the time. For tests and tools.
func step() -> void:
	before_tick_loop.emit()
	_run_tick(get_tick_dt())
	after_tick_loop.emit()


func get_tick_rate() -> int:
	return _rate


## Length of one tick in seconds.
func get_tick_dt() -> float:
	return 1.0 / _rate


## Multiply velocity by this before move_and_slide (and divide after) so a tick moves the pawn
## velocity * tick_dt even when tick_rate isn't the physics rate. 1.0 when they match.
func get_physics_factor() -> float:
	return float(Engine.physics_ticks_per_second) / _rate


## How far between the last tick and the next one we are, 0..1. For smoothing visuals per rendered frame.
func get_interpolation_fraction() -> float:
	var physics_dt := 1.0 / Engine.physics_ticks_per_second
	var t := _accumulator + Engine.get_physics_interpolation_fraction() * physics_dt * tick_factor
	return clampf(t / get_tick_dt(), 0.0, 1.0)


## Seconds (as designers type them) to whole ticks. Any time above zero is at least one tick,
## so a short buffer window or cooldown never silently becomes zero.
func seconds_to_ticks(seconds: float) -> int:
	if seconds <= 0.0:
		return 0
	return maxi(1, ceili(seconds * _rate - 0.0001))


func ticks_to_seconds(ticks: int) -> float:
	return ticks * get_tick_dt()


## True while a rollback is replaying ticks. Cosmetic effects (sounds, particles) should not fire then.
func is_resimulating() -> bool:
	return _resimulating


## Claude 2026-11-04: repeatable randomness for gameplay, instead of randf(). The rolls depend only on key, tick and
## salt, so a replay of the same tick gets the same results and there's no generator state to save. Use it right
## away; the same object is returned every call. key is usually an entity id; salt separates rolls within a tick.
func tick_rng(key: int, salt: int = 0) -> RandomNumberGenerator:
	_tick_random.seed = hash(Vector3i(key, tick, salt))
	return _tick_random


## Claude 2026-11-04: puts predicted participants back to how they ended from_tick and replays up to the last
## finished tick. See the rules at the top of this file. Returns true if a replay happened.
func rollback(from_tick: int) -> bool:
	if _in_phases or _resimulating:
		push_warning("[NetworkTime] rollback(%d) ignored: not allowed during a tick's phases or another replay" % from_tick)
		return false
	var real_tick := tick
	var last_finished := tick - 1 if _in_tick else tick # from before_tick, the current tick hasn't run yet
	if from_tick < 0 or from_tick > last_finished:
		return false
	if _dirty:
		_rebuild_phases()
	var loaded: Array = []
	for p in _predicted:
		if is_instance_valid(p) and p._rollback_load(from_tick):
			loaded.append(p)
	if loaded.is_empty():
		return false
	# Claude 2026-11-04: bodies replaying together must see each other's replayed positions. One body alone never hits
	# itself, so the usual client replay of just its own pawn skips this and pays nothing.
	var to_sync: Array = []
	if loaded.size() > 1:
		to_sync = loaded.filter(func(p): return p.has_method(&"_sync_collision"))
	for p in to_sync:
		p._sync_collision()
	# Claude 2026-11-04: known issue, left for later (owner's call after review). This flag is only true from here until
	# the replay ends, so it's still false during the load above and _rollback_finished below. That means a rollback() from
	# a load hook isn't refused and could nest, and effects in load hooks guarded by is_resimulating() would still fire.
	# Fix: set it before the load loop and clear it after the finish loop, including on the early return above.
	_resimulating = true
	var dt := get_tick_dt()
	for t in range(from_tick + 1, last_finished + 1):
		tick = t
		for p in loaded:
			if is_instance_valid(p):
				p._rollback_input(t)
		for p in loaded:
			if is_instance_valid(p):
				p._rollback_simulate(dt, t)
		for p in loaded:
			if is_instance_valid(p):
				p._tick_record(t)
		for p in to_sync:
			if is_instance_valid(p):
				p._sync_collision()
	tick = real_tick
	_resimulating = false
	# Claude 2026-11-04: lets following entities go back to what they had before the replay.
	for p in loaded:
		if is_instance_valid(p) and p.has_method(&"_rollback_finished"):
			p._rollback_finished()
	after_rollback.emit(from_tick, last_finished)
	return true


## Claude 2026-11-04: one body alone never collides with itself, so this only does anything for two or more.
func _sync_collision_world() -> void:
	if _dirty:
		_rebuild_phases()
	if _syncing.size() < 2:
		return
	for p in _syncing:
		if is_instance_valid(p):
			p._sync_collision()


## True where gameplay outcomes are decided. Offline: always. Online: the server.
func is_authority() -> bool:
	if not is_inside_tree() or multiplayer == null or multiplayer.multiplayer_peer == null:
		return true
	if multiplayer.multiplayer_peer is OfflineMultiplayerPeer:
		return true
	return multiplayer.is_server()


# --- Internals ---------------------------------------------------------------------------------

func _run_tick(dt: float) -> void:
	if _dirty:
		_rebuild_phases()
	tick += 1
	_in_tick = true
	before_tick.emit(dt, tick)
	_in_phases = true # Claude 2026-11-04: rollback is refused from here until the phases end
	for p in _input:
		if not is_instance_valid(p):
			_dirty = true
		elif _removed_now.is_empty() or not _removed_now.has(p):
			p._tick_input(dt, tick)
	# Claude 2026-11-04: inputs are saved here, after all of them are written and before simulate can consume them
	for p in _capture:
		if not is_instance_valid(p):
			_dirty = true
		elif _removed_now.is_empty() or not _removed_now.has(p):
			p._tick_capture_input(tick)
	for p in _simulate:
		if not is_instance_valid(p):
			_dirty = true
		elif _removed_now.is_empty() or not _removed_now.has(p):
			p._tick_simulate(dt, tick)
	for p in _record:
		if not is_instance_valid(p):
			_dirty = true
		elif _removed_now.is_empty() or not _removed_now.has(p):
			p._tick_record(tick)
	# Claude 2026-11-04: cleared before after_tick, so the finished tick counts as finished for a rollback from that signal
	_in_phases = false
	_in_tick = false
	after_tick.emit(dt, tick)
	_removed_now.clear()


## Sorts participants and splits them by the phase methods they have. Only runs when the registry
## changed, never per tick. Also drops freed participants.
func _rebuild_phases() -> void:
	_dirty = false
	_entries = _entries.filter(func(e): return is_instance_valid(e.object))
	_entries.sort_custom(func(a, b): return a.order < b.order or (a.order == b.order and a.seq < b.seq))
	_input.clear()
	_capture.clear()
	_simulate.clear()
	_record.clear()
	_predicted.clear()
	_syncing.clear()
	for e in _entries:
		var o: Object = e.object
		if o.has_method(&"_tick_input"):
			_input.append(o)
		if o.has_method(&"_tick_capture_input"):
			_capture.append(o)
		if o.has_method(&"_rollback_load") and o.has_method(&"_rollback_input") and o.has_method(&"_rollback_simulate") and o.has_method(&"_tick_record"):
			_predicted.append(o)
		if o.has_method(&"_sync_collision"):
			_syncing.append(o)
		if o.has_method(&"_tick_simulate"):
			_simulate.append(o)
		if o.has_method(&"_tick_record"):
			_record.append(o)


func _find(participant: Object) -> int:
	for i in _entries.size():
		var o = _entries[i].object
		if is_instance_valid(o) and o == participant:
			return i
	return -1


func _refresh_rate() -> void:
	var r := tick_rate
	if r <= 0:
		r = ProjectSettings.get_setting(TICK_RATE_SETTING, 0)
	if r <= 0:
		r = Engine.physics_ticks_per_second
	_rate = maxi(1, r)
