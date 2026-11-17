## Written by Claude (claude-opus-5-5), 2026-11-07: the tier -1 pawn: a body something can possess. Its parts (managers, abilities,
## AI) are child nodes that PawnInitializer adds from the game's defaults; there is no nexus. Specs: docs/pawn/PAWN_SPEC.md and
## docs/pawn/PLAYER_AND_CAMERA.md. (Claude 2026-11-17: the first lines said it had no managers or abilities yet.) The old CharacterPawn3D is untouched, and carries on working in test scene.tscn
## (Claude 2026-11-08: both are now in assets/legacy/).
##
## How to use it: use assets/scenes/pawn/pawn.tscn as it is, or inherit from it. Something writes this pawn's input each tick,
## such as a PlayerController, or an AI script on the server. Its abilities make that into movement.
##
## Claude 2026-11-07: parts and input, pawn spec steps 3 to 6.
##   - When it enters the tree, GameMode's PawnInitializer adds the default parts its scene doesn't have: ControllerManager (with an
##     AIController), NavigationManager (Claude 2026-11-08), StatManager (with movement stats) and AbilityManager (with Walk, Jump
##     and Sprint). fill_in_default_parts and skip_default_parts opt out. Claude 2026-11-10: and EffectManager, which applies effects
##     such as a hit's damage and knockback (pawn spec 8.11).
##   - Each tick, in its input phase, it asks its ControllerManager for input from whoever is in charge: this machine's player, or
##     else its AI controller. It only asks where its input is decided here. A client's pawn on the server gets its input over the
##     network instead.
##   - Each tick, its AbilityManager runs the abilities, which write velocity and facing. Then the pawn adds gravity and makes the one
##     move_and_slide call. Claude 2026-11-07: this replaced GroundMovement and MovementModule, which are gone.
##   - Claude 2026-11-09: each tick, before asking for input, it runs its AI parts (AIContextComponent, AIStateManager,
##     AIBehaviourManager) in a fixed order, offline or on the server only. See AIContextComponent.run_ai (Claude 2026-11-16: was _tick_ai here) and pawn spec
##     section 10.
##
## What it needs in its scene, all optional:
##   - an AbilityManager child. With none, nothing steers it, and it only falls. It comes from PawnInitializer by default.
##   - a TickStateComponent and a NetworkEntity child, for rollback and multiplayer. With none, it plays as single player. These
##     two stay in the scene, because NetworkSession reads them before the pawn joins the tree.
##   - a Node3D child called Visual, which the camera and the model hang from.
## pawn.tscn puts bodies on collision layer 2, and they collide with layers 1 and 2. The ground is on layer 1, so a camera arm
## can tell the ground from a pawn walking past.
##
## Why the body's rotation is never written: writing rotation every tick slowly changed the body's scale through rounding, which
## made collision differ in a replay (see TickSamplePawn). So facing is a plain number, and only the model turns.
##
## Why Visual exists: the body moves in ticks and gets corrected, and looks jerky if you watch it directly. Visual follows it
## smoothly per rendered frame, and hides corrections by fading them out. Anything on screen hangs from it.
##
## Claude 2026-11-07: input is now an InputCommand, given with apply_input(). Actions such as jump and sprint are named, held as bits,
## and a press is "held this tick, not last tick" (was_action_pressed). Pawn spec section 5.
## Claude 2026-11-16 (pawn M4): the input, the press and hold checks, the server's checks on a client's input and whether a player has the pawn
## all moved to its ControllerManager (pawn.controller_manager.move_input, .has_player() and so on), the owner's call.
##
## What happens in odd cases (all checked in tests/pawn_selftest.gd):
##   - No TickDriver: it ticks itself from _physics_process.
##   - AI pawn in unloaded ground: AIActivationManager stops its ticks, and it keeps all its state.
##   - On the server, a client's input goes missing: see ControllerManager._network_input_missing (Claude 2026-11-16 (pawn M4)).
class_name Pawn
extends CharacterBody3D

## Claude 2026-11-16 (pawn M1): sent when this pawn's team changes, for the TeamRegistry (GameMode.team_registry), which keeps the counts.
signal team_changed(pawn: Pawn, old_team: int, new_team: int)
# Claude 2026-11-16 (pawn M4): possession_changed moved to the ControllerManager, with whether a player has the pawn.
# Claude 2026-11-16 (pawn M3): hit_received and died moved to the AbilityManager, which handles hits and death now (pawn.ability_manager.died).

# Claude 2026-11-17 (the owner's call): possessable moved to the ControllerManager, with the rest of possession (has_player).
## On: this pawn keeps the world loaded around it even without a player, as a player's pawn always does: a hero, say. Off, it's
## frozen wherever nothing else keeps the ground loaded, which is what you want for a horde.
## Claude 2026-11-16 (pawn M2): renamed from ai_loads_chunks, and now only a flag: the pawn makes no StreamingSource node. The chunk streamer, the nav
## feeder and the AI switch-off read it whenever they look (counts_on_this_machine below), so changing it needs nothing told. That
## also ends the bug where switching it off left a hero unwatched (2026-11-15). How far it loads is the game's setting
## (PawnDefaultsRes.world_load_distance), not the pawn's.
## Claude 2026-11-16 (wider audit): setting it also puts the pawn in or out of the sources' group (_update_source_group).
@export var keeps_world_loaded := false:
	set(value):
		keeps_world_loaded = value
		_update_source_group()
# Claude 2026-11-16 (pawn M5): always_has_camera_arm is gone: the player's one arm moves to whichever pawn they take, so there's no delay to save.
## Claude 2026-11-16 (pawn M2): how far this pawn keeps the world loaded when it does, in metres: the game's setting (PawnDefaultsRes, read through
## GameMode's PawnInitializer), 320 without one. Read-only. Named as a StreamingSource's is, because the chunk streamer reads both the
## same way (StreamingSource.gd, "the source contract").
var load_distance: float:
	get:
		var defaults: PawnDefaultsRes = _pawn_defaults()
		return defaults.world_load_distance if defaults else 320.0
## How far nav is built around it, in metres: the game's setting, 128 without one. Read-only.
var nav_distance: float:
	get:
		var defaults: PawnDefaultsRes = _pawn_defaults()
		return defaults.world_nav_distance if defaults else 128.0
# Claude 2026-11-16 (pawn M5): camera_preset moved to a CameraMount node the pawn's scene places under Visual (camera/CameraMount.gd).
## Claude 2026-11-07: on, GameMode's PawnInitializer adds every default part this pawn's scene doesn't already have. Off, the pawn
## gets only what its scene has.
@export var fill_in_default_parts := true
## Claude 2026-11-07: how strongly it falls, in metres per second per second. Below 0, the project's gravity setting. Moved here from
## GroundMovement: the pawn adds gravity, and abilities only steer.
@export var gravity := -1.0
## Claude 2026-11-07: default parts to leave out, by name, such as &"AbilityManager". A part with that name in the scene is kept
## either way.
@export var skip_default_parts: Array[StringName] = []
## Claude 2026-11-09: which side this pawn is on. AI sensing only notices pawns of other teams (pawn spec 10.4). A player who
## possesses a pawn plays for its team.
@export var team := 0:
	set(value):
		if team == value:
			return
		var old_team := team
		team = value
		team_changed.emit(self, old_team, value) # Claude 2026-11-16 (pawn M1): the counts moved to the TeamRegistry module
## Claude 2026-11-09: how easy this pawn is for AI to see: 1 is normal, lower is harder, 0 is invisible. Sight multiplies its fill
## rate by this (pawn spec 10.4). Nothing in the base changes it: how stealth, gear or light level turn into this number is a game
## rule, for a GameMode module to set.
## Claude 2026-11-17 (C++ bundle stage 4, pawn M6): a stat now, Detectability in the pawn's StatManager (StatManager.DETECTABILITY,
## in the default stats), so effects can change it (a stealth buff, say) and it's mirrored into the pawn table for the sensing job.
## This reads and writes that stat: set its base value on the stat in a pawn scene. A pawn without the stat keeps its own number here.
## No longer in the inspector, so there's one place to set it.
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
var _own_detectability := 1.0 # Claude 2026-11-17: detectability, for a pawn without the stat
## Claude 2026-11-09: on: a pawn standing still with nothing to do sleeps, skipping its abilities, gravity and move_and_slide until
## something wakes it (pawn spec 15.3). Off: it simulates fully every tick.
@export var sleep_when_idle := true
## Claude 2026-11-09: a sleeping pawn still runs a full tick this often, staggered by entity id, so ground that went away under it is
## noticed. 15 ticks is a quarter of a second at 60 ticks a second.
@export_range(1, 600, 1, "or_greater") var sleep_check_ticks := 15
## Claude 2026-11-16 (movement experiments): on: a pawn awake for its timers (an effect or ability counting down) but not moving skips move_and_slide, when it's
## grounded, has no velocity after its abilities and gravity, and nothing moved it since its last tick. It still moves for real on its
## check ticks (sleep_check_ticks), so ground taken from under it is noticed, as for a sleeping pawn. Off (the default until it's
## measured): it always moves. Skipped moves are counted in diagnostics as pawn.move_skipped.
## Claude 2026-11-16: on by default, the owner's call after the mass battle measurement (24 to 31 skipped moves a frame at the first
## clash, about 0.2 ms; nothing skipped while marching, when everyone moves).
@export var skip_move_when_still := true
## Claude 2026-11-16 (pawn spec 8.22): on (the default): while an AI drives this pawn on the server or offline and it walks on the
## ground, the GameMode's CrowdMover moves it with the rest of the crowd instead of move_and_slide (much cheaper; AI pawns are kept
## apart by separation rather than by colliding). A player's pawn, one in the air, one on a client, or one running an ability with
## needs_full_movement always moves by physics. Off: this pawn always moves by physics.
@export var crowd_movement := true
## Claude 2026-11-16 (movement experiments): on (the default, as before): after a rollback restores this pawn, a zero-length move_and_slide rebuilds Godot's own
## "on the floor" flag, which the first replayed tick's floor snap reads. Off: it's left as it was, which saves a physics solve per
## restored pawn but can make that first replayed tick differ. Only clients roll back, and by default only their own pawn.
@export var rebuild_floor_on_rollback := true
## Claude 2026-11-09: whether this pawn rested on its last tick, for readouts and tests. Worked out again every tick from its state,
## so it isn't rollback state. Setting it changes nothing.
var is_sleeping := false

# Claude 2026-11-09: the shared table of plain pawn data (a PawnTable from the navcore C++ library, scaling spec section 3), or null
# without the library. Every pawn in the tree has a row, in entity-id order. Pawns NetworkSession never configured, as in most
# tests, have no entity id; they get keys from TABLE_KEYS_WITHOUT_ID up, after every networked pawn, in the order they joined.
static var _table: Object = null
static var _grid: Object = null # Claude 2026-11-17: see get_grid()
const TABLE_KEYS_WITHOUT_ID := 1 << 40
static var _next_table_key := TABLE_KEYS_WITHOUT_ID

# Claude 2026-11-16 (pawn M4): this tick's input and last tick's held actions moved to the ControllerManager (see the top of the file).
var yaw := 0.0
## Our own copy of "on the floor", because rollback has to restore it, and is_on_floor() can't be set.
var grounded := false
var _body_radius := -1.0 # Claude 2026-11-16: the capsule's radius, found once (get_body_radius)
var _body_shape: CollisionShape3D = null # Claude 2026-11-16: the collision shape, found once (get_body_shape)
var _tick_state: TickStateComponent = null # Claude 2026-11-16: its rollback state, if it has one, for rounding crowd moves

## Claude 2026-11-07: runs this pawn's abilities, which steer it. Null if it has none. Replaces the old movement module.
var ability_manager: AbilityManager = null
## Claude 2026-11-07: this pawn's stats, which abilities read. Null if it has none, and then abilities use their fallbacks.
var stat_manager: StatManager = null
## Claude 2026-11-10: applies effects to this pawn and keeps the over-time ones (pawn spec 8.11). Null if it has none, and then hits
## and effects do nothing to it.
var effect_manager: EffectManager = null
## Claude 2026-11-07: picks whose input this pawn follows. Null if the pawn has none, and then nothing writes its input for it.
var controller_manager: ControllerManager = null
## Claude 2026-11-08: finds paths and says which way to walk, for click-to-move and the AI. Null if the pawn has none.
var navigation_manager: NavigationManager = null
## Claude 2026-11-09: shared data and settings for this pawn's AI (pawn spec 10). Null if the pawn has no AI.
var ai_context: AIContextComponent = null
# Claude 2026-11-17 (the owner's call): the other AI parts (state manager, behaviour manager, sensing, memory, target selector) are
# found by the AI's core, ai_context, not by the pawn: pawn.ai_context.memory and so on. The pawn knows only that it has an AI.


var _driver: Node = null
## Claude 2026-11-09 (scaling spec step 4): true while the Death ability runs, the same as is_dead(). Kept current by DeathAbility
## (through its timer, so a rollback updates it too), and read directly by C++, which is much cheaper than calling is_dead().
## Read it; don't set it.
var dead := false
## Claude 2026-11-16 (pawn spec 8.21, scaling spec 7.1, the owner's call): how often this pawn simulates: every tick (1), every 2nd (2)
## or every 4th (4). The AIActivationManager sets it for AI pawns far from every player and camera, and raises it for every AI pawn
## while the game is overloaded (TickDriver.load_step). A pawn a player has always runs every tick, whatever this says. Rolls back.
## A pawn that runs every Nth tick does N ticks' worth each time it runs (ticks_elapsed), so it walks as far and its timers last as
## long; it only reacts less often. Which ticks: spread by its own number, so a crowd at every 4th tick doesn't all run on one.
var tick_step := 1
## Claude 2026-11-16: the ticks since this pawn last ran, for this run: 1 normally, up to tick_step (at most MAX_TICK_STEP). Its parts
## advance their timers by it (cooldowns, effects, the AI's schedules), and its simulate step is this many ticks long. Read it; don't set it.
var ticks_elapsed := 1
## Claude 2026-11-16: the longest step, and so the most ticks one run can cover. A pawn frozen for a while comes back with at most this.
const MAX_TICK_STEP := 4
## Claude 2026-11-16 (wider audit): the Godot group every pawn is in while it's in the tree: the one list of "all pawns". Systems
## that need every pawn (the crowd mover, the kill floor, the team registry, diagnostics, the replay) read it:
##   for node in get_tree().get_nodes_in_group(Pawn.GROUP): ...
## They used to borrow TerrainBodyLifter's group, whose name says something else, or the streaming sources' group.
const GROUP := &"pawns"
var _last_run_tick := -1 # Claude 2026-11-16: the tick this pawn last simulated; rolls back. -1: not yet
var _prepared_tick := -1 # the tick _runs_this_tick and ticks_elapsed were worked out for
var _runs_this_tick := true
var _last_run_span := 1 # ticks_elapsed of the last run, for smoothing Visual across it
var _entity: NetworkEntity = null
var _game_mode: Node = null # Claude 2026-11-16 (pawn M2): found when entering the tree, for the distances
var _last_streamed_position := Vector3.ZERO # for distance_moved_since_last_check
var _streamed_before := false
var _visual: Node3D = null
var _model: Node3D = null
var _previous_position := Vector3.ZERO # the body before and after the last tick, for smoothing Visual
var _current_position := Vector3.ZERO
var _previous_yaw := 0.0
var _current_yaw := 0.0
var _correction_offset := Vector3.ZERO # what's left of a correction, fading to nothing
var _fallback_tick := 0
var _frozen := false # Claude 2026-11-16 (pawn M1): was _simulating, the other way round


func _init() -> void:
	floor_snap_length = 0.3
	floor_max_angle = deg_to_rad(50.0)
	# Godot's default margin is exactly 1 mm, and TickState rounds positions to exact 1 mm steps. That parks a standing body on
	# the edge of "touching the floor", so float noise flips the contact. A margin between two steps avoids it.
	safe_margin = 0.0014


func _enter_tree() -> void:
	add_to_group(GROUP) # Claude 2026-11-16 (wider audit): the list of all pawns
	add_to_group(TerrainBodyLifter.GROUP)
	_join_table() # Claude 2026-11-09: the shared table of plain pawn data, which AI sensing's grid reads (C++ only; scaling spec step 1)
	# Claude 2026-11-07: default parts first, so they're children before anything below or any _ready looks for them. A node may
	# add children to itself here: Godot enters them right after.
	var game_mode: Node = get_node_or_null("/root/GameMode")
	_game_mode = game_mode
	if game_mode and game_mode.pawn_initializer:
		game_mode.pawn_initializer.initialize(self)
	_driver = get_node_or_null("/root/TickDriver")
	if _driver:
		_driver.register(self)
	# Claude 2026-11-16 (wider audit): a pawn coming back into the tree (taken out and put back, or moved under another parent) joins
	# the AI switch-off again. _exit_tree takes it off that list, and _ready, which adds it the first time, only ever runs once.
	# GDScript note: is_node_ready() is false the first time a node enters the tree, and true every time after.
	if is_node_ready():
		var ai := _ai_activation_manager()
		if ai:
			ai.add_pawn(self)
		_update_source_group()


func _exit_tree() -> void:
	if _table: # Claude 2026-11-09: leaves the shared table (scaling spec step 1)
		_table.remove(self)
	# Claude 2026-11-07: this first, because leaving the list can switch the pawn back on, which would register it again.
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
		if child is AbilityManager and ability_manager == null: # Claude 2026-11-07: was the movement module
			ability_manager = child
		elif child is StatManager and stat_manager == null: # Claude 2026-11-07
			stat_manager = child
		elif child is EffectManager and effect_manager == null: # Claude 2026-11-10
			effect_manager = child
		elif child is NetworkEntity:
			_entity = child
		elif child is ControllerManager and controller_manager == null: # Claude 2026-11-07
			controller_manager = child
		elif child is NavigationManager and navigation_manager == null: # Claude 2026-11-08
			navigation_manager = child
		elif child is AIContextComponent and ai_context == null: # Claude 2026-11-09: the AI's core; it finds the other AI parts (2026-11-17)
			ai_context = child

	_visual = get_node_or_null(^"Visual")
	if _visual:
		_visual.top_level = true # it's placed by _process, between ticks, not by the body
		_model = _visual.get_node_or_null(^"Model")
	_previous_position = global_position
	_current_position = global_position
	_previous_yaw = yaw
	_current_yaw = yaw
	# Claude 2026-11-16 (pawn spec 8.21): how often it runs, and when it last did, roll back, so a replay runs on the same ticks.
	for child in get_children():
		if child is TickStateComponent:
			var entries: Array[String] = ["tick_step", "_last_run_tick"] # GDScript note: typed, as add_state_properties asks
			child.add_state_properties(entries)
			_tick_state = child # Claude 2026-11-16 (pawn spec 8.22)
			break
	# Claude 2026-11-16 (pawn M2): every pawn is watched by the AI switch-off, which leaves alone those that keep the world loaded, checking each time.
	var ai := _ai_activation_manager()
	if ai:
		ai.add_pawn(self)
	# Claude 2026-11-16 (wider audit): in the sources' group only while it might keep the world loaded; a player taking or leaving it
	# changes that. GDScript note: unbind(2) drops the signal's two arguments, which _update_source_group doesn't take.
	if controller_manager:
		controller_manager.possession_changed.connect(_update_source_group.unbind(2))
	_update_source_group()


# --- Things other scripts can call ---


## Claude 2026-11-16 (pawn M2): true while this pawn keeps the world loaded around it: a player has it or keeps_world_loaded is on, and it's
## simulated on this machine (another player's pawn on a client doesn't count there). Was has_chunk_source(). The same as
## counts_on_this_machine(), under a name that says what it means outside streaming.
func is_keeping_world_loaded() -> bool:
	return counts_on_this_machine()


## Claude 2026-11-16 (wider audit): keeps this pawn in the streaming sources' group (StreamingSource.GROUP) exactly while it might keep
## the world loaded: keeps_world_loaded is on, or a player has it. Every pawn used to be in that group, so the chunk streamer (twice
## a frame), the nav feeder and the replay each went through the whole army to find the two or three pawns that count. Whether it
## really counts on this machine is still counts_on_this_machine(), asked each time; this only keeps the list they look through short.
## Called when either of the two changes, and when the pawn enters the tree.
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


## Claude 2026-11-16 (pawn M2): the source contract (StreamingSource.gd): whether this pawn loads the world around it on this machine now. The chunk
## streamer, the nav feeder and the AI switch-off ask this every time they look.
func counts_on_this_machine() -> bool:
	return (keeps_world_loaded or _has_a_player()) and is_inside_tree() and is_simulated_here()


## Claude 2026-11-16 (pawn M2): the source contract: how far this pawn has moved since the streamer last asked, so it can judge how soon a chunk edge
## comes. 0 the first time, because arriving somewhere isn't moving.
func distance_moved_since_last_check() -> float:
	var at := global_position
	var moved := at.distance_to(_last_streamed_position) if _streamed_before else 0.0
	_last_streamed_position = at
	_streamed_before = true
	return moved


## The node that follows the body smoothly, for hanging things from. With no Visual, it's the body.
func get_visual() -> Node3D:
	return _visual if _visual else self


# Claude 2026-11-16 (wider audit): get_camera_arm, get_camera_mount, get_camera_preset and get_default_view moved to CameraMount
# (CameraMount.arm_of(pawn), mount_of, preset_of, view_of). Only the PlayerController used them, and the camera isn't the pawn's business.


## Freezes or unfreezes the pawn: frozen, it doesn't tick at all, and everything about it stays as it is. AIActivationManager calls this
## where no ground is loaded around an AI pawn (pawn spec 15.3, "frozen").
# Claude 2026-11-07: through the NetworkEntity, because it decides what ticks. This only stopped the pawn itself, and left its entity and
# TickState running: 2,000 pawns that were off still cost 53 ms a tick.
# Claude 2026-11-16 (pawn M1): renamed from set_simulation_active(active), the agreed name; the true-or-false is the other way round.
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


## True while frozen. Claude 2026-11-16 (pawn M1): was is_simulation_active(), the other way round.
func is_frozen() -> bool:
	return _frozen


## Claude 2026-11-09: true where this pawn's AI runs: offline, or on the server. The AI never runs on a client (pawn spec 10.2).
func runs_ai_here() -> bool:
	return is_authority()


## Claude 2026-11-09: true where this pawn's state is decided: offline, or on the server. Hits are decided here.
func is_authority() -> bool:
	return _entity == null or _entity.role == NetworkEntity.Role.AUTHORITY


## Claude 2026-11-09, step 10: true while this pawn's Death ability runs: from Health reaching 0 until revive(). A pawn with no Death
## ability never dies. Claude 2026-11-09 (scaling spec step 4): it returns dead, which the Death ability keeps current.
func is_dead() -> bool:
	return dead


# Claude 2026-11-17 (the owner's call): get_health() moved to the StatManager (pawn.stat_manager.get_health()), with the one Health name.


# Claude 2026-11-16 (pawn M3): revive, receive_hit, is_invulnerable, notice_incoming_attack, health_ran_out and the hit queue moved to the
# AbilityManager (pawn.ability_manager.receive_hit and so on); the swing's warning goes to the AI context directly.


## Claude 2026-11-09: the shared table of plain pawn data (scaling spec section 3), or null without the C++ library. Read-only for
## anyone but Pawn: pawns join and leave it themselves. Its rows are read from the pawns once a tick, at the first refresh(tick).
static func get_table() -> Object:
	return _table


# Claude 2026-11-17 (C++ bundle stage 4): the Detectability stat, or null without one (or before the StatManager is found).
func _detectability_stat() -> Stat:
	return stat_manager.get_stat(StatManager.DETECTABILITY) if stat_manager else null


## Claude 2026-11-17 (C++ bundle stage 3): the shared grid of pawns (AIPawnGrid), built from the table on first use, or null without
## the C++ library. Was AISensingManager's own; the swing hit checks use it too (MeleeSweepStep), so it lives beside the table.
static func get_grid() -> Object:
	if _grid == null and _table != null and ClassDB.class_exists(&"AIPawnGrid"):
		_grid = ClassDB.instantiate(&"AIPawnGrid")
		_grid.set_table(_table)
	return _grid


# Claude 2026-11-09: joins the shared table, making it on first use. The key is the entity id, which the NetworkEntity already has:
# NetworkSession configures it before the pawn enters the tree. _entity isn't found until _ready, so the child is looked for here.
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


## Claude 2026-11-09: this pawn's NetworkEntity, or null when it isn't networked. Its entity_id is the same on every machine.
func get_network_entity() -> NetworkEntity:
	return _entity


# --- Ticks ---


## Claude 2026-11-07: the input phase. Asks the controller in charge for this tick's input, where this pawn's input is decided here.
## A script that writes input itself, such as a test brain, can still do so later in the same phase and win.
func _tick_input(_dt: float, tick: int) -> void:
	# Claude 2026-11-16 (pawn spec 8.21): a pawn that runs every Nth tick skips the others: no AI, no input.
	_prepare_run(tick)
	if not _runs_this_tick:
		return
	if is_dead():
		if controller_manager:
			controller_manager.clear_input() # Claude 2026-11-09: a dead pawn ignores its controllers and its AI
		return
	# Claude 2026-11-09: the AI first (step 1 of pawn spec section 4), before the controller in charge is asked for input.
	# Claude 2026-11-16 (pawn M1): the AI's ordered step moved into its core part, AIContextComponent.run_ai (was Pawn._tick_ai).
	if ai_context:
		var ai_started := PerfScopes.begin() # Claude 2026-11-16: timed for diagnostics (PerfScopes)
		ai_context.run_ai(tick)
		PerfScopes.end(&"ai", ai_started)
	# Claude 2026-11-16 (pawn M4): the ControllerManager asks the controller in charge and writes the input, where it's decided here.
	if controller_manager:
		var input_started := PerfScopes.begin() # Claude 2026-11-16: timed for diagnostics (PerfScopes)
		controller_manager.tick_input(tick)
		PerfScopes.end(&"pawn.input", input_started)


func _tick_simulate(dt: float, tick: int) -> void:
	# Claude 2026-11-16 (pawn spec 8.21): skipped on ticks it doesn't run; on those it does, a step as long as the ticks since its last.
	# A rollback replay calls only this, not _tick_input, so it works out the same thing here.
	_prepare_run(tick)
	if not _runs_this_tick:
		return
	dt *= ticks_elapsed
	_last_run_span = ticks_elapsed
	_last_run_tick = tick
	# Claude 2026-11-09: sleeping (pawn spec 15.3). Checked before _current_position is overwritten, because "nothing moved it since
	# its last tick" compares against it. A sleeping pawn only does the bookkeeping at the end.
	var sleeping := _can_sleep(tick)
	is_sleeping = sleeping
	_previous_position = _current_position
	_previous_yaw = _current_yaw
	if sleeping:
		_finish_tick()
		return
	# Claude 2026-11-07: abilities steer, then gravity, then one move_and_slide. Gravity goes by whether it was on the ground when the
	# tick began, as GroundMovement did, so a jump that starts this tick isn't pulled down in the same tick.
	var was_grounded := grounded
	# Claude 2026-11-10: over-time effects count down first, so this tick's abilities see this tick's slows and boosts (8.11).
	var abilities_started := PerfScopes.begin() # Claude 2026-11-16: timed for diagnostics (PerfScopes)
	if effect_manager:
		effect_manager.tick_effects()
	if ability_manager:
		ability_manager.tick_abilities(dt)
	PerfScopes.end(&"pawn.abilities", abilities_started)
	if not was_grounded:
		velocity.y -= _gravity_strength() * dt
	# move_and_slide uses Godot's physics delta. This scales it so that one tick moves velocity * tick dt.
	# Claude 2026-11-16 (movement experiments): standing still with nothing to move it: skip the solve (see skip_move_when_still).
	if skip_move_when_still and was_grounded and velocity == Vector3.ZERO and global_position == _current_position and not _is_check_tick(tick):
		PerfScopes.add(&"pawn.move_skipped", 0)
		_finish_tick()
		return
	# Claude 2026-11-16 (pawn spec 8.22): the CrowdMover takes the move of an AI pawn walking on the ground (its rule, try_take_move),
	# moves the whole crowd once every pawn has simulated, then finishes this tick for it (finish_crowd_move). dt is this run's length.
	if CrowdMover.current and CrowdMover.current.try_take_move(self, was_grounded, dt):
		return
	_move_with_physics() # Claude 2026-11-16 (pawn spec 8.22): moved into a function, which the CrowdMover's fallback runs too
	_finish_tick() # Claude 2026-11-09: moved into a function, which a sleeping tick runs too


# Claude 2026-11-16 (pawn spec 8.22): one move by physics, as every pawn moved before the CrowdMover: move_and_slide with this run's
# velocity, then whether it's on the floor.
func _move_with_physics() -> void:
	# Claude 2026-11-16: times ticks_elapsed, so a pawn running every Nth tick moves N ticks' worth.
	var factor: float = (_driver.get_physics_factor() if _driver else 1.0) * ticks_elapsed
	velocity *= factor
	var move_started := PerfScopes.begin() # Claude 2026-11-16: timed for diagnostics (PerfScopes)
	move_and_slide()
	PerfScopes.end(&"pawn.move_and_slide", move_started)
	velocity /= factor
	grounded = is_on_floor()


## Claude 2026-11-16 (pawn spec 8.22): the CrowdMover moved this pawn to at, over seconds: it stands there on the ground, its velocity
## is what it really moved (as move_and_slide leaves it), and its tick finishes. Claude 2026-11-16 (the owner's call): the position is
## rounded as the rollback recording will round it (TickStateComponent.round_position), so the recording changes nothing afterwards
## and a still pawn is exactly still, and sleeps. That replaced a millimetre tolerance in the mover, which did the same by hand.
func finish_crowd_move(at: Vector3, seconds: float) -> void: # Claude 2026-11-16 (audit): public, since the CrowdMover calls it
	# The velocity from the real move, before rounding, as move_and_slide leaves it: from the rounded one it would wobble by up to a
	# millimetre a tick, 0.06 m/s at 60 ticks a second.
	var moved := at - global_position
	velocity = Vector3(moved.x, 0.0, moved.z) / seconds if seconds > 0.0 else Vector3.ZERO
	global_position = at
	if _tick_state:
		position = _tick_state.round_position(position) # its own position, as the recording rounds it, not the world one
	grounded = true
	_finish_tick()


## Claude 2026-11-16 (pawn spec 8.22): the CrowdMover couldn't move this pawn (a wall, an edge, no ground under where it was going), so
## it moves by physics now, in the same tick, which handles those, and finishes its tick. Its velocity is still this run's.
func finish_move_by_physics() -> void: # Claude 2026-11-16 (audit): public, since the CrowdMover calls it
	_move_with_physics()
	_finish_tick()


## Claude 2026-11-16: how wide this pawn's body is: its collision capsule's (or sphere's, or cylinder's) radius, scaled, in metres.
## 0.4 without one. Found once.
func get_body_radius() -> float:
	if _body_radius < 0.0:
		_body_radius = 0.4
		var body := get_body_shape()
		if body and (body.shape is CapsuleShape3D or body.shape is SphereShape3D or body.shape is CylinderShape3D):
			_body_radius = float(body.shape.get(&"radius")) * absf(body.global_basis.get_scale().x)
	return _body_radius


## Claude 2026-11-16 (pawn spec 8.22): this pawn's collision shape node (its first CollisionShape3D child with a shape), or null. The
## CrowdMover sweeps it along a move to find walls. Found once.
func get_body_shape() -> CollisionShape3D:
	if _body_shape == null or not is_instance_valid(_body_shape):
		_body_shape = null
		for child in get_children():
			var shape := child as CollisionShape3D
			if shape and shape.shape:
				_body_shape = shape
				break
	return _body_shape


# Claude 2026-11-09: the end of every tick, sleeping or not: where the body is now, for smoothing Visual and for the sleeping check,
# and the input bookkeeping.
func _finish_tick() -> void:
	_current_position = global_position
	_current_yaw = yaw
	# Claude 2026-11-07: the input bookkeeping: what was held this tick, so the next tick can tell a press from a hold, and a tick with
	# real input ends a run of missing ones. Claude 2026-11-16 (pawn M4): the ControllerManager's, with the input.
	if controller_manager:
		controller_manager.finish_tick()


## Claude 2026-11-09: true if this pawn sleeps this tick (pawn spec 15.3). Claude 2026-11-16 (pawn M1): "resting" renamed "sleeping", the standard
## physics name, so it isn't confused with frozen or paused. A pure rule of its state and the tick number, with nothing
## remembered, so nothing extra rolls back and a server and a client predicting it rest on the same ticks. In order of cheapness:
##   - sleep_when_idle is on, it's grounded, its velocity is exactly zero, and it has no move input and no held actions
##   - nothing moved it since its last tick (a teleport, or TerrainBodyLifter raising it)
##   - this isn't one of its check ticks, every sleep_check_ticks, staggered by entity id
##   - its abilities have no timer running and agree (AbilityManager.can_sleep)
##   - Claude 2026-11-10: it has no over-time effect on it to count down (EffectManager.can_sleep)
func _can_sleep(tick: int) -> bool:
	if not sleep_when_idle or not grounded or velocity != Vector3.ZERO:
		return false
	if controller_manager and (controller_manager.move_input != Vector3.ZERO or controller_manager.held_actions != 0): # Claude 2026-11-16 (pawn M4)
		return false
	if global_position != _current_position:
		return false
	if _is_check_tick(tick): # Claude 2026-11-16 (movement experiments): shared with skip_move_when_still
		return false
	if effect_manager and not effect_manager.can_sleep(): # Claude 2026-11-10
		return false
	return ability_manager == null or ability_manager.can_sleep()


# Claude 2026-11-09: one of this pawn's check ticks, every sleep_check_ticks, staggered by entity id, when a sleeping or still pawn runs
# a full tick anyway so ground that went away under it is noticed. Claude 2026-11-16 (movement experiments): moved into its own function.
func _is_check_tick(tick: int) -> bool:
	var stagger: int = _entity.entity_id if _entity and _entity.entity_id >= 0 else get_instance_id()
	# Claude 2026-11-16 (pawn spec 8.21): "< ticks_elapsed" rather than "== 0", so a pawn running every Nth tick still finds the check
	# tick that fell between its runs. With ticks_elapsed 1 it's the same rule as before.
	return posmod(tick + stagger, TickDriver.ticks_at_rate(sleep_check_ticks)) < ticks_elapsed # Claude 2026-11-09 (scaling spec step 6)


## Claude 2026-11-16 (pawn spec 8.21): true if a rule that fires every interval ticks, on the ticks where (tick + offset) is a multiple
## of interval, fired on this tick or on one this pawn skipped since its last run. For the AI's schedules and the like, so a pawn that
## runs every Nth tick keeps them. With ticks_elapsed 1, it's (tick + offset) % interval == 0.
func fired_since_last_run(tick: int, offset: int, interval: int) -> bool:
	return fires_in_run(tick, ticks_elapsed, offset, interval)


## Claude 2026-11-16 (audit): the same rule for any run: true if a rule that fires every interval ticks (where (tick + offset) is a
## multiple of interval) fires on run_tick or on one of the run_length - 1 ticks before it. AISensingManager asks it about a pawn's
## next run, before that run happens, so both use one rule.
static func fires_in_run(run_tick: int, run_length: int, offset: int, interval: int) -> bool:
	return interval <= 1 or posmod(run_tick + offset, interval) < run_length


## Claude 2026-11-16 (profiling the networked mass battle): the tick this pawn will next run after tick, if its step doesn't change
## before then. The same rule as _prepare_run, looking ahead from a tick it ran on: the first later tick that lines up with its step,
## or a whole step on. AISensingManager uses it to ask the worker-thread sensing job in time for a stepping pawn's next run.
func next_run_tick(tick: int) -> int:
	var step := _current_step()
	if step <= 1:
		return tick + 1
	# Claude 2026-11-16 (audit): as a formula: how many ticks until (tick + ahead + stagger) is a multiple of step; none within the step
	# (ahead 0) means a whole step on, when "a whole step has passed" makes it run.
	var ahead := posmod(-(tick + _stagger()), step)
	return tick + (ahead if ahead > 0 else step)


# Claude 2026-11-16 (profiling): the step this pawn runs at now, and the number that spreads a crowd's runs over the ticks. Split out of
# _prepare_run so next_run_tick uses the same rule.
func _current_step() -> int:
	return 1 if _has_a_player() else clampi(tick_step, 1, MAX_TICK_STEP)


func _stagger() -> int:
	return _entity.entity_id if _entity and _entity.entity_id >= 0 else get_instance_id()


## Claude 2026-11-16 (pawn spec 8.21): true while it runs every tick: tick_step 1, or a player has it.
func runs_every_tick() -> bool:
	return tick_step <= 1 or _has_a_player()


# Claude 2026-11-16 (pawn spec 8.21): works out, once per tick, whether this pawn runs this tick and how many ticks the run covers.
# Due when its step is 1, when it's never run, when the tick lines up with its step (spread by its own number), or when a whole step
# has passed since its last run (after its step changed). ticks_elapsed is the ticks since its last run, from 1 to MAX_TICK_STEP.
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
	_prepared_tick = -1 # Claude 2026-11-16 (pawn spec 8.21): worked out again from the loaded _last_run_tick
	# Claude 2026-11-07: previous_held_actions is restored by the TickState itself now, as rollback state.
	var saved_position := position
	var saved_velocity := velocity
	if rebuild_floor_on_rollback: # Claude 2026-11-16 (movement experiments): gated, see rebuild_floor_on_rollback
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
	_tick_input(delta, _fallback_tick) # Claude 2026-11-07
	_tick_simulate(delta, _fallback_tick)


# --- Per rendered frame: only ever reads game state ---


func _process(delta: float) -> void:
	if _visual == null:
		return
	var started := PerfScopes.begin() # Claude 2026-11-16: timed for diagnostics (PerfScopes)
	# Fades over about 100 ms, so the player sees a quick slide rather than a jump (netcode spec section 6.2).
	_correction_offset = _correction_offset.lerp(Vector3.ZERO, 1.0 - exp(-delta / 0.04))
	var fraction: float = _driver.get_interpolation_fraction() if _driver else 1.0
	# Claude 2026-11-16 (pawn spec 8.21): a pawn running every Nth tick moves once per run, so Visual glides across the whole run.
	if _last_run_span > 1 and _driver and is_simulated_here():
		fraction = clampf((float(_driver.tick - _last_run_tick) + fraction) / float(_last_run_span), 0.0, 1.0)
	_visual.global_position = _previous_position.lerp(_current_position, fraction) + _correction_offset
	if _model:
		_model.rotation.y = lerp_angle(_previous_yaw, _current_yaw, fraction)
	PerfScopes.end(&"animation.smoothing", started) # Claude 2026-11-16: was visuals.smoothing, now in diagnostics' animation category


# --- Multiplayer: optional hooks from NetworkEntity ---


## Works for a role that changes while running, as swapping pawns does.
func _on_network_role(entity: NetworkEntity) -> void:
	_entity = entity
	# The server runs it now: it stops doing what the last player's final input said.
	if entity.role == NetworkEntity.Role.AUTHORITY and entity.owner_peer == 0 and controller_manager:
		controller_manager.clear_input()


# Claude 2026-11-16 (pawn M4): sanitize_network_input and _network_input_missing moved to the ControllerManager, NetworkEntity's input_owner.


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


# Claude 2026-11-16 (pawn M2): the game's pawn defaults, for the distances, or null without a PawnInitializer.
func _pawn_defaults() -> PawnDefaultsRes:
	var initializer: PawnInitializer = _game_mode.pawn_initializer if _game_mode else null
	return initializer.defaults if initializer else null


## Claude 2026-11-07: gravity in metres per second per second, from the gravity setting or else the project's.
func _gravity_strength() -> float:
	if gravity >= 0.0:
		return gravity
	return ProjectSettings.get_setting("physics/3d/default_gravity", 9.8)


## False for a pawn on a client that belongs to someone else. Claude 2026-11-16 (pawn M4): public (was _is_simulated_here), since the ControllerManager
## asks it too; deciding whose input this is moved there (ControllerManager.decides_own_input).
func is_simulated_here() -> bool:
	return _entity == null or _entity.is_local or _entity.role == NetworkEntity.Role.AUTHORITY


# Claude 2026-11-16 (pawn M4): true while a player has this pawn (asked of its ControllerManager; a pawn without one never has a player).
func _has_a_player() -> bool:
	return controller_manager != null and controller_manager.has_player()


func _ai_activation_manager() -> AIActivationManager: # Claude 2026-11-07: renamed with the module
	var game_mode: Node = get_node_or_null("/root/GameMode") if is_inside_tree() else null
	return game_mode.ai_activation_manager if game_mode else null
