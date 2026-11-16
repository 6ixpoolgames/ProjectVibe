## Written by Claude (claude-opus-5-5), 2026-11-04: the tick driver (netcode spec section 3), offline version.
## Claude 2026-11-07: renamed from NetworkTime, to the name the netcode spec already used. It drives ticks online and offline.
## Autoload "TickDriver". Every machine runs it, online and offline. All gameplay simulation runs inside its
## numbered, fixed-length ticks, in a fixed phase order, instead of in each node's own _process/_physics_process.
## The abilities, the AI and the netcode all run on it. (Claude 2026-11-17: this said nothing was networked yet.)
##
## How an entity takes part:
##   TickDriver.register(self)    # a Pawn, TickStateComponent or NetworkEntity does this itself in _enter_tree
##   TickDriver.unregister(self)  # or just get freed; freed participants are dropped automatically
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
##     registration order. Every machine registers a level's pawns in the same order, so they run in the same order.
##   - Registering twice changes nothing (the first registration stands). Unregistering an unknown object is a no-op.
##   - Registering DURING a tick takes effect from the next tick. Unregistering during a tick stops its calls
##     immediately (a pawn despawned mid-tick isn't simulated or recorded afterwards).
##   - A freed participant is skipped and dropped, never called.
##   - Spiral of death: at most max_ticks_per_frame ticks per frame. Time beyond that is dropped (the game
##     slows down instead of freezing) and counted in dropped_ticks.
##   - Claude 2026-11-16 (pawn spec 8.21, the owner's call): the load ladder. Each tick's cost is measured against its budget (the
##     tick's length). While ticks use more than raise_above of it for raise_after_ticks, load_step doubles (1, 2, 4); while they use
##     less than lower_below for lower_after_ticks, it halves again (Claude 2026-11-16: or while the load it predicts for the lower
##     step, from what stepping up saved, fits under raise_above less step_down_headroom; see _lower_step_fits). The AIActivationManager makes every AI pawn run at most every
##     load_step-th tick, so an overloaded game sheds AI work, the bulk of a tick, instead of falling behind: the whole game's AI at 30
##     (or 15) ticks a second, with every timer still lasting as long (Pawn.ticks_elapsed). Players' pawns always run every tick.
##     Tick numbers don't change, so nothing in the netcode does either. load_step_override forces a step; load_ladder_enabled off
##     keeps it at 1.
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
##   - While replaying: is_resimulating() is true (cosmetic effects must check it), TickDriver.tick reads as the tick
##     being replayed, and the tick_rng() rolls repeat exactly. Input phases don't run; saved inputs are restored instead.
##   - Everything not predicted stays where it is during the replay, the standard accepted inaccuracy. The exception is
##     an entity in FOLLOW_SERVER mode with follows_during_rollback on: it stands on server data, extrapolates past it on its
##     velocity, then returns to where it was.
##   - Each replaying participant's optional _rollback_finished() runs once the replay is over, before after_rollback.
##   - Loading happens in stages (Claude 2026-11-04): resimulated participants load first. If none could, nothing happens and
##     it returns false, because a replay would have nothing to do. Following ones then join if they want to and are near one
##     of those (wants_to_join_rollback). Then collision positions sync, then each one's optional _rollback_after_load(tick) runs, so
##     a floor check there sees everyone else in place. is_resimulating() is true through all of this and the finish step.
##   - When two or more participants replay, each one's optional _sync_collision() runs after loading and after each
##     replayed tick, so physics bodies collide with each other's replayed positions rather than their final ones.
##   - Allowed between ticks or from before_tick (where the netcode will apply snapshots). During the phases, or
##     during another replay, it warns and returns false.
##   - With physics bodies, call it during the physics frame (before_tick is). Outside it, move_and_slide uses the
##     rendered frame's delta instead, so replayed movement would be the wrong length.
##   - A participant that no longer has from_tick keeps its current state and sits the replay out.
##   - Returns false if nothing could be loaded or from_tick is in the future. No side effects then.
extends Node
class_name TickDriverSingleton

signal before_tick_loop
signal before_tick(dt: float, tick: int)
signal after_tick(dt: float, tick: int)
## Claude 2026-11-09: after every participant has simulated and before anything is recorded (pawn spec 15.1). Effects one entity
## queued for another during simulate, such as hits, are delivered here, so they never depend on which simulated first. Not sent
## during a rollback's replay.
signal after_simulate(dt: float, tick: int)
signal after_tick_loop
signal after_rollback(from_tick: int, to_tick: int) # Claude 2026-11-04: rollback added
## Claude 2026-11-07: state is back to from_tick, and the replay is about to run. A correction can put a pawn somewhere new here,
## and anything that has to be ready before it moves, such as the ground, gets its chance now.
signal rollback_state_loaded(from_tick: int)

const TICK_RATE_SETTING := "project_base/network/tick_rate"
## Claude 2026-11-09 (scaling spec step 6): settings counted in ticks are written for 60 ticks a second, whatever rate a game runs at,
## so designers tune in the same numbers everywhere. ticks_at_rate() turns one into ticks at the rate this match runs at.
const REFERENCE_RATE := 60

## Ticks per second. 0 (default) = use the project's physics rate. Claude 2026-11-09 (scaling spec step 6): chosen before a match
## starts and not changed during it: clients take the server's in the handshake, before anything spawns. Settings counted in ticks
## are written for 60 a second and converted with ticks_at_rate().
@export var tick_rate: int = 0:
	set(value):
		tick_rate = value
		_refresh_rate()
## Most ticks one frame may run (stops a slow frame from causing ever more ticks).
## Claude 2026-11-16 (the owner's 6 fps playtest): was 6, now 3, and the autoload sets Godot's own limit on physics steps a frame
## (Engine.max_physics_steps_per_frame, 8 by default) to the same number. Each physics step runs one tick, so Godot's limit was the
## real one: a frame ran up to 8 ticks to catch up, which made the next frame later still (a catch-up spiral), and nothing was ever
## dropped. Now a frame runs at most 3, and the rest of the time is dropped: an overloaded game slows down instead of freezing.
@export var max_ticks_per_frame: int = 3:
	set(value):
		max_ticks_per_frame = maxi(1, value)
		_apply_physics_rate()
## Claude 2026-11-09 (scaling spec step 6): the autoload sets Godot's physics rate to the tick rate whenever the rate is chosen, so
## there's one tick per physics step and the physics engine doesn't step twice for every tick at 30. Pawns are drawn between ticks
## anyway (Visual's smoothing). Turn it off to keep physics at the project's rate with ticks at another.
@export var physics_follows_tick_rate := true
## False pauses ticking.
@export var active: bool = true

## Current tick number: the last tick that ran. Starts at 0 before any tick.
var tick: int = 0
## Time dilation multiplier. 1.0 offline; adjusted on clients once netcode exists.
var tick_factor: float = 1.0
## Ticks skipped by the max_ticks_per_frame limit, for diagnostics.
var dropped_ticks: int = 0

## Claude 2026-11-16 (pawn spec 8.21): the load ladder (see the top of the file). Sent when load_step changes.
signal load_step_changed(step: int)
## Claude 2026-11-16: on, load_step follows how loaded the ticks are. Off, it stays at 1 (unless load_step_override says otherwise).
@export var load_ladder_enabled := true
## Claude 2026-11-16: the highest load_step the ladder goes to: 1, 2 or 4.
@export_enum("1:1", "2:2", "4:4") var max_load_step := 4
## Claude 2026-11-16: 0 (the default): automatic. 1, 2 or 4: forced, for testing a level or a game that wants one.
@export_enum("Automatic:0", "1:1", "2:2", "4:4") var load_step_override := 0
## Claude 2026-11-16: the share of a tick's budget above which the ladder steps up, after raise_after_ticks in a row.
@export_range(0.1, 2.0, 0.05) var raise_above := 0.85
## Claude 2026-11-16: how many ticks in a row over raise_above before it steps up, at 60 a second. 30: half a second.
@export_range(1, 600, 1) var raise_after_ticks := 30
## Claude 2026-11-16: the share of a tick's budget below which the ladder always steps down, after lower_after_ticks in a row.
## Claude 2026-11-16 (the owner's question: why doesn't it step back down?): it also steps down when it predicts the lower step fits,
## below. This line alone kept it at 4 for good in the owner's run: much of a tick doesn't shrink with the AI's step (recording, the
## player's pawn, the replay), so the tick sat at about half its budget, under 85% and never under 40%.
@export_range(0.0, 1.0, 0.05) var lower_below := 0.4
## Claude 2026-11-16: the ladder also steps down when the load it predicts for the lower step is under raise_above minus this, after
## lower_after_ticks in a row. The prediction is the load now plus what stepping up saved when it last did (measured: the load just
## before the step up, less the load once it had settled). With no measurement yet, it assumes the load doubles.
@export_range(0.0, 1.0, 0.05) var step_down_headroom := 0.15
## Claude 2026-11-16 (audit): how long after a step up the load is measured again to work out what it saved, in ticks at 60 a second.
## About three times what the average takes to settle. Its own setting (it borrowed raise_after_ticks).
@export_range(1, 600, 1) var saving_measured_after_ticks := 30
## Claude 2026-11-16 (audit): a measured saving under this share of the budget is treated as not measured (the load probably rose
## for another reason while measuring, such as a fight starting), so stepping down assumes the load doubles instead of that it
## barely changes, which would bounce the ladder up and down.
@export_range(0.0, 1.0, 0.01) var smallest_believable_saving := 0.05
## Claude 2026-11-16: how many ticks in a row under lower_below before it steps down, at 60 a second. 180: three seconds.
@export_range(1, 3600, 1) var lower_after_ticks := 180
## Claude 2026-11-16: the most every AI pawn may run, as a step: 1 every tick, 2 every 2nd, 4 every 4th. Read it; set
## load_step_override to force it.
var load_step := 1
## Claude 2026-11-16: how much of its budget a tick has used lately, smoothed over about ten ticks: 1.0 is the whole tick's length.
var load_average := 0.0
# Claude 2026-11-16 (the ladder's prediction): step -> how much of the budget stepping up to it saved (load before less load after),
# measured once the average has settled after the step up; and the step being measured, the load before it, and the ticks left.
var _saving_at := {}
var _measuring_step := 0
var _load_before_raise := 0.0
var _measure_ticks_left := 0
var _over_ticks := 0
var _under_ticks := 0
var _physics_steps_this_frame := 0 # Claude 2026-11-16: physics steps since the last rendered frame
## Claude 2026-11-05: on, each tick phase adds up its time in microseconds into profile, for finding what's slow. Off, it costs
## a few checks of this flag per tick.
var profile_enabled: bool = false
## Claude 2026-11-16 (wider audit): the entries of profile that count things. The rest are times in microseconds.
const PROFILE_COUNTS: Array[String] = ["ticks", "rollbacks", "rollback_ticks"]
var profile: Dictionary = {}

var _rate: int = 60
var _accumulator: float = 0.0
var _resimulating := false
var _in_tick := false
var _in_phases := false           # inside a tick's phases; rollback isn't allowed then
var _in_simulate := false         # Claude 2026-11-09: inside a tick's simulate phase (not a replay's); see is_in_simulate()
var _removed_now: Dictionary = {} # unregistered during the current tick
var _tick_random := RandomNumberGenerator.new()

# Claude 2026-11-16 (wider audit): each entry also keeps its object's id and which phases it takes part in (worked out once, when it
# registers), and the list is kept in order as entries arrive. _registered answers "is this one in?" without a search. Before, every
# register and unregister searched the whole list, and any change had the next tick sort it again and ask every participant about
# nine functions: about 450 entries at 150 pawns, each time one spawned, died or froze.
var _entries: Array = []      # [{object, order, seq, id, phases}] in order: by order, then seq
var _registered: Dictionary = {} # instance id -> the seq of its entry
const _PHASE_INPUT := 1
const _PHASE_CAPTURE := 2
const _PHASE_PREDICTED := 4
const _PHASE_SYNCING := 8
const _PHASE_SIMULATE := 16
const _PHASE_RECORD := 32
var _input: Array = []        # participants per phase, rebuilt when the registry changes
var _capture: Array = []
var _simulate: Array = []
var _record: Array = []
var _predicted: Array = []    # participants that can be rolled back
var _syncing: Array = []      # participants that can update the collision world straight away
var _dirty := false
var _seq := 0


func _ready() -> void:
	_apply_physics_rate() # Claude 2026-11-09 (step 6): _init runs before the autoload is in the tree


func _init() -> void:
	process_priority = -100 # tick before other nodes' own processing
	process_physics_priority = -100
	# Claude 2026-11-09 (scaling spec step 6): a dedicated server can choose its rate at start-up, with "-- --tick-rate=30" after
	# Godot's own arguments. It wins over the project setting. Clients take the server's rate in the handshake anyway.
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--tick-rate="):
			tick_rate = maxi(0, int(arg.trim_prefix("--tick-rate=")))
	_refresh_rate()


func _physics_process(delta: float) -> void:
	if active:
		_physics_steps_this_frame += 1 # Claude 2026-11-16: for counting the time Godot drops (_process)
		advance(delta)


# Claude 2026-11-16: Godot drops the time beyond max_physics_steps_per_frame itself, before advance() sees it, so it's counted here,
# once a rendered frame: a frame that ran the most steps it may, and was longer than they cover, dropped the rest. Counted in
# dropped_ticks with the driver's own, so diagnostics show when the game slows down. Only the autoload, which sets Godot's limit.
func _process(delta: float) -> void:
	var steps := _physics_steps_this_frame
	_physics_steps_this_frame = 0
	if not active or steps < max_ticks_per_frame or not (is_inside_tree() and get_parent() == get_tree().root):
		return
	var dt := get_tick_dt()
	var behind := delta * tick_factor - steps * dt
	if behind >= dt:
		dropped_ticks += int(behind / dt)


# --- Registry ----------------------------------------------------------------------------------

## Adds a participant. `order`: lower runs first within each phase.
func register(participant: Object, order: int = 0) -> void:
	if participant == null:
		return
	var id := participant.get_instance_id()
	if _registered.has(id):
		return
	_registered[id] = _seq
	var entry := {"object": participant, "order": order, "seq": _seq, "id": id, "phases": _phases_of(participant)}
	_seq += 1
	# Kept in order: after every entry with the same or a lower order. Nearly always that's the end of the list, or a step or two
	# before it, so this loop is short.
	var at := _entries.size()
	while at > 0 and _entries[at - 1].order > order:
		at -= 1
	_entries.insert(at, entry)
	_dirty = true


func unregister(participant: Object) -> void:
	if participant == null:
		return
	var id := participant.get_instance_id()
	if not _registered.has(id):
		return
	_registered.erase(id) # its entry is dropped the next time the phases are rebuilt
	_dirty = true
	if _in_tick:
		_removed_now[participant] = true


func is_registered(participant: Object) -> bool:
	return participant != null and _registered.has(participant.get_instance_id())


func get_participant_count() -> int:
	return _registered.size()


# Claude 2026-11-16 (wider audit): which phases a participant takes part in, as bits, from the functions it has.
func _phases_of(o: Object) -> int:
	var phases := 0
	if o.has_method(&"_tick_input"):
		phases |= _PHASE_INPUT
	if o.has_method(&"_tick_capture_input"):
		phases |= _PHASE_CAPTURE
	if o.has_method(&"_rollback_load") and o.has_method(&"_rollback_input") and o.has_method(&"_rollback_simulate") and o.has_method(&"_tick_record"):
		phases |= _PHASE_PREDICTED
	if o.has_method(&"_sync_collision"):
		phases |= _PHASE_SYNCING
	if o.has_method(&"_tick_simulate"):
		phases |= _PHASE_SIMULATE
	if o.has_method(&"_tick_record"):
		phases |= _PHASE_RECORD
	return phases


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


## Claude 2026-11-09 (scaling spec step 6): a setting counted in ticks at the reference rate (60 a second), as ticks at this match's
## rate, so it lasts the same time: round(ticks × rate ÷ 60), and at least 1 where the setting is above 0. 0 and negative settings
## (which usually mean "off" or "use the default") come back as they are. At 60 it changes nothing. An 8-tick wind-up is 8 ticks at
## 60 and 4 at 30: 0.13 s either way. A setting that doesn't divide evenly is up to half a tick off.
func ticks_at_rate(reference_ticks: int) -> int:
	if reference_ticks <= 0 or _rate == REFERENCE_RATE:
		return reference_ticks
	return maxi(1, roundi(reference_ticks * float(_rate) / REFERENCE_RATE))


## Claude 2026-11-09 (step 6): an amount added each tick at the reference rate (sight's fill_rate, say), as the amount each tick at
## this match's rate adds, so the total over a second is the same: amount × 60 ÷ rate.
func per_tick_at_rate(reference_amount: float) -> float:
	return reference_amount * REFERENCE_RATE / float(_rate)


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


## Claude 2026-11-04: jumps to a tick number. For a client setting its clock from the server's; use nothing else to change
## tick. Not allowed during a tick. Saved history stays valid, because each slot remembers which tick it holds.
func set_tick(new_tick: int) -> void:
	if _in_tick or _resimulating:
		push_warning("[TickDriver] set_tick(%d) ignored: not allowed during a tick or a replay" % new_tick)
		return
	tick = new_tick
	_accumulator = 0.0


## True while a rollback is replaying ticks. Cosmetic effects (sounds, particles) should not fire then.
func is_resimulating() -> bool:
	return _resimulating


## Claude 2026-11-09 (scaling spec step 3): true while a tick runs, from before_tick to after_tick. A request aimed at another pawn's AI
## made then is queued and applied at that pawn's next AI step (pawn spec 15.1), so it never depends on which pawn went first.
func is_in_tick() -> bool:
	return _in_tick


## Claude 2026-11-09: true while a tick's simulate phase runs (not a rollback's replay). An effect aimed at another entity during
## it is queued and delivered from after_simulate (pawn spec 15.1).
func is_in_simulate() -> bool:
	return _in_simulate


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
		push_warning("[TickDriver] rollback(%d) ignored: not allowed during a tick's phases or another replay" % from_tick)
		return false
	var profile_started := Time.get_ticks_usec() if profile_enabled else 0
	var real_tick := tick
	var last_finished := tick - 1 if _in_tick else tick # from before_tick, the current tick hasn't run yet
	if from_tick < 0 or from_tick > last_finished:
		return false
	if _dirty:
		_rebuild_phases()
	# Claude 2026-11-04: on from here, so load hooks count as part of the replay: they can't start another, and effects
	# they guard with is_resimulating() stay quiet.
	_resimulating = true
	var loaded := _load_for_rollback(from_tick)
	if loaded.is_empty():
		_resimulating = false
		return false
	# Claude 2026-11-04: bodies replaying together must see each other's replayed positions. One body alone never hits
	# itself, so the usual client replay of just its own pawn skips this and pays nothing.
	var to_sync: Array = []
	if loaded.size() > 1:
		to_sync = loaded.filter(func(p): return p.has_method(&"_sync_collision"))
	for p in to_sync:
		p._sync_collision()
	for p in loaded:
		if is_instance_valid(p) and p.has_method(&"_rollback_after_load"):
			p._rollback_after_load(from_tick)
	rollback_state_loaded.emit(from_tick)
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
	# Claude 2026-11-04: lets following entities go back to what they had before the replay.
	for p in loaded:
		if is_instance_valid(p) and p.has_method(&"_rollback_finished"):
			p._rollback_finished()
	_resimulating = false
	if profile_enabled:
		profile["rollback"] += Time.get_ticks_usec() - profile_started
		profile["rollbacks"] += 1
		profile["rollback_ticks"] += last_finished - from_tick
	after_rollback.emit(from_tick, last_finished)
	return true


## Claude 2026-11-04: loads resimulated participants, then the following ones near them. Far-away following entities are
## skipped, which is what keeps a large swarm affordable. Empty if no resimulated participant could load.
func _load_for_rollback(from_tick: int) -> Array:
	var loaded: Array = []
	var following: Array = []
	for p in _predicted:
		if not is_instance_valid(p):
			continue
		if p.has_method(&"is_following_server") and p.is_following_server():
			following.append(p)
		elif p._rollback_load(from_tick):
			loaded.append(p)
	if loaded.is_empty():
		return loaded
	var centres: Array = []
	for p in loaded:
		if p.has_method(&"get_rollback_centre"):
			var centre: Variant = p.get_rollback_centre()
			if centre != null:
				centres.append(centre)
	var joined: Array = []
	for p in following:
		if p.wants_to_join_rollback(centres) and p._rollback_load(from_tick):
			joined.append(p)
	# Following ones go first in each replayed tick, so a resimulated entity reading their properties sees that tick's values.
	return joined + loaded


## Claude 2026-11-04: one body alone never collides with itself, so this only does anything for two or more.
func _sync_collision_world() -> void:
	if _dirty:
		_rebuild_phases()
	if _syncing.size() < 2:
		return
	for p in _syncing:
		# Claude 2026-11-04: following entities don't move during a tick's simulation, and this runs when the machine is already
		# behind, so a large swarm mustn't add to it.
		if is_instance_valid(p) and not (p.has_method(&"is_following_server") and p.is_following_server()):
			p._sync_collision()


## Claude 2026-11-05: empties the timing record. See profile_enabled.
func reset_profile() -> void:
	profile = {"ticks": 0, "before_tick": 0, "input": 0, "capture": 0, "simulate": 0, "record": 0, "after_tick": 0, "rollback": 0, "rollbacks": 0, "rollback_ticks": 0}


## True where gameplay outcomes are decided. Offline: always. Online: the server.
func is_authority() -> bool:
	if not is_inside_tree() or multiplayer == null or multiplayer.multiplayer_peer == null:
		return true
	if multiplayer.multiplayer_peer is OfflineMultiplayerPeer:
		return true
	return multiplayer.is_server()


# --- Internals ---------------------------------------------------------------------------------

func _run_tick(dt: float) -> void:
	var tick_started := Time.get_ticks_usec() # Claude 2026-11-16: for the load ladder
	if _dirty:
		_rebuild_phases()
	tick += 1
	_in_tick = true
	var mark := Time.get_ticks_usec() if profile_enabled else 0
	before_tick.emit(dt, tick)
	mark = _profile_phase(&"before_tick", mark)
	_in_phases = true # Claude 2026-11-04: rollback is refused from here until the phases end
	for p in _input:
		if not is_instance_valid(p):
			_dirty = true
		elif _removed_now.is_empty() or not _removed_now.has(p):
			p._tick_input(dt, tick)
	mark = _profile_phase(&"input", mark)
	# Claude 2026-11-04: inputs are saved here, after all of them are written and before simulate can consume them
	for p in _capture:
		if not is_instance_valid(p):
			_dirty = true
		elif _removed_now.is_empty() or not _removed_now.has(p):
			p._tick_capture_input(tick)
	mark = _profile_phase(&"capture", mark)
	_in_simulate = true # Claude 2026-11-09
	for p in _simulate:
		if not is_instance_valid(p):
			_dirty = true
		elif _removed_now.is_empty() or not _removed_now.has(p):
			p._tick_simulate(dt, tick)
	_in_simulate = false
	after_simulate.emit(dt, tick) # Claude 2026-11-09: queued effects, such as hits, are delivered here (pawn spec 15.1)
	mark = _profile_phase(&"simulate", mark)
	for p in _record:
		if not is_instance_valid(p):
			_dirty = true
		elif _removed_now.is_empty() or not _removed_now.has(p):
			p._tick_record(tick)
	mark = _profile_phase(&"record", mark)
	# Claude 2026-11-04: cleared before after_tick, so the finished tick counts as finished for a rollback from that signal
	_in_phases = false
	_in_tick = false
	after_tick.emit(dt, tick)
	_profile_phase(&"after_tick", mark)
	if profile_enabled:
		profile["ticks"] += 1
	_removed_now.clear()
	_note_tick_cost(Time.get_ticks_usec() - tick_started, dt) # Claude 2026-11-16: the load ladder


## Claude 2026-11-16: the settings a start menu may offer before a match (MatchOptionsPanel.add_from_autoloads): the load ladder.
func get_match_options() -> PackedStringArray:
	return PackedStringArray(["load_ladder_enabled", "load_step_override"])


# Claude 2026-11-16 (pawn spec 8.21): the load ladder's rule, from one tick's cost in microseconds. See the top of the file.
func _note_tick_cost(microseconds: int, dt: float) -> void:
	var share := float(microseconds) / maxf(dt * 1000000.0, 1.0)
	load_average = lerpf(load_average, share, 0.1)
	if load_step_override > 0:
		_set_load_step(load_step_override)
		return
	if not load_ladder_enabled:
		_set_load_step(1)
		return
	# Claude 2026-11-16 (the ladder's prediction): once the average has settled after a step up, note what that step saved.
	if _measure_ticks_left > 0:
		_measure_ticks_left -= 1
		if _measure_ticks_left == 0 and load_step == _measuring_step:
			var saving := _load_before_raise - load_average
			if saving >= smallest_believable_saving:
				_saving_at[_measuring_step] = saving
			else:
				_saving_at.erase(_measuring_step) # Claude 2026-11-16 (audit): not believable; assume the load doubles
	_over_ticks = _over_ticks + 1 if load_average > raise_above else 0
	_under_ticks = _under_ticks + 1 if _lower_step_fits() else 0
	if _over_ticks >= ticks_at_rate(raise_after_ticks) and load_step < max_load_step:
		_over_ticks = 0
		_under_ticks = 0
		_load_before_raise = load_average
		_set_load_step(load_step * 2)
		_measuring_step = load_step
		_measure_ticks_left = ticks_at_rate(saving_measured_after_ticks)
	elif _under_ticks >= ticks_at_rate(lower_after_ticks) and load_step > 1:
		_under_ticks = 0
		_set_load_step(load_step >> 1) # GDScript note: >> 1 halves a whole number, with no warning about dropping a fraction


## Claude 2026-11-16: true if the next step down looks safe now: the load is under lower_below, or the load predicted for the lower
## step (the load now plus what this step saved, or twice the load if that isn't known) is under raise_above less step_down_headroom.
func _lower_step_fits() -> bool:
	if load_step <= 1:
		return false
	if load_average < lower_below:
		return true
	var predicted: float = load_average + float(_saving_at.get(load_step, load_average))
	return predicted < raise_above - step_down_headroom


func _set_load_step(wanted: int) -> void:
	var allowed := 4 if wanted >= 4 else (2 if wanted >= 2 else 1)
	if allowed == load_step:
		return
	load_step = allowed
	load_step_changed.emit(load_step)


## Claude 2026-11-05: adds the time since mark to this phase, and returns the new mark.
func _profile_phase(phase: StringName, mark: int) -> int:
	if not profile_enabled:
		return 0
	var now := Time.get_ticks_usec()
	profile[phase] = int(profile.get(phase, 0)) + now - mark
	return now


## Sorts participants and splits them by the phase methods they have. Only runs when the registry
## changed, never per tick. Also drops freed participants.
func _rebuild_phases() -> void:
	_dirty = false
	# Claude 2026-11-16 (wider audit): one pass. Entries unregistered since (their id is gone from _registered, or belongs to a newer
	# entry of the same object) and freed ones are dropped; the rest are already in order, with their phases known.
	var kept: Array = []
	for e in _entries:
		if _registered.get(e.id, -1) != e.seq:
			continue
		if not is_instance_valid(e.object):
			_registered.erase(e.id)
			continue
		kept.append(e)
	_entries = kept
	_input.clear()
	_capture.clear()
	_simulate.clear()
	_record.clear()
	_predicted.clear()
	_syncing.clear()
	for e in _entries:
		var o: Object = e.object
		var phases: int = e.phases
		if phases & _PHASE_INPUT:
			_input.append(o)
		if phases & _PHASE_CAPTURE:
			_capture.append(o)
		if phases & _PHASE_PREDICTED:
			_predicted.append(o)
		if phases & _PHASE_SYNCING:
			_syncing.append(o)
		if phases & _PHASE_SIMULATE:
			_simulate.append(o)
		if phases & _PHASE_RECORD:
			_record.append(o)


func _refresh_rate() -> void:
	var r := tick_rate
	if r <= 0:
		r = ProjectSettings.get_setting(TICK_RATE_SETTING, 0)
	if r <= 0:
		r = Engine.physics_ticks_per_second
	_rate = maxi(1, r)
	_apply_physics_rate()


# Claude 2026-11-09 (scaling spec step 6): only the autoload, never a test's own driver, and only when it's in the tree.
func _apply_physics_rate() -> void:
	if not (physics_follows_tick_rate and is_inside_tree() and get_parent() == get_tree().root):
		return
	if Engine.physics_ticks_per_second != _rate:
		Engine.physics_ticks_per_second = _rate
	# Claude 2026-11-16: Godot's catch-up limit follows this one, so a frame never runs more ticks than max_ticks_per_frame (see there).
	Engine.max_physics_steps_per_frame = max_ticks_per_frame
