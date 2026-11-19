# Written by Claude (claude-opus-5-5), 2026-11-04. History: singletons/CHANGELOG.md.
## Runs all gameplay in numbered, fixed-length ticks, online and offline. Autoload "TickDriver".
##
## Every machine runs it. Pawns, TickStateComponent and NetworkEntity register with it and get called once a tick, in phases, instead
## of in their own _physics_process; abilities, AI and netcode all run on it. [code]dt[/code] is always the fixed tick length.
## [codeblock]
## TickDriver.register(self)   # then write any of _tick_input(dt, tick), _tick_capture_input(tick),
##                             # _tick_simulate(dt, tick), _tick_record(tick); each is optional
## [/codeblock]
## One tick: [signal before_tick], input, capture input, simulate, [signal after_simulate], record, commit, [signal after_tick]. Within a
## phase, lower [code]order[/code] runs first, then registration order. The commit writes every entity's state into [member store], the
## record of play at tick boundaries. A participant with a [code]due_tick[/code] property (a pawn) isn't called in input or simulate
## before that tick, so a pawn on a load step costs nothing on the ticks it skips. Rollback and the load ladder are in the README.
## Design: state store spec 4 and 9, netcode spec 3 (rollback 3.5), scaling spec 7, pawn spec 8.21 (load ladder).
extends Node
class_name TickDriverSingleton

## Sent once a frame, before the frame's first tick. Not sent in a frame with no tick due.
signal before_tick_loop
## Sent at the start of each tick, before any phase. The netcode applies snapshots here, and may roll back from it.
signal before_tick(dt: float, tick: int)
## Sent at the end of each tick, after every phase. A rollback from here counts this tick as finished.
signal after_tick(dt: float, tick: int)
## Sent after every participant has simulated, before anything is recorded (pawn spec 15.1). Queued effects, such as hits, are delivered
## here, so they never depend on simulate order. Not sent during a replay.
signal after_simulate(dt: float, tick: int)
## Sent once a frame, after the frame's last tick. Delays counted in ticks (SpawnManager's, say) run here, between ticks.
signal after_tick_loop
## Sent when a rollback's replay is over: it went back to from_tick and replayed up to to_tick.
signal after_rollback(from_tick: int, to_tick: int)
## State is back to from_tick and the replay is about to run. A correction can move a pawn here, and anything that must be ready
## before it moves (the ground, say) gets its chance now.
signal rollback_state_loaded(from_tick: int)

## The project setting for the tick rate. 0 or missing: the project's physics rate.
const TICK_RATE_SETTING := "project_base/network/tick_rate"
## Settings counted in ticks are written for 60 ticks a second, whatever rate a game runs at.
## [method ticks_at_rate] turns one into ticks at this match's rate.
const REFERENCE_RATE := 60

## Ticks per second; 0 is the project setting, else the physics rate. Fixed before a match (scaling spec 7): clients take the server's in
## the handshake. A dedicated server can set it with [code]-- --tick-rate=30[/code].
@export var tick_rate: int = 0:
	set(value):
		tick_rate = value
		_refresh_rate()
## Most ticks one frame may run; the rest of the time is dropped (the game slows down instead of freezing). The autoload sets
## Godot's [code]max_physics_steps_per_frame[/code] to match, since that limit is the one that really counts.
@export var max_ticks_per_frame: int = 3:
	set(value):
		max_ticks_per_frame = maxi(1, value)
		_apply_physics_rate()
## On, the autoload sets Godot's physics rate to the tick rate, so there is one tick per physics step. Off, physics keeps the project's
## rate with ticks at another.
@export var physics_follows_tick_rate := true
## False pauses ticking.
@export var active: bool = true
## Ticks of history [member store] keeps: the deepest any reader needs (rollback, lag compensation, snapshot baselines). Applies while
## the store is empty, so set it before entities arrive.
@export_range(8, 1024, 1) var history_depth: int = 64:
	set(value):
		history_depth = value
		if store:
			store.set_depth(value)
## On, the start of each tick checks every bound entity's nodes still hold what the last commit recorded, and warns about the ones that
## don't: something wrote around the store (state store spec 4). Costs a read of every gathered value; for finding such writes.
@export var verify_store_each_tick := false

## The central record of play ([code]StateStore[/code] in C++, or its twin [StateStoreGD]): every entity's state at the end of each
## tick. Untyped because it's one of two classes with the same calls.
var store: Object = null
## Use the C++ store when the library is there. Off: the GDScript twin, for comparing (tests take [code]-- --gdscript-store[/code]).
static var use_native_store: bool = true
## Entities the tripwire ([member verify_store_each_tick]) has caught, added up.
var store_mismatches: int = 0

## Current tick number: the last tick that ran, 0 before any. Change it only with [method set_tick].
var tick: int = 0
## Time dilation multiplier: how fast ticks happen. 1.0 offline and on the server; on a client the netcode nudges it to keep its clock right.
var tick_factor: float = 1.0
## Ticks dropped by the [member max_ticks_per_frame] limit, plus time Godot dropped beyond its own limit; for diagnostics.
var dropped_ticks: int = 0

## Sent when [member load_step] changes (see the load ladder in the README).
signal load_step_changed(step: int)
## On, [member load_step] follows how loaded the ticks are. Off, it stays at 1 (unless [member load_step_override] says otherwise).
@export var load_ladder_enabled := true
## The highest [member load_step] the ladder goes to: 1, 2 or 4.
@export_enum("1:1", "2:2", "4:4") var max_load_step := 4
## 0: automatic. 1, 2 or 4: forced, for testing a level or a game that wants one.
@export_enum("Automatic:0", "1:1", "2:2", "4:4") var load_step_override := 0
## The share of a tick's budget above which the ladder steps up, after [member raise_after_ticks] in a row.
@export_range(0.1, 2.0, 0.05) var raise_above := 0.85
## Ticks in a row over [member raise_above] before it steps up, at 60 a second. 30: half a second.
@export_range(1, 600, 1) var raise_after_ticks := 30
## The share of a tick's budget below which the ladder steps down, after [member lower_after_ticks] in a row. It also steps down when
## it predicts the lower step fits ([member step_down_headroom]), as much of a tick doesn't shrink with the AI's step.
@export_range(0.0, 1.0, 0.05) var lower_below := 0.4
## It also steps down when the load predicted for the lower step is under [member raise_above] minus this. Predicted: the load now plus
## what stepping up saved last time; with no measurement yet, twice the load.
@export_range(0.0, 1.0, 0.05) var step_down_headroom := 0.15
## Ticks after a step up before the load is measured to work out what it saved, at 60 a second. About three times what the average
## takes to settle.
@export_range(1, 600, 1) var saving_measured_after_ticks := 30
## A measured saving under this share of the budget counts as not measured (the load likely rose for another reason), so stepping down
## assumes the load doubles; this stops the ladder bouncing.
@export_range(0.0, 1.0, 0.01) var smallest_believable_saving := 0.05
## Ticks in a row under [member lower_below] (or with the lower step predicted to fit) before it steps down, at 60 a second. 180: three
## seconds.
@export_range(1, 3600, 1) var lower_after_ticks := 180
## The most every AI pawn may run, as a step: 1 every tick, 2 every 2nd, 4 every 4th. Read it; set [member load_step_override] to force it.
var load_step := 1
## How much of its budget a tick has used lately, smoothed over about ten ticks: 1.0 is the whole tick's length.
var load_average := 0.0
# The ladder's prediction: step -> budget share that stepping up to it saved, measured once the average settled; then the step being measured.
var _saving_at := {}
var _measuring_step := 0
var _load_before_raise := 0.0
var _measure_ticks_left := 0
var _over_ticks := 0
var _under_ticks := 0
var _physics_steps_this_frame := 0 # physics steps since the last rendered frame
# REFACTOR: profile is a second way of timing work beside diagnostics' PerfScopes, with its own names and its own switch. One timing
# tool would be one place to look and one thing to learn (reusable).
## On, each tick phase adds up its time in microseconds into [member profile], for finding what's slow. Off, it costs a few flag checks
## per tick.
var profile_enabled: bool = false
## The entries of [member profile] that count things. The rest are times in microseconds.
const PROFILE_COUNTS: Array[String] = ["ticks", "rollbacks", "rollback_ticks"]
## Each phase's time in microseconds, plus the counts in [constant PROFILE_COUNTS], while [member profile_enabled] is on. Emptied by
## [method reset_profile].
var profile: Dictionary = {}

var _rate: int = 60
var _accumulator: float = 0.0
var _resimulating := false
var _in_tick := false
var _in_phases := false           # inside a tick's phases; rollback isn't allowed then
var _in_simulate := false         # inside a tick's simulate phase (not a replay's); see is_in_simulate()
var _removed_now: Dictionary = {} # unregistered during the current tick
var _tick_random := RandomNumberGenerator.new()

# Each entry keeps its object's id and phases (worked out once, at register) and the list stays in order as entries arrive, so a pawn
# spawning or dying costs no sort and no asking what functions it has.
var _entries: Array = []      # [{object, order, seq, id, phases}] in order: by order, then seq
var _registered: Dictionary = {} # instance id -> the seq of its entry
const _PHASE_INPUT := 1
const _PHASE_CAPTURE := 2
const _PHASE_PREDICTED := 4
const _PHASE_SYNCING := 8
const _PHASE_SIMULATE := 16
const _PHASE_RECORD := 32
const _PHASE_DUE := 64 # it has a due_tick, and isn't called in input or simulate before that tick
var _input: Array = []        # participants per phase, rebuilt when the registry changes
var _capture: Array = []
var _simulate: Array = []
var _input_due := PackedByteArray()    # 1 where the participant at the same index in _input has a due_tick
var _simulate_due := PackedByteArray() # the same for _simulate
var _record: Array = []
var _predicted: Array = []    # participants that can be rolled back
var _syncing: Array = []      # participants that can update the collision world straight away
var _dirty := false
var _seq := 0


func _ready() -> void:
	_apply_physics_rate() # _init runs before the autoload is in the tree, so this is where it can apply


func _init() -> void:
	process_priority = -100 # tick before other nodes' own processing
	process_physics_priority = -100
	if OS.get_cmdline_user_args().has("--gdscript-store"):
		use_native_store = false
	replace_store(null)
	# A dedicated server can set its rate at start-up ("-- --tick-rate=30"); it wins over the project setting. Clients take the server's.
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--tick-rate="):
			tick_rate = maxi(0, int(arg.trim_prefix("--tick-rate=")))
	_refresh_rate()


func _physics_process(delta: float) -> void:
	if active:
		_physics_steps_this_frame += 1 # for counting the time Godot drops (_process)
		advance(delta)


# Godot drops time beyond max_physics_steps_per_frame itself, before advance() sees it, so it's counted here once a rendered frame
# (a frame that ran the most steps and was longer than they cover) in dropped_ticks. Only the autoload, which sets Godot's limit.
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

## Adds a participant. [code]order[/code]: lower runs first within each phase; equal order keeps registration order. Registering twice
## changes nothing; during a tick it takes effect next tick. Gotcha: a participant that also has _physics_process must turn it off in _ready, not _enter_tree, or it ticks twice.
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


## Swaps in a new, empty store (null: a fresh one of the kind [member use_native_store] picks), for tests comparing the two. Entities
## already recorded stay in the old one, so call it before they arrive.
func replace_store(new_store: Object) -> void:
	if new_store == null:
		new_store = ClassDB.instantiate(&"StateStore") if use_native_store and ClassDB.class_exists(&"StateStore") else StateStoreGD.new()
	new_store.set_depth(history_depth)
	store = new_store


## Removes a participant. During a tick its calls stop at once (a pawn despawned mid-tick isn't simulated or recorded). Freed ones are dropped by themselves.
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


## True if this participant is registered.
func is_registered(participant: Object) -> bool:
	return participant != null and _registered.has(participant.get_instance_id())


## How many participants are registered.
func get_participant_count() -> int:
	return _registered.size()


# Which phases a participant takes part in, as bits, from the functions it has.
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
	if &"due_tick" in o:
		phases |= _PHASE_DUE
	return phases


# --- Time --------------------------------------------------------------------------------------

## Feeds elapsed time in and runs the ticks it covers, at most [member max_ticks_per_frame] (the rest is dropped and counted). Called every
## physics frame while [member active]; tests call it directly.
func advance(elapsed: float) -> void:
	var dt := get_tick_dt()
	_accumulator += elapsed * tick_factor
	if _accumulator < dt:
		return
	before_tick_loop.emit()
	var ran := 0
	while _accumulator >= dt and ran < max_ticks_per_frame:
		# A later tick in this frame must see where the last one left things, or touching pawns drift from a one-tick-per-frame run
		# (up to 21 cm in testing; netcode spec 4.2). Frames with one tick pay nothing.
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


## Ticks per second this match runs at.
func get_tick_rate() -> int:
	return _rate


## A setting counted in ticks at the reference rate (60 a second) as ticks at this match's rate, so it lasts the same time: round(ticks
## × rate ÷ 60), at least 1 if the setting is above 0; 0 and negative come back unchanged. An 8-tick wind-up is 4 ticks at 30.
func ticks_at_rate(reference_ticks: int) -> int:
	if reference_ticks <= 0 or _rate == REFERENCE_RATE:
		return reference_ticks
	return maxi(1, roundi(reference_ticks * float(_rate) / REFERENCE_RATE))


## An amount added each tick at the reference rate (sight's fill_rate, say) as the amount each tick adds at this match's rate:
## amount × 60 ÷ rate.
func per_tick_at_rate(reference_amount: float) -> float:
	return reference_amount * REFERENCE_RATE / float(_rate)


## Length of one tick in seconds.
func get_tick_dt() -> float:
	return 1.0 / _rate


## Multiply velocity by this before move_and_slide (and divide after), which scales by Godot's physics delta, so a tick moves the pawn
## velocity × tick length even if tick_rate isn't the physics rate. 1.0 when they match.
func get_physics_factor() -> float:
	return float(Engine.physics_ticks_per_second) / _rate


## How far between the last tick and the next it is, 0 to 1. For smoothing visuals per rendered frame.
func get_interpolation_fraction() -> float:
	var physics_dt := 1.0 / Engine.physics_ticks_per_second
	var t := _accumulator + Engine.get_physics_interpolation_fraction() * physics_dt * tick_factor
	return clampf(t / get_tick_dt(), 0.0, 1.0)


## Seconds (as designers type them) to whole ticks. Any time above zero is at least one tick, so a short window never becomes zero.
func seconds_to_ticks(seconds: float) -> int:
	if seconds <= 0.0:
		return 0
	return maxi(1, ceili(seconds * _rate - 0.0001))


## Ticks to seconds at this match's rate.
func ticks_to_seconds(ticks: int) -> float:
	return ticks * get_tick_dt()


## Jumps to a tick number; the only way to change [member tick]. For a client setting its clock from the server's. Not allowed during a tick
## or a replay. Saved history stays valid, as each slot remembers which tick it holds.
func set_tick(new_tick: int) -> void:
	if _in_tick or _resimulating:
		push_warning("[TickDriver] set_tick(%d) ignored: not allowed during a tick or a replay" % new_tick)
		return
	tick = new_tick
	_accumulator = 0.0


## True while a rollback replays ticks. Cosmetic effects (sounds, particles) must not fire then.
func is_resimulating() -> bool:
	return _resimulating


## True while a tick runs, from before_tick to after_tick. A request aimed at another pawn's AI made then is queued for that pawn's next
## AI step (pawn spec 15.1), so it never depends on which pawn went first.
func is_in_tick() -> bool:
	return _in_tick


## True while a tick's simulate phase runs (not a replay's). An effect aimed at another entity then is queued and delivered from
## [signal after_simulate] (pawn spec 15.1).
func is_in_simulate() -> bool:
	return _in_simulate


## Repeatable randomness for gameplay, instead of randf(): the rolls depend only on key (usually an entity id), tick and salt (separates
## rolls in one tick), so a replayed tick rolls the same. Use it at once; the same object is returned every call.
func tick_rng(key: int, salt: int = 0) -> RandomNumberGenerator:
	_tick_random.seed = hash(Vector3i(key, tick, salt))
	return _tick_random


## Rolls predicted participants back to how they ended from_tick, then replays every tick up to the last finished one (netcode spec 3.5).
## Only between ticks or from before_tick; else warns and returns false, as it does if nothing could load or from_tick is in the future. Rules in the README.
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
	# On from here, so load hooks count as part of the replay: they can't start another, and effects
	# they guard with is_resimulating() stay quiet.
	_resimulating = true
	var loaded := _load_for_rollback(from_tick)
	if loaded.is_empty():
		_resimulating = false
		return false
	# Bodies replaying together must see each other's replayed positions. One body alone never hits
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
	# The re-run rewrites these entities' rows in the store, tick by tick.
	var handles := PackedInt64Array()
	for p in loaded:
		if is_instance_valid(p) and p.has_method(&"get_store_handle"):
			var handle: int = p.get_store_handle()
			if handle >= 0:
				handles.append(handle)
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
		_commit_entities(t, handles)
		for p in to_sync:
			if is_instance_valid(p):
				p._sync_collision()
	tick = real_tick
	# Lets following entities go back to what they had before the replay.
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


## Loads resimulated participants, then following ones near them (far-away followers are skipped, which keeps a swarm affordable).
## Empty if no resimulated participant could load.
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


## The commit: every active entity's row for this tick into the store, in one pass. Entities the store can't read by itself (still
## being matched, or a node gone) are handed to their owner's [code]_store_gather(handle, tick)[/code].
func _commit(t: int) -> void:
	_gather_unfinished(store.commit(t), t)


func _commit_entities(t: int, handles: PackedInt64Array) -> void:
	if not handles.is_empty():
		_gather_unfinished(store.commit_entities(t, handles), t)


func _gather_unfinished(unfinished: PackedInt64Array, t: int) -> void:
	for handle in unfinished:
		var owner: Object = store.get_owner(handle)
		if owner and owner.has_method(&"_store_gather"):
			owner._store_gather(handle, t)


# The tripwire: the nodes at the start of a tick must hold what the last tick committed.
func _verify_store(last_tick: int) -> void:
	var differ: PackedInt64Array = store.verify_nodes(last_tick)
	if differ.is_empty():
		return
	store_mismatches += differ.size()
	var names: Array = []
	for handle in differ.slice(0, 5):
		var owner: Object = store.get_owner(handle)
		names.append(str(owner.get_parent().name) if owner is Node and owner.get_parent() else str(owner))
	push_warning("[TickDriver] %d entities changed outside a tick since tick %d (something wrote around the store): %s" % [differ.size(), last_tick, ", ".join(names)])


## Brings every body's collision up to date between two ticks of one frame. One body alone never collides with itself, so this only
## matters for two or more.
func _sync_collision_world() -> void:
	if _dirty:
		_rebuild_phases()
	if _syncing.size() < 2:
		return
	for p in _syncing:
		# Following entities don't move during simulation, and this runs when the machine is already behind, so a swarm mustn't add to it.
		if is_instance_valid(p) and not (p.has_method(&"is_following_server") and p.is_following_server()):
			p._sync_collision()


## Empties the timing record. See [member profile_enabled].
func reset_profile() -> void:
	profile = {"ticks": 0, "before_tick": 0, "input": 0, "capture": 0, "simulate": 0, "record": 0, "commit": 0, "after_tick": 0, "rollback": 0, "rollbacks": 0, "rollback_ticks": 0}


## True where gameplay outcomes are decided. Offline: always. Online: the server.
func is_authority() -> bool:
	if not is_inside_tree() or multiplayer == null or multiplayer.multiplayer_peer == null:
		return true
	if multiplayer.multiplayer_peer is OfflineMultiplayerPeer:
		return true
	return multiplayer.is_server()


# --- Internals ---------------------------------------------------------------------------------

func _run_tick(dt: float) -> void:
	var tick_started := Time.get_ticks_usec() # for the load ladder
	if _dirty:
		_rebuild_phases()
	if verify_store_each_tick:
		_verify_store(tick)
	tick += 1
	_in_tick = true
	var mark := Time.get_ticks_usec() if profile_enabled else 0
	before_tick.emit(dt, tick)
	mark = _profile_phase(&"before_tick", mark)
	_in_phases = true # rollback is refused from here until the phases end
	# A participant with a due_tick (a pawn on a load step) isn't called before it: pawns grouped by step (state store spec 9).
	for i in _input.size():
		var p = _input[i] # untyped: a freed one can't go in an Object variable, and is dropped below
		if not is_instance_valid(p):
			_dirty = true
		elif _input_due[i] == 1 and p.due_tick > tick:
			continue
		elif _removed_now.is_empty() or not _removed_now.has(p):
			p._tick_input(dt, tick)
	mark = _profile_phase(&"input", mark)
	# Inputs are saved here, after all of them are written and before simulate can consume them
	for p in _capture:
		if not is_instance_valid(p):
			_dirty = true
		elif _removed_now.is_empty() or not _removed_now.has(p):
			p._tick_capture_input(tick)
	mark = _profile_phase(&"capture", mark)
	_in_simulate = true
	for i in _simulate.size():
		var p = _simulate[i]
		if not is_instance_valid(p):
			_dirty = true
		elif _simulate_due[i] == 1 and p.due_tick > tick:
			continue
		elif _removed_now.is_empty() or not _removed_now.has(p):
			p._tick_simulate(dt, tick)
	_in_simulate = false
	after_simulate.emit(dt, tick) # queued effects, such as hits, are delivered here (pawn spec 15.1)
	mark = _profile_phase(&"simulate", mark)
	for p in _record:
		if not is_instance_valid(p):
			_dirty = true
		elif _removed_now.is_empty() or not _removed_now.has(p):
			p._tick_record(tick)
	mark = _profile_phase(&"record", mark)
	_commit(tick)
	mark = _profile_phase(&"commit", mark)
	# Cleared before after_tick, so the finished tick counts as finished for a rollback from that signal
	_in_phases = false
	_in_tick = false
	after_tick.emit(dt, tick)
	_profile_phase(&"after_tick", mark)
	if profile_enabled:
		profile["ticks"] += 1
	_removed_now.clear()
	_note_tick_cost(Time.get_ticks_usec() - tick_started, dt) # the load ladder


## The settings a start menu may offer before a match (MatchOptionsPanel.add_from_autoloads): the load ladder.
func get_match_options() -> PackedStringArray:
	return PackedStringArray(["load_ladder_enabled", "load_step_override"])


# The load ladder's rule, from one tick's cost in microseconds (pawn spec 8.21; see the README).
# REFACTOR: the ladder is a policy for shedding AI work, with its own tuning and match options, inside the universal tick driver. The
# driver could just report each tick's cost, and a GameMode module (beside AIActivationManager) own the rule (few autoloads).
func _note_tick_cost(microseconds: int, dt: float) -> void:
	var share := float(microseconds) / maxf(dt * 1000000.0, 1.0)
	load_average = lerpf(load_average, share, 0.1)
	if load_step_override > 0:
		_set_load_step(load_step_override)
		return
	if not load_ladder_enabled:
		_set_load_step(1)
		return
	# The ladder's prediction: once the average has settled after a step up, note what that step saved.
	if _measure_ticks_left > 0:
		_measure_ticks_left -= 1
		if _measure_ticks_left == 0 and load_step == _measuring_step:
			var saving := _load_before_raise - load_average
			if saving >= smallest_believable_saving:
				_saving_at[_measuring_step] = saving
			else:
				_saving_at.erase(_measuring_step) # not believable; assume the load doubles
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
		_set_load_step(load_step >> 1)


## True if the next step down looks safe now: load under [member lower_below], or the predicted load for the lower step (load now plus
## what this step saved, or twice the load if unknown) under [member raise_above] less [member step_down_headroom].
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


## Adds the time since mark to this phase, and returns the new mark.
func _profile_phase(phase: StringName, mark: int) -> int:
	if not profile_enabled:
		return 0
	var now := Time.get_ticks_usec()
	profile[phase] = int(profile.get(phase, 0)) + now - mark
	return now


## Sorts participants and splits them by the phase methods they have. Only runs when the registry changed. Also drops freed participants.
func _rebuild_phases() -> void:
	_dirty = false
	# One pass: entries unregistered since (id gone, or owned by a newer entry of the same object) and freed ones are dropped.
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
	_input_due.clear()
	_simulate_due.clear()
	_record.clear()
	_predicted.clear()
	_syncing.clear()
	for e in _entries:
		var o: Object = e.object
		var phases: int = e.phases
		var due := 1 if phases & _PHASE_DUE else 0
		if phases & _PHASE_INPUT:
			_input.append(o)
			_input_due.append(due)
		if phases & _PHASE_CAPTURE:
			_capture.append(o)
		if phases & _PHASE_PREDICTED:
			_predicted.append(o)
		if phases & _PHASE_SYNCING:
			_syncing.append(o)
		if phases & _PHASE_SIMULATE:
			_simulate.append(o)
			_simulate_due.append(due)
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


# Sets Godot's physics rate and catch-up limit to the driver's. Only the autoload (not a test's own driver), and only in the tree.
func _apply_physics_rate() -> void:
	if not (physics_follows_tick_rate and is_inside_tree() and get_parent() == get_tree().root):
		return
	if Engine.physics_ticks_per_second != _rate:
		Engine.physics_ticks_per_second = _rate
	# Godot's catch-up limit follows this one, so a frame never runs more ticks than max_ticks_per_frame (see there).
	Engine.max_physics_steps_per_frame = max_ticks_per_frame
