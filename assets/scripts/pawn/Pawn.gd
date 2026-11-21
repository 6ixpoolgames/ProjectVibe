# Written by Claude (claude-opus-5-5), 2026-11-07. History: pawn/CHANGELOG.md.
## A body something can possess, which runs its parts in a fixed order each tick.
##
## Its parts (managers, abilities, AI, its streaming source) are child nodes that PawnInitializer adds from the game's defaults
## ([member fill_in_default_parts], [member skip_default_parts]), and each tells the pawn it's there; the pawn keeps the body, the
## tick order, references to its parts and a few general flags. Use
## pawn.tscn as it is, or inherit from it. A controller writes its input each tick through its ControllerManager, and its abilities
## turn that into movement. Optional scene children: AbilityManager, TickStateComponent and NetworkEntity (rollback and multiplayer;
## the last two stay in the scene) and a Node3D called Visual.
## [br]
## Each tick: [b]input[/b] (the AI runs, then the ControllerManager asks the controller in charge, where input is decided here),
## [b]simulate[/b] (effects count down, abilities steer by writing [member velocity], gravity, then one move: its [member mover]'s if
## it takes it, else the pawn's own move_and_slide), then the state store records it. Hits resolve after every pawn has simulated. The
## body's rotation is never written (it slowly changed its scale and made replays collide differently; see TickSamplePawn): facing is
## [member yaw] and only the model turns. A child called Visual is drawn smoothly between ticks by a VisualSmoother. It also works
## without the tick driver (it ticks itself) and without a mover. Design: pawn spec 4, 15.1; state store spec 12.8.
class_name Pawn
extends CharacterBody3D

## Sent when this pawn's team changes, for the TeamRegistry (GameMode.team_registry), which keeps the counts.
signal team_changed(pawn: Pawn, old_team: int, new_team: int)

## On, GameMode's PawnInitializer adds every default part this pawn's scene doesn't already have. Off, the pawn gets only what its
## scene has.
@export var fill_in_default_parts := true
## How strongly it falls, in metres per second per second. Below 0, the project's gravity setting. The pawn adds gravity; abilities
## only steer.
@export var gravity := -1.0
## Default parts to leave out, by name, such as &"AbilityManager". A part with that name in the scene is kept either way.
@export var skip_default_parts: Array[StringName] = []
## Which side this pawn is on. AI sensing only notices pawns of other teams (pawn spec 10.4). A player who possesses a pawn plays for
## its team. Recorded in the state store, pushed when it changes.
@export var team := 0:
	set(value):
		if team == value:
			return
		var old_team := team
		team = value
		if _tick_state:
			_tick_state.push_value("team", value)
		team_changed.emit(self, old_team, value) # the TeamRegistry module keeps the counts
## On: a pawn standing still with nothing to do sleeps, skipping its abilities, gravity and move_and_slide until something wakes it
## (pawn spec 15.3). Off: it simulates fully every tick.
@export var sleep_when_idle := true
## A sleeping pawn still runs a full tick this often, staggered by entity id, so ground that went away under it is noticed. 15 ticks
## is a quarter of a second at 60 ticks a second.
@export_range(1, 600, 1, "or_greater") var sleep_check_ticks := 15
## On (the default): a pawn awake only for its timers, grounded and not moving, skips move_and_slide, but still moves on its check
## ticks ([member sleep_check_ticks]) so ground taken from under it is noticed. Off: it always moves. Counted in diagnostics as
## pawn.move_skipped.
@export var skip_move_when_still := true
## On (the default): its [member mover] may take its moves (the CrowdMover moves AI pawns walking on the ground with the crowd, pawn
## spec 8.22). Off: it always moves itself, with move_and_slide.
@export var crowd_movement := true
## What moves this pawn instead of its own move_and_slide, on the ticks it takes the move ([code]take_move(pawn, was_grounded, seconds)[/code],
## then [method finish_move] or [method move_by_physics_now]): the game's CrowdMover, set by the PawnInitializer, or null, and the
## pawn moves itself every tick.
var mover: Object = null
## On (the default): after a rollback restores this pawn, a zero-length move_and_slide rebuilds Godot's own "on the floor" flag, which
## the first replayed tick's floor snap reads. Off: it's left as it was, which saves a physics solve per restored pawn but can make
## that first replayed tick differ. Only clients roll back, and by default only their own pawn.
@export var rebuild_floor_on_rollback := true
## Whether this pawn slept on its last tick, for readouts and tests. Worked out again every tick from its state, so it isn't rollback
## state. Setting it changes nothing.
var is_sleeping := false

## Which way the pawn faces, in radians. The body never turns; only the model does.
var yaw := 0.0
## Our own copy of "on the floor", because rollback has to restore it, and is_on_floor() can't be set.
var grounded := false
## The tick it last moved instantly ([method teleport]), or -1. The MoveSanityCheck lets that move through.
var last_teleport_tick := -1
var _body_radius := -1.0 # the capsule's radius, found once (get_body_radius)
var _body_shape: CollisionShape3D = null # the collision shape, found once (get_body_shape)
var _tick_state: TickStateComponent = null # its part in the state store, if it has one: pushes, marks, rounding crowd moves

## Runs this pawn's abilities, which steer it. Null if it has none.
var ability_manager: AbilityManager = null
## This pawn's stats, which abilities read. Null if it has none, and then abilities use their fallbacks.
var stat_manager: StatManager = null
## Applies effects to this pawn and keeps the over-time ones (pawn spec 8.11). Null if it has none, and then hits and effects do
## nothing to it.
var effect_manager: EffectManager = null
## Picks whose input this pawn follows, and holds that input. Null if the pawn has none, and then nothing writes its input for it.
var controller_manager: ControllerManager = null
## Finds paths and says which way to walk, for click-to-move and the AI. Null if the pawn has none.
var navigation_manager: NavigationManager = null
## Shared data and settings for this pawn's AI (pawn spec 10), and the AI's core. Null if the pawn has no AI.
var ai_context: AIContextComponent = null
## Keeps the world loaded around this pawn while a player has it (or always, with its keeps_world_loaded on). Null if it has none,
## and then it never does.
var streaming_source: PawnStreamingSource = null
# Each of these parts sets its reference when it enters the tree, so on a pawn that's been made but not yet added they're all null
# (and default parts don't exist yet): set things on its parts after add_child. The other AI parts (state manager, behaviour manager, sensing,
# memory, target selector) are found by the AI's core, ai_context, not by the pawn: pawn.ai_context.memory and so on.


var _driver: Node = null
## True while the Death ability runs, the same as is_dead(). Kept current by DeathAbility (through its timer, so a rollback updates
## it too), and read directly by C++, which is much cheaper than calling is_dead(). Read it; don't set it.
var dead := false
## How often this pawn simulates: every tick (1), 2nd (2) or 4th (4), spread by its own number. Rolls back (pushed to the state
## store when it changes). AIActivationManager raises it for far-away AI pawns; a player's pawn always runs every tick. Each run does N
## ticks' worth ([member ticks_elapsed]). Pawn spec 8.21.
var tick_step := 1:
	set(value):
		if tick_step == value:
			return
		tick_step = value
		if _tick_state:
			_tick_state.push_value("tick_step", value)
		due_tick = 0 # when it next runs changes
## The ticks since this pawn last ran, 1 to [constant MAX_TICK_STEP]. Its parts advance their timers by it (cooldowns, effects, AI
## schedules) and its simulate step is this many ticks long. Read it; don't set it.
var ticks_elapsed := 1
## The first tick this pawn may run on: the tick driver doesn't call it before then, so a pawn on every 4th tick isn't called on the
## three it skips. Worked out after each run; whatever changes when it runs (its step, a player taking it, a rollback) sets it to 0,
## which means "ask it every tick". Read it; don't set it.
var due_tick := 0
## The longest step, and so the most ticks one run can cover. A pawn frozen for a while comes back with at most this.
const MAX_TICK_STEP := 4
## The Godot group every pawn is in while it's in the tree: the one list of "all pawns" (crowd mover, kill floor, team registry,
## diagnostics, replay).
const GROUP := &"pawns"
var _last_run_tick := -1 # the tick this pawn last simulated; rolls back. -1: not yet
var _prepared_tick := -1 # the tick _runs_this_tick and ticks_elapsed were worked out for
var _runs_this_tick := true
var _next_due_tick := 0 # when this tick's run is followed by the next, for due_tick
var _entity: NetworkEntity = null
var _visual: Node3D = null
var _smoother: VisualSmoother = null # draws Visual between ticks; null without a Visual
var _moved_since_run := false # teleported since its last run began: no sleeping and no skipped move until it has run again
var _fallback_tick := 0
var _frozen := false


func _init() -> void:
	floor_snap_length = 0.3
	floor_max_angle = deg_to_rad(50.0)
	# Godot's default margin is exactly 1 mm, and TickState rounds positions to exact 1 mm steps. That parks a standing body on
	# the edge of "touching the floor", so float noise flips the contact. A margin between two steps avoids it.
	safe_margin = 0.0014


func _enter_tree() -> void:
	add_to_group(GROUP) # the list of all pawns
	add_to_group(TerrainBodyLifter.GROUP)
	SharedPawnTable.join(self) # the shared table of plain pawn data, which AI sensing's grid reads (C++ only; scaling spec step 1)
	if CrowdMover.current:
		CrowdMover.current.add_pawn(self) # every pawn: the crowd keeps clear of it
	# Its two general parts, which any entity may have, so they don't know about pawns: found here, before its other parts enter.
	for child in get_children():
		if child is NetworkEntity:
			_entity = child
		elif child is TickStateComponent and _tick_state == null:
			_tick_state = child
	# Default parts next, so they're children before anything below or any _ready looks for them. A node may add children to itself
	# here: Godot enters them right after, and each pawn part sets its reference on the pawn as it enters.
	var game_mode: Node = get_node_or_null("/root/GameMode")
	if game_mode and game_mode.pawn_initializer:
		game_mode.pawn_initializer.initialize(self)
	_driver = get_node_or_null("/root/TickDriver")
	if _driver:
		_driver.register(self)
	# A pawn coming back into the tree (taken out and put back, or moved under another parent) joins the AI switch-off again.
	# _exit_tree takes it off that list, and _ready, which adds it the first time, only ever runs once.
	# is_node_ready() is false the first time a node enters the tree, and true every time after.
	if is_node_ready():
		var ai := _ai_activation_manager()
		if ai:
			ai.add_pawn(self)


func _exit_tree() -> void:
	SharedPawnTable.leave(self)
	if CrowdMover.current:
		CrowdMover.current.remove_pawn(self)
	# This first, because leaving the list can switch the pawn back on, which would register it again.
	var ai := _ai_activation_manager()
	if ai:
		ai.remove_pawn(self)
	if _driver:
		_driver.unregister(self)


func _ready() -> void:
	set_physics_process(_driver == null) # the driver calls us. Godot turns this on at ready for any script that defines it
	yaw = rotation.y # whatever the scene placed it at. From here on, the body itself stays unrotated
	rotation = Vector3.ZERO
	_visual = get_node_or_null(^"Visual")
	if _visual:
		_smoother = VisualSmoother.new()
		_smoother.name = "VisualSmoother"
		add_child(_smoother)
		_smoother.setup(self, _visual)
	# How often it runs and when it last did roll back, so a replay runs on the same ticks (pawn spec 8.21); its team and step are
	# pushed when they change. It's recorded only when it runs or something marks it (mark_state_changed), so a pawn on a load step
	# costs the store almost nothing on the ticks it skips.
	if _tick_state:
		var entries: Array[String] = ["tick_step pushed", "team pushed", "_last_run_tick"]
		_tick_state.add_state_properties(entries)
		_tick_state.record_only_when_changed = true
	# Every pawn is watched by the AI switch-off, which leaves alone those that keep the world loaded, checking each time.
	var ai := _ai_activation_manager()
	if ai:
		ai.add_pawn(self)
	# A player's pawn runs every tick, so a player taking it changes when it next runs. unbind(2) drops the signal's arguments.
	if controller_manager:
		controller_manager.possession_changed.connect(_forget_due_tick.unbind(2))


# --- Things other scripts can call ---


## True while this pawn keeps the world loaded around it on this machine: its [member streaming_source] counts (a player has it, or
## its keeps_world_loaded is on, and it's simulated here). The AI switch-off leaves such a pawn on.
func is_keeping_world_loaded() -> bool:
	return streaming_source != null and streaming_source.counts_on_this_machine()


## The node that follows the body smoothly, for hanging things from. With no Visual, it's the body.
func get_visual() -> Node3D:
	return _visual if _visual else self


## Freezes or unfreezes the pawn: frozen, it doesn't tick at all, and everything about it stays as it is. AIActivationManager calls
## this where no ground is loaded around an AI pawn (pawn spec 15.3, "frozen").
# Through the NetworkEntity, because it decides what ticks: stopping only the pawn would leave its entity and TickState running.
func set_frozen(frozen: bool) -> void:
	if _frozen == frozen:
		return
	_frozen = frozen
	if _driver == null:
		set_physics_process(not frozen)
	elif _entity:
		_entity.set_paused(frozen)
	elif frozen:
		_driver.unregister(self)
	else:
		_driver.register(self)


## True while frozen.
func is_frozen() -> bool:
	return _frozen


## True where this pawn's AI runs: offline, or on the server. The AI never runs on a client (pawn spec 10.2).
func runs_ai_here() -> bool:
	return is_authority()


## True where this pawn's state is decided: offline, or on the server. Hits are decided here.
func is_authority() -> bool:
	return _entity == null or _entity.role == NetworkEntity.Role.AUTHORITY


## True while this pawn's Death ability runs: from Health reaching 0 until it's revived (AbilityManager.revive). A pawn with no
## Death ability never dies. Returns [member dead], which the Death ability keeps current.
func is_dead() -> bool:
	return dead


## Something changed this pawn between its own runs (an effect landed on it), so the state store reads it at the next commit
## instead of copying its last row forward. Its runs mark it themselves.
func mark_state_changed() -> void:
	if _tick_state:
		_tick_state.mark_changed()


## Moves this pawn instantly instead of through the space between, for a respawn, a blink or a debug move. Use it for any such move,
## so the crowd mover reads it from its node this tick, its Visual is drawn there at once instead of gliding, the state store records
## it even on a tick it doesn't run or after the crowd wrote its move, and the MoveSanityCheck lets the jump through. Its velocity and
## yaw stay as they are.
func teleport(to: Vector3) -> void:
	global_position = to
	if _tick_state:
		position = _tick_state.round_position(position) # as the recording rounds it, so the store and the node agree
		_tick_state.mark_changed()
	last_teleport_tick = TickDriver.tick
	_moved_since_run = true
	if CrowdMover.current:
		CrowdMover.current.note_moved(self)
	if _smoother:
		_smoother.snap()


## This pawn's NetworkEntity, or null when it isn't networked. Its entity_id is the same on every machine.
func get_network_entity() -> NetworkEntity:
	return _entity


# --- Ticks ---


## The input phase: runs the AI, then asks the controller in charge for this tick's input, where this pawn's input is decided here.
## A script that writes input itself, such as a test brain, can still do so later in the same phase and win.
func _tick_input(_dt: float, tick: int) -> void:
	# A pawn that runs every Nth tick skips the others: no AI, no input (pawn spec 8.21).
	_prepare_run(tick)
	if not _runs_this_tick:
		return
	if is_dead():
		if controller_manager:
			controller_manager.clear_input() # a dead pawn ignores its controllers and its AI
		return
	# The AI first (step 1 of pawn spec section 4), before the controller in charge is asked for input. Its ordered step is in its
	# core part, AIContextComponent.run_ai.
	if ai_context:
		var ai_started := PerfScopes.begin() # timed for diagnostics (PerfScopes)
		ai_context.run_ai(tick)
		PerfScopes.end(&"ai", ai_started)
	# The ControllerManager asks the controller in charge and writes the input, where it's decided here.
	if controller_manager:
		var input_started := PerfScopes.begin()
		controller_manager.tick_input(tick)
		PerfScopes.end(&"pawn.input", input_started)


func _tick_simulate(dt: float, tick: int) -> void:
	# Skipped on ticks it doesn't run; on those it does, a step as long as the ticks since its last (pawn spec 8.21). A rollback
	# replay calls only this, not _tick_input, so it works out the same thing here.
	_prepare_run(tick)
	if not _runs_this_tick:
		return
	dt *= ticks_elapsed
	_last_run_tick = tick
	# The driver needn't call it again before its next run (worked out in _prepare_run). Set here in simulate, not in _prepare_run:
	# input runs _prepare_run first, and a due_tick set there would make the driver skip this same tick's simulate.
	due_tick = _next_due_tick
	# Teleported since its last run: it stays awake for this one. A teleport during this run sets it again, for the next.
	var was_moved := _moved_since_run
	_moved_since_run = false
	# Sleeping (pawn spec 15.3). A sleeping pawn only does the bookkeeping at the end.
	var sleeping := not was_moved and _can_sleep(tick)
	is_sleeping = sleeping
	if sleeping:
		_finish_input()
		_finish_tick()
		return
	# Abilities steer, then gravity, then one move_and_slide. Gravity goes by whether it was on the ground when the tick began, so a
	# jump that starts this tick isn't pulled down in the same tick.
	var was_grounded := grounded
	# Over-time effects count down first, so this tick's abilities see this tick's slows and boosts (pawn spec 8.11).
	var abilities_started := PerfScopes.begin()
	if effect_manager:
		effect_manager.tick_effects()
	if ability_manager:
		ability_manager.tick_abilities(dt)
	PerfScopes.end(&"pawn.abilities", abilities_started)
	_finish_input() # the abilities were the last to read this tick's input
	if not was_grounded:
		velocity.y -= _gravity_strength() * dt
	# move_and_slide uses Godot's physics delta. This scales it so that one tick moves velocity * tick dt.
	# Standing still with nothing to move it: skip the solve (see skip_move_when_still).
	if skip_move_when_still and was_grounded and velocity == Vector3.ZERO and not was_moved and not _moved_since_run and not _is_check_tick(tick):
		PerfScopes.add(&"pawn.move_skipped", 0)
		_finish_tick()
		return
	# Its mover (the CrowdMover) may take this move: it moves the whole crowd once every pawn has simulated, then finishes this tick
	# for it (finish_move or move_by_physics_now). dt is this run's length (pawn spec 8.22).
	if mover and crowd_movement and mover.take_move(self, was_grounded, dt):
		return
	_move_with_physics() # a mover's fallback runs it too
	_finish_tick() # a sleeping tick runs it too


# One move by physics: move_and_slide with this run's velocity, then whether it's on the floor.
func _move_with_physics() -> void:
	# Times ticks_elapsed, so a pawn running every Nth tick moves N ticks' worth.
	var factor: float = (_driver.get_physics_factor() if _driver else 1.0) * ticks_elapsed
	velocity *= factor
	var move_started := PerfScopes.begin()
	move_and_slide()
	PerfScopes.end(&"pawn.move_and_slide", move_started)
	if CrowdMover.current:
		CrowdMover.current.note_moved(self) # the store's last frame has it a tick behind now
	velocity /= factor
	grounded = is_on_floor()


## Its mover moved this pawn to at, over seconds: it stands there on the ground, its velocity is what it really moved (as
## move_and_slide leaves it), and its tick finishes (pawn spec 8.22). The position is rounded as the state store will round it
## (TickStateComponent.round_position), so the commit changes nothing afterwards and a still pawn is exactly still, and sleeps.
func finish_move(at: Vector3, seconds: float) -> void: # public, since its mover calls it
	# The velocity from the real move, before rounding, as move_and_slide leaves it: from the rounded one it would wobble by up to a
	# millimetre a tick, 0.06 m/s at 60 ticks a second.
	var moved := at - global_position
	velocity = Vector3(moved.x, 0.0, moved.z) / seconds if seconds > 0.0 else Vector3.ZERO
	global_position = at
	if _tick_state:
		position = _tick_state.round_position(position) # its own position, as the recording rounds it, not the world one
	grounded = true
	_finish_tick()


## Its mover couldn't move this pawn (a wall, an edge, no ground under where it was going), so it moves by physics now, in the same
## tick, which handles those, and finishes its tick. Its velocity is still this run's.
func move_by_physics_now() -> void: # public, since its mover calls it
	_move_with_physics()
	_finish_tick()


## Its Visual's slot in the [VisualPlacer] (VisualSmoother.slot), or -1 without a Visual. The crowd mover tells the placer about its
## pawns' runs by slot, all at once.
func get_visual_slot() -> int:
	return _smoother.slot if _smoother else -1


## Its handle in the state store (TickStateComponent.get_store_handle), or -1 without one.
func get_store_handle() -> int:
	return _tick_state.get_store_handle() if _tick_state else -1


## How wide this pawn's body is: its collision capsule's (or sphere's, or cylinder's) radius, scaled, in metres. 0.4 without one.
## Found once.
func get_body_radius() -> float:
	if _body_radius < 0.0:
		_body_radius = 0.4
		var body := get_body_shape()
		if body and (body.shape is CapsuleShape3D or body.shape is SphereShape3D or body.shape is CylinderShape3D):
			_body_radius = float(body.shape.get(&"radius")) * absf(body.global_basis.get_scale().x)
	return _body_radius


## This pawn's collision shape node (its first CollisionShape3D child with a shape), or null. The CrowdMover sweeps it along a move
## to find walls. Found once.
func get_body_shape() -> CollisionShape3D:
	if _body_shape == null or not is_instance_valid(_body_shape):
		_body_shape = null
		for child in get_children():
			var shape := child as CollisionShape3D
			if shape and shape.shape:
				_body_shape = shape
				break
	return _body_shape


# The end of a run the pawn finishes itself, sleeping or not: its Visual glides to where the body is now. The crowd mover does this
# for the pawns it moves, all at once (VisualPlacer.note_runs).
func _finish_tick() -> void:
	if _smoother:
		_smoother.note_run(ticks_elapsed, _last_run_tick)


# Once its abilities have read this tick's input: the ControllerManager's bookkeeping (what was held, so the next tick can tell a press
# from a hold, and whether input went missing). Before the move, so the crowd mover needn't call each pawn back for it.
func _finish_input() -> void:
	if controller_manager:
		controller_manager.finish_tick()


## True if this pawn sleeps this tick (pawn spec 15.3); not the same as frozen or paused. A rule of its state and the tick number
## only, so nothing extra rolls back and server and client sleep on the same ticks. It sleeps when sleep_when_idle is on, it's grounded
## and still, it isn't a check tick, and no effect or ability timer is running; its run also keeps it awake after a teleport.
func _can_sleep(tick: int) -> bool:
	if not sleep_when_idle or not grounded or velocity != Vector3.ZERO:
		return false
	if controller_manager and (controller_manager.move_input != Vector3.ZERO or controller_manager.held_actions != 0):
		return false
	if _is_check_tick(tick): # shared with skip_move_when_still
		return false
	if effect_manager and not effect_manager.can_sleep():
		return false
	return ability_manager == null or ability_manager.can_sleep()


# One of this pawn's check ticks, every sleep_check_ticks, staggered by entity id, when a sleeping or still pawn runs a full tick
# anyway so ground that went away under it is noticed.
func _is_check_tick(tick: int) -> bool:
	var stagger: int = _entity.entity_id if _entity and _entity.entity_id >= 0 else get_instance_id()
	# "< ticks_elapsed" rather than "== 0", so a pawn running every Nth tick still finds the check tick that fell between its runs.
	# sleep_check_ticks is written for 60 ticks a second (scaling spec step 6).
	return posmod(tick + stagger, TickDriver.ticks_at_rate(sleep_check_ticks)) < ticks_elapsed


## True if a rule that fires every interval ticks, on the ticks where (tick + offset) is a multiple of interval, fired on this tick
## or on one this pawn skipped since its last run. For the AI's schedules and the like, so a pawn that runs every Nth tick keeps them
## (pawn spec 8.21). With ticks_elapsed 1, it's (tick + offset) % interval == 0.
func fired_since_last_run(tick: int, offset: int, interval: int) -> bool:
	return fires_in_run(tick, ticks_elapsed, offset, interval)


## The same rule for any run: true if a rule that fires every interval ticks (where (tick + offset) is a multiple of interval) fires
## on run_tick or on one of the run_length - 1 ticks before it. AISensingManager asks it about a pawn's next run, before that run
## happens, so both use one rule.
static func fires_in_run(run_tick: int, run_length: int, offset: int, interval: int) -> bool:
	return interval <= 1 or posmod(run_tick + offset, interval) < run_length


## The tick this pawn will next run after tick, if its step doesn't change before then. The same rule as _prepare_run, looking ahead
## from a tick it ran on: the first later tick that lines up with its step, or a whole step on. AISensingManager uses it to ask the
## worker-thread sensing job in time for a stepping pawn's next run.
func next_run_tick(tick: int) -> int:
	var step := _current_step()
	if step <= 1:
		return tick + 1
	# How many ticks until (tick + ahead + stagger) is a multiple of step; none within the step (ahead 0) means a whole step on, when
	# "a whole step has passed" makes it run.
	var ahead := posmod(-(tick + _stagger()), step)
	return tick + (ahead if ahead > 0 else step)


# The step this pawn runs at now, and the number that spreads a crowd's runs over the ticks. Shared by _prepare_run and
# next_run_tick, so both use the same rule.
func _current_step() -> int:
	return 1 if _has_a_player() else clampi(tick_step, 1, MAX_TICK_STEP)


func _stagger() -> int:
	return _entity.entity_id if _entity and _entity.entity_id >= 0 else get_instance_id()


## True while it runs every tick: tick_step 1, or a player has it.
func runs_every_tick() -> bool:
	return tick_step <= 1 or _has_a_player()


# Works out, once per tick, whether this pawn runs this tick and how many ticks the run covers (pawn spec 8.21). Due when its step is
# 1, when it's never run, when the tick lines up with its step (spread by its own number), or when a whole step has passed since its
# last run (after its step changed). ticks_elapsed is the ticks since its last run, from 1 to MAX_TICK_STEP.
func _prepare_run(tick: int) -> void:
	if _prepared_tick == tick:
		return
	_prepared_tick = tick
	var step := _current_step()
	if step <= 1 or _last_run_tick < 0:
		_runs_this_tick = true
	else:
		var since := tick - _last_run_tick
		_runs_this_tick = since >= step or (since > 0 and posmod(tick + _stagger(), step) == 0)
	if _runs_this_tick: # on ticks it skips, ticks_elapsed keeps its last run's value
		ticks_elapsed = clampi(tick - _last_run_tick, 1, MAX_TICK_STEP) if _last_run_tick >= 0 else 1
		mark_state_changed() # a run changes it, so the store reads it this tick
		# next_run_tick's rule, from what's at hand: the next tick that lines up with its step, or a whole step on.
		_next_due_tick = tick + 1 if step <= 1 else tick + step - posmod(tick + _stagger(), step)


# Something that decides when it runs changed (a player took it or let go), so the driver asks it every tick until its next run.
func _forget_due_tick() -> void:
	due_tick = 0


## TickState restored our properties, but CharacterBody3D also keeps a private "on floor" flag that still holds what the body is
## doing now. Nothing can set it directly, so this makes the engine work it out again, then puts things back.
func _on_state_loaded(_tick: int) -> void:
	_prepared_tick = -1 # worked out again from the loaded _last_run_tick
	due_tick = 0
	if ability_manager:
		ability_manager.state_loaded()
	# The ControllerManager's previous_held_actions is restored by the TickState itself, as rollback state.
	var saved_position := position
	var saved_velocity := velocity
	if rebuild_floor_on_rollback: # see rebuild_floor_on_rollback
		var saved_snap := floor_snap_length
		floor_snap_length = 0.0
		velocity = Vector3.ZERO
		var rebuild_started := PerfScopes.begin()
		move_and_slide()
		PerfScopes.end(&"pawn.rollback_floor_rebuild", rebuild_started)
		floor_snap_length = saved_snap
		if grounded and not is_on_floor():
			apply_floor_snap()
	position = saved_position
	velocity = saved_velocity
	_moved_since_run = false # it stands where the loaded run left it
	if _smoother:
		_smoother.snap()


func _physics_process(delta: float) -> void:
	_fallback_tick += 1
	_tick_input(delta, _fallback_tick)
	_tick_simulate(delta, _fallback_tick)


# --- Multiplayer: optional hooks from NetworkEntity ---


## Works for a role that changes while running, as swapping pawns does.
func _on_network_role(entity: NetworkEntity) -> void:
	_entity = entity


## On a client, for a pawn someone else controls: it was just moved between snapshots, so Visual follows.
func _on_network_interpolated() -> void:
	if _smoother:
		_smoother.note_moved()


## On a client: a correction moved our body by this much.
func _on_network_corrected(jump: Variant) -> void:
	if jump is Vector3 and _smoother:
		_smoother.add_correction(jump)


# --- Helpers ---


## Gravity in metres per second per second, from the gravity setting or else the project's.
func _gravity_strength() -> float:
	if gravity >= 0.0:
		return gravity
	return ProjectSettings.get_setting("physics/3d/default_gravity", 9.8)


## False for a pawn on a client that belongs to someone else. Whose input this is, is the ControllerManager's question
## (ControllerManager.decides_own_input).
func is_simulated_here() -> bool:
	return _entity == null or _entity.is_local or _entity.role == NetworkEntity.Role.AUTHORITY


# True while a player has this pawn (asked of its ControllerManager; a pawn without one never has a player).
func _has_a_player() -> bool:
	return controller_manager != null and controller_manager.has_player()


func _ai_activation_manager() -> AIActivationManager:
	var game_mode: Node = get_node_or_null("/root/GameMode") if is_inside_tree() else null
	return game_mode.ai_activation_manager if game_mode else null
