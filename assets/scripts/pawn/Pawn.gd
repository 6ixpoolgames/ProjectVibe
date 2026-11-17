# Written by Claude (claude-opus-5-5), 2026-11-07. History: pawn/CHANGELOG.md.
## The tier -1 pawn: a body something can possess, which runs its parts in a fixed order each tick.
##
## Its parts (managers, abilities, AI) are child nodes that PawnInitializer adds from the game's defaults; there is no nexus. The
## pawn keeps the body, its tick order, references to its parts and a few general flags. Specs: docs/pawn/PAWN_SPEC.md and
## docs/pawn/PLAYER_AND_CAMERA.md.
## [br]
## How to use it: use assets/scenes/pawn/pawn.tscn as it is, or inherit from it. A controller writes this pawn's input each tick,
## through its ControllerManager: a PlayerController, or its AIController. Its abilities make that into movement.
## [br]
## [b]Parts and the tick[/b] (pawn spec sections 4 and 15.1):
## [br]- When it enters the tree, GameMode's PawnInitializer adds the default parts its scene doesn't have: ControllerManager (with an
##   AIController), NavigationManager, StatManager, EffectManager, AbilityManager (with Walk, Jump and Sprint) and the AI's parts
##   (AIContextComponent and the rest). [member fill_in_default_parts] and [member skip_default_parts] opt out.
## [br]- Each tick, in its input phase, it first runs its AI (AIContextComponent.run_ai, offline or on the server only; pawn spec
##   section 10), then its ControllerManager asks whoever is in charge for input: this machine's player, or else its AI controller.
##   That happens only where its input is decided here. A client's pawn on the server gets its input over the network instead.
## [br]- Each tick, in its simulate phase, its EffectManager counts down over-time effects and its AbilityManager runs the abilities,
##   which write velocity and facing. Then the pawn adds gravity and makes the one move_and_slide call, or hands the move to the
##   CrowdMover (pawn spec 8.22).
## [br]
## What it needs in its scene, all optional:
## [br]- an AbilityManager child. With none, nothing steers it, and it only falls. It comes from PawnInitializer by default.
## [br]- a TickStateComponent and a NetworkEntity child, for rollback and multiplayer. With none, it plays as single player. These
##   two stay in the scene, because NetworkSession reads them before the pawn joins the tree.
## [br]- a Node3D child called Visual, which the camera and the model hang from.
## [br]
## pawn.tscn puts bodies on collision layer 2, and they collide with layers 1 and 2. The ground is on layer 1, so a camera arm can
## tell the ground from a pawn walking past.
## [br]
## Why the body's rotation is never written: writing rotation every tick slowly changed the body's scale through rounding, which
## made collision differ in a replay (see TickSamplePawn). So facing is a plain number, [member yaw], and only the model turns.
## [br]
## Why Visual exists: the body moves in ticks and gets corrected, and looks jerky if you watch it directly. Visual follows it
## smoothly per rendered frame, and hides corrections by fading them out. Anything on screen hangs from it.
## [br]
## Where things that used to be here live now: input, presses and whether a player has the pawn are on its ControllerManager
## (pawn.controller_manager.move_input, .has_player(), .possessable); hits, death and their signals on its AbilityManager
## (pawn.ability_manager.died); camera pieces on CameraMount (CameraMount.arm_of(pawn)); team counts in GameMode's TeamRegistry;
## Health on its StatManager (pawn.stat_manager.get_health()).
## [br]
## What happens in odd cases (all checked in tests/pawn_selftest.gd):
## [br]- No TickDriver: it ticks itself from _physics_process.
## [br]- AI pawn in unloaded ground: AIActivationManager freezes it ([method set_frozen]), and it keeps all its state.
## [br]- On the server, a client's input goes missing: see ControllerManager's [code]_network_input_missing[/code].
class_name Pawn
extends CharacterBody3D

## Sent when this pawn's team changes, for the TeamRegistry (GameMode.team_registry), which keeps the counts.
signal team_changed(pawn: Pawn, old_team: int, new_team: int)

## On: this pawn keeps the world loaded around it even without a player, as a player's pawn always does: a hero, say. Off, it's
## frozen wherever nothing else keeps the ground loaded, which is what you want for a horde.
## [br]
## Only a flag: the pawn makes no StreamingSource node. The chunk streamer, the nav feeder and the AI switch-off read it whenever they
## look ([method counts_on_this_machine]), so changing it needs nothing told. Setting it also puts the pawn in or out of the sources'
## group. How far it loads is the game's setting (PawnDefaultsRes.world_load_distance), not the pawn's.
@export var keeps_world_loaded := false:
	set(value):
		keeps_world_loaded = value
		_update_source_group()
# REFACTOR: the streaming source contract (load_distance, nav_distance, distance_moved_since_last_check, the sources' group) is
# streaming's business kept on the pawn (pawn slimming: source). Pawn M2 chose a flag here; a small part or the streamer's own
# bookkeeping would slim the pawn. The owner's call. See CHANGELOG.md.
## How far this pawn keeps the world loaded when it does, in metres: the game's setting (PawnDefaultsRes, read through GameMode's
## PawnInitializer), 320 without one. Read-only. Named as a StreamingSource's is, because the chunk streamer reads both the same way
## (StreamingSource.gd, "the source contract").
var load_distance: float:
	get:
		var defaults: PawnDefaultsRes = _pawn_defaults()
		return defaults.world_load_distance if defaults else 320.0
## How far nav is built around it, in metres: the game's setting, 128 without one. Read-only.
var nav_distance: float:
	get:
		var defaults: PawnDefaultsRes = _pawn_defaults()
		return defaults.world_nav_distance if defaults else 128.0
## On, GameMode's PawnInitializer adds every default part this pawn's scene doesn't already have. Off, the pawn gets only what its
## scene has.
@export var fill_in_default_parts := true
## How strongly it falls, in metres per second per second. Below 0, the project's gravity setting. The pawn adds gravity; abilities
## only steer.
@export var gravity := -1.0
## Default parts to leave out, by name, such as &"AbilityManager". A part with that name in the scene is kept either way.
@export var skip_default_parts: Array[StringName] = []
## Which side this pawn is on. AI sensing only notices pawns of other teams (pawn spec 10.4). A player who possesses a pawn plays for
## its team.
@export var team := 0:
	set(value):
		if team == value:
			return
		var old_team := team
		team = value
		team_changed.emit(self, old_team, value) # the TeamRegistry module keeps the counts
# REFACTOR: detectability is a pass-through to a stat, kept for pawns without one (pawn slimming M6). Callers could read the stat,
# and the pawn table could take a default, so this leaves the pawn. See CHANGELOG.md.
## How easy this pawn is for AI to see: 1 is normal, lower is harder, 0 is invisible. Sight multiplies its fill rate by this (pawn
## spec 10.4).
## [br]
## It reads and writes the Detectability stat in the pawn's StatManager (StatManager.DETECTABILITY, in the default stats), so effects
## can change it (a stealth buff, say) and it's mirrored into the pawn table for the sensing job. Set its base value on the stat in a
## pawn scene; it isn't in the inspector here, so there's one place to set it. A pawn without the stat keeps its own number. Nothing
## in the base changes it: how stealth, gear or light level turn into this number is a game rule, for a GameMode module to set.
var detectability: float:
	get:
		var stat := _detectability_stat()
		return stat.value if stat else _own_detectability
	set(new_value):
		var stat := _detectability_stat()
		if stat:
			stat.base_value = new_value # the stat copies it into the pawn table itself
		else:
			_own_detectability = new_value
			var table := get_table()
			if table and is_inside_tree():
				table.set_value(self, &"detectability", new_value)
var _own_detectability := 1.0 # detectability, for a pawn without the stat
## On: a pawn standing still with nothing to do sleeps, skipping its abilities, gravity and move_and_slide until something wakes it
## (pawn spec 15.3). Off: it simulates fully every tick.
@export var sleep_when_idle := true
## A sleeping pawn still runs a full tick this often, staggered by entity id, so ground that went away under it is noticed. 15 ticks
## is a quarter of a second at 60 ticks a second.
@export_range(1, 600, 1, "or_greater") var sleep_check_ticks := 15
## On (the default): a pawn awake for its timers (an effect or ability counting down) but not moving skips move_and_slide, when it's
## grounded, has no velocity after its abilities and gravity, and nothing moved it since its last tick. It still moves for real on its
## check ticks ([member sleep_check_ticks]), so ground taken from under it is noticed, as for a sleeping pawn. Off: it always moves.
## Skipped moves are counted in diagnostics as pawn.move_skipped. In the mass battle it skipped 24 to 31 moves a frame at the first
## clash (about 0.2 ms), and nothing while marching, when everyone moves.
@export var skip_move_when_still := true
## On (the default): while an AI drives this pawn on the server or offline and it walks on the ground, the GameMode's CrowdMover moves
## it with the rest of the crowd instead of move_and_slide (much cheaper; AI pawns are kept apart by separation rather than by
## colliding). A player's pawn, one in the air, one on a client, or one running an ability with needs_full_movement always moves by
## physics. Off: this pawn always moves by physics (pawn spec 8.22).
@export var crowd_movement := true
## On (the default): after a rollback restores this pawn, a zero-length move_and_slide rebuilds Godot's own "on the floor" flag, which
## the first replayed tick's floor snap reads. Off: it's left as it was, which saves a physics solve per restored pawn but can make
## that first replayed tick differ. Only clients roll back, and by default only their own pawn.
@export var rebuild_floor_on_rollback := true
## Whether this pawn slept on its last tick, for readouts and tests. Worked out again every tick from its state, so it isn't rollback
## state. Setting it changes nothing.
var is_sleeping := false

# The shared table of plain pawn data (a PawnTable from the navcore C++ library, scaling spec section 3), or null without the
# library. Every pawn in the tree has a row, in entity-id order. Pawns NetworkSession never configured, as in most tests, have no
# entity id; they get keys from TABLE_KEYS_WITHOUT_ID up, after every networked pawn, in the order they joined.
# REFACTOR: the shared table and grid (get_table, get_grid, _join_table) are static state on the pawn class; a small holder class
# would give them a name of their own and slim the pawn (names say what things do). See CHANGELOG.md.
static var _table: Object = null
static var _grid: Object = null # see get_grid()
const TABLE_KEYS_WITHOUT_ID := 1 << 40
static var _next_table_key := TABLE_KEYS_WITHOUT_ID

## Which way the pawn faces, in radians. The body never turns; only the model does.
var yaw := 0.0
## Our own copy of "on the floor", because rollback has to restore it, and is_on_floor() can't be set.
var grounded := false
var _body_radius := -1.0 # the capsule's radius, found once (get_body_radius)
var _body_shape: CollisionShape3D = null # the collision shape, found once (get_body_shape)
var _tick_state: TickStateComponent = null # its rollback state, if it has one, for rounding crowd moves

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
# The other AI parts (state manager, behaviour manager, sensing, memory, target selector) are found by the AI's core, ai_context,
# not by the pawn: pawn.ai_context.memory and so on. The pawn knows only that it has an AI.


var _driver: Node = null
## True while the Death ability runs, the same as is_dead(). Kept current by DeathAbility (through its timer, so a rollback updates
## it too), and read directly by C++, which is much cheaper than calling is_dead(). Read it; don't set it.
var dead := false
## How often this pawn simulates: every tick (1), every 2nd (2) or every 4th (4). Pawn spec 8.21, scaling spec 7.1.
## [br]
## The AIActivationManager sets it for AI pawns far from every player and camera, and raises it for every AI pawn while the game is
## overloaded (TickDriver.load_step). A pawn a player has always runs every tick, whatever this says. Rolls back. A pawn that runs
## every Nth tick does N ticks' worth each time it runs ([member ticks_elapsed]), so it walks as far and its timers last as long; it
## only reacts less often. Which ticks: spread by its own number, so a crowd at every 4th tick doesn't all run on one.
var tick_step := 1
## The ticks since this pawn last ran, for this run: 1 normally, up to tick_step (at most [constant MAX_TICK_STEP]). Its parts
## advance their timers by it (cooldowns, effects, the AI's schedules), and its simulate step is this many ticks long. Read it; don't
## set it.
var ticks_elapsed := 1
## The longest step, and so the most ticks one run can cover. A pawn frozen for a while comes back with at most this.
const MAX_TICK_STEP := 4
## The Godot group every pawn is in while it's in the tree: the one list of "all pawns". Systems that need every pawn (the crowd
## mover, the kill floor, the team registry, diagnostics, the replay) read it:
## [codeblock]
## for node in get_tree().get_nodes_in_group(Pawn.GROUP): ...
## [/codeblock]
const GROUP := &"pawns"
var _last_run_tick := -1 # the tick this pawn last simulated; rolls back. -1: not yet
var _prepared_tick := -1 # the tick _runs_this_tick and ticks_elapsed were worked out for
var _runs_this_tick := true
var _last_run_span := 1 # ticks_elapsed of the last run, for smoothing Visual across it
var _entity: NetworkEntity = null
var _game_mode: Node = null # found when entering the tree, for the distances
var _last_streamed_position := Vector3.ZERO # for distance_moved_since_last_check
var _streamed_before := false
# REFACTOR: smoothing Visual (these fields, _process, _on_network_interpolated, _on_network_corrected) belongs in its own part, the
# VisualSmoother planned for animation v0 (pawn slimming M6). See CHANGELOG.md.
var _visual: Node3D = null
var _model: Node3D = null
var _previous_position := Vector3.ZERO # the body before and after the last tick, for smoothing Visual
var _current_position := Vector3.ZERO
var _previous_yaw := 0.0
var _current_yaw := 0.0
var _correction_offset := Vector3.ZERO # what's left of a correction, fading to nothing
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
	_join_table() # the shared table of plain pawn data, which AI sensing's grid reads (C++ only; scaling spec step 1)
	# Default parts first, so they're children before anything below or any _ready looks for them. A node may add children to itself
	# here: Godot enters them right after.
	var game_mode: Node = get_node_or_null("/root/GameMode")
	_game_mode = game_mode
	if game_mode and game_mode.pawn_initializer:
		game_mode.pawn_initializer.initialize(self)
	_driver = get_node_or_null("/root/TickDriver")
	if _driver:
		_driver.register(self)
	# A pawn coming back into the tree (taken out and put back, or moved under another parent) joins the AI switch-off again.
	# _exit_tree takes it off that list, and _ready, which adds it the first time, only ever runs once.
	# GDScript note: is_node_ready() is false the first time a node enters the tree, and true every time after.
	if is_node_ready():
		var ai := _ai_activation_manager()
		if ai:
			ai.add_pawn(self)
		_update_source_group()


func _exit_tree() -> void:
	if _table: # leaves the shared table (scaling spec step 1)
		_table.remove(self)
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
	for child in get_children():
		if child is AbilityManager and ability_manager == null:
			ability_manager = child
		elif child is StatManager and stat_manager == null:
			stat_manager = child
		elif child is EffectManager and effect_manager == null:
			effect_manager = child
		elif child is NetworkEntity:
			_entity = child
		elif child is ControllerManager and controller_manager == null:
			controller_manager = child
		elif child is NavigationManager and navigation_manager == null:
			navigation_manager = child
		elif child is AIContextComponent and ai_context == null: # the AI's core; it finds the other AI parts
			ai_context = child

	_visual = get_node_or_null(^"Visual")
	if _visual:
		_visual.top_level = true # it's placed by _process, between ticks, not by the body
		_model = _visual.get_node_or_null(^"Model")
	_previous_position = global_position
	_current_position = global_position
	_previous_yaw = yaw
	_current_yaw = yaw
	# How often it runs, and when it last did, roll back, so a replay runs on the same ticks (pawn spec 8.21).
	for child in get_children():
		if child is TickStateComponent:
			var entries: Array[String] = ["tick_step", "_last_run_tick"] # GDScript note: typed, as add_state_properties asks
			child.add_state_properties(entries)
			_tick_state = child
			break
	# Every pawn is watched by the AI switch-off, which leaves alone those that keep the world loaded, checking each time.
	var ai := _ai_activation_manager()
	if ai:
		ai.add_pawn(self)
	# In the sources' group only while it might keep the world loaded; a player taking or leaving it changes that.
	# GDScript note: unbind(2) drops the signal's two arguments, which _update_source_group doesn't take.
	if controller_manager:
		controller_manager.possession_changed.connect(_update_source_group.unbind(2))
	_update_source_group()


# --- Things other scripts can call ---


## True while this pawn keeps the world loaded around it: a player has it or [member keeps_world_loaded] is on, and it's simulated
## on this machine (another player's pawn on a client doesn't count there). The same as [method counts_on_this_machine], under a name
## that says what it means outside streaming.
func is_keeping_world_loaded() -> bool:
	return counts_on_this_machine()


## Keeps this pawn in the streaming sources' group (StreamingSource.GROUP) exactly while it might keep the world loaded:
## keeps_world_loaded is on, or a player has it. So the chunk streamer (twice a frame), the nav feeder and the replay look through the
## two or three pawns that count, not the whole army. Whether it really counts on this machine is still counts_on_this_machine(),
## asked each time; this only keeps the list they look through short. Called when either of the two changes, and when the pawn
## enters the tree.
func _update_source_group() -> void:
	if not is_inside_tree():
		return
	var wanted := keeps_world_loaded or _has_a_player()
	if wanted == is_in_group(StreamingSource.GROUP):
		return
	if wanted:
		add_to_group(StreamingSource.GROUP)
	else:
		remove_from_group(StreamingSource.GROUP)


## The source contract (StreamingSource.gd): whether this pawn loads the world around it on this machine now. The chunk streamer, the
## nav feeder and the AI switch-off ask this every time they look.
func counts_on_this_machine() -> bool:
	return (keeps_world_loaded or _has_a_player()) and is_inside_tree() and is_simulated_here()


## The source contract: how far this pawn has moved since the streamer last asked, so it can judge how soon a chunk edge comes. 0 the
## first time, because arriving somewhere isn't moving.
func distance_moved_since_last_check() -> float:
	var at := global_position
	var moved := at.distance_to(_last_streamed_position) if _streamed_before else 0.0
	_last_streamed_position = at
	_streamed_before = true
	return moved


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


## The shared table of plain pawn data (scaling spec section 3), or null without the C++ library. Read-only for anyone but Pawn:
## pawns join and leave it themselves. Its rows are read from the pawns once a tick, at the first refresh(tick).
static func get_table() -> Object:
	return _table


# The Detectability stat, or null without one (or before the StatManager is found).
func _detectability_stat() -> Stat:
	return stat_manager.get_stat(StatManager.DETECTABILITY) if stat_manager else null


## The shared grid of pawns (AIPawnGrid), built from the table on first use, or null without the C++ library. AI sensing and the
## swing hit checks (MeleeSweepStep) both use it, so it lives beside the table.
static func get_grid() -> Object:
	if _grid == null and _table != null and ClassDB.class_exists(&"AIPawnGrid"):
		_grid = ClassDB.instantiate(&"AIPawnGrid")
		_grid.set_table(_table)
	return _grid


# Joins the shared table, making it on first use. The key is the entity id, which the NetworkEntity already has: NetworkSession
# configures it before the pawn enters the tree. _entity isn't found until _ready, so the child is looked for here.
func _join_table() -> void:
	if _table == null:
		if not ClassDB.class_exists(&"PawnTable"):
			return
		# GDScript note: made by name, so this script still runs where the C++ library isn't available.
		_table = ClassDB.instantiate(&"PawnTable")
	var key := -1
	for child in get_children():
		if child is NetworkEntity and child.entity_id >= 0:
			key = child.entity_id
	if key < 0:
		key = _next_table_key
		_next_table_key += 1
	_table.add(self, key)


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
	_last_run_span = ticks_elapsed
	_last_run_tick = tick
	# Sleeping (pawn spec 15.3). Checked before _current_position is overwritten, because "nothing moved it since its last tick"
	# compares against it. A sleeping pawn only does the bookkeeping at the end.
	var sleeping := _can_sleep(tick)
	is_sleeping = sleeping
	_previous_position = _current_position
	_previous_yaw = _current_yaw
	if sleeping:
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
	if not was_grounded:
		velocity.y -= _gravity_strength() * dt
	# move_and_slide uses Godot's physics delta. This scales it so that one tick moves velocity * tick dt.
	# Standing still with nothing to move it: skip the solve (see skip_move_when_still).
	if skip_move_when_still and was_grounded and velocity == Vector3.ZERO and global_position == _current_position and not _is_check_tick(tick):
		PerfScopes.add(&"pawn.move_skipped", 0)
		_finish_tick()
		return
	# The CrowdMover takes the move of an AI pawn walking on the ground (its rule, try_take_move), moves the whole crowd once every
	# pawn has simulated, then finishes this tick for it (finish_crowd_move). dt is this run's length (pawn spec 8.22).
	if CrowdMover.current and CrowdMover.current.try_take_move(self, was_grounded, dt):
		return
	_move_with_physics() # the CrowdMover's fallback runs it too
	_finish_tick() # a sleeping tick runs it too


# One move by physics: move_and_slide with this run's velocity, then whether it's on the floor.
func _move_with_physics() -> void:
	# Times ticks_elapsed, so a pawn running every Nth tick moves N ticks' worth.
	var factor: float = (_driver.get_physics_factor() if _driver else 1.0) * ticks_elapsed
	velocity *= factor
	var move_started := PerfScopes.begin()
	move_and_slide()
	PerfScopes.end(&"pawn.move_and_slide", move_started)
	velocity /= factor
	grounded = is_on_floor()


## The CrowdMover moved this pawn to at, over seconds: it stands there on the ground, its velocity is what it really moved (as
## move_and_slide leaves it), and its tick finishes (pawn spec 8.22). The position is rounded as the rollback recording will round it
## (TickStateComponent.round_position), so the recording changes nothing afterwards and a still pawn is exactly still, and sleeps.
func finish_crowd_move(at: Vector3, seconds: float) -> void: # public, since the CrowdMover calls it
	# The velocity from the real move, before rounding, as move_and_slide leaves it: from the rounded one it would wobble by up to a
	# millimetre a tick, 0.06 m/s at 60 ticks a second.
	var moved := at - global_position
	velocity = Vector3(moved.x, 0.0, moved.z) / seconds if seconds > 0.0 else Vector3.ZERO
	global_position = at
	if _tick_state:
		position = _tick_state.round_position(position) # its own position, as the recording rounds it, not the world one
	grounded = true
	_finish_tick()


## The CrowdMover couldn't move this pawn (a wall, an edge, no ground under where it was going), so it moves by physics now, in the
## same tick, which handles those, and finishes its tick. Its velocity is still this run's.
func finish_move_by_physics() -> void: # public, since the CrowdMover calls it
	_move_with_physics()
	_finish_tick()


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


# The end of every tick, sleeping or not: where the body is now, for smoothing Visual and for the sleeping check, and the input
# bookkeeping.
func _finish_tick() -> void:
	_current_position = global_position
	_current_yaw = yaw
	# The input bookkeeping, on the ControllerManager: what was held this tick, so the next tick can tell a press from a hold, and a
	# tick with real input ends a run of missing ones.
	if controller_manager:
		controller_manager.finish_tick()


## True if this pawn sleeps this tick (pawn spec 15.3). "Sleeping" is the standard physics name, not to be confused with frozen
## (switched off by the AIActivationManager) or paused (the whole game). A pure rule of its state and the tick number, with nothing
## remembered, so nothing extra rolls back and a server and a client predicting it sleep on the same ticks. In order of cheapness:
## [br]- sleep_when_idle is on, it's grounded, its velocity is exactly zero, and it has no move input and no held actions
## [br]- nothing moved it since its last tick (a teleport, or TerrainBodyLifter raising it)
## [br]- this isn't one of its check ticks, every sleep_check_ticks, staggered by entity id
## [br]- it has no over-time effect on it to count down (EffectManager.can_sleep)
## [br]- its abilities have no timer running and agree (AbilityManager.can_sleep)
func _can_sleep(tick: int) -> bool:
	if not sleep_when_idle or not grounded or velocity != Vector3.ZERO:
		return false
	if controller_manager and (controller_manager.move_input != Vector3.ZERO or controller_manager.held_actions != 0):
		return false
	if global_position != _current_position:
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


## TickState restored our properties, but CharacterBody3D also keeps a private "on floor" flag that still holds what the body is
## doing now. Nothing can set it directly, so this makes the engine work it out again, then puts things back.
func _on_state_loaded(_tick: int) -> void:
	_prepared_tick = -1 # worked out again from the loaded _last_run_tick
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
	_previous_position = global_position
	_current_position = global_position
	_previous_yaw = yaw
	_current_yaw = yaw


func _physics_process(delta: float) -> void:
	_fallback_tick += 1
	_tick_input(delta, _fallback_tick)
	_tick_simulate(delta, _fallback_tick)


# --- Per rendered frame: only ever reads game state ---


func _process(delta: float) -> void:
	if _visual == null:
		return
	var started := PerfScopes.begin() # timed for diagnostics, in its animation category
	# Fades over about 100 ms, so the player sees a quick slide rather than a jump (netcode spec section 6.2).
	_correction_offset = _correction_offset.lerp(Vector3.ZERO, 1.0 - exp(-delta / 0.04))
	var fraction: float = _driver.get_interpolation_fraction() if _driver else 1.0
	# A pawn running every Nth tick moves once per run, so Visual glides across the whole run (pawn spec 8.21).
	if _last_run_span > 1 and _driver and is_simulated_here():
		fraction = clampf((float(_driver.tick - _last_run_tick) + fraction) / float(_last_run_span), 0.0, 1.0)
	_visual.global_position = _previous_position.lerp(_current_position, fraction) + _correction_offset
	if _model:
		_model.rotation.y = lerp_angle(_previous_yaw, _current_yaw, fraction)
	PerfScopes.end(&"animation.smoothing", started)


# --- Multiplayer: optional hooks from NetworkEntity ---


## Works for a role that changes while running, as swapping pawns does.
func _on_network_role(entity: NetworkEntity) -> void:
	_entity = entity
	# The server runs it now: it stops doing what the last player's final input said.
	# REFACTOR: clearing input is the ControllerManager's job (pawn slimming M4); it could watch the role change itself. See
	# CHANGELOG.md.
	if entity.role == NetworkEntity.Role.AUTHORITY and entity.owner_peer == 0 and controller_manager:
		controller_manager.clear_input()


## On a client, for a pawn someone else controls: it was just moved between snapshots, so Visual follows.
func _on_network_interpolated() -> void:
	_previous_position = _current_position
	_current_position = global_position
	_previous_yaw = _current_yaw
	_current_yaw = yaw


## On a client: a correction moved our body by this much.
func _on_network_corrected(jump: Variant) -> void:
	if jump is Vector3:
		_correction_offset += jump


# --- Helpers ---


# The game's pawn defaults, for the distances, or null without a PawnInitializer.
func _pawn_defaults() -> PawnDefaultsRes:
	var initializer: PawnInitializer = _game_mode.pawn_initializer if _game_mode else null
	return initializer.defaults if initializer else null


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
