## Written by Claude (claude-opus-5-5), 2026-11-07: the tier -1 pawn: a body something can possess, with movement in a module.
## No nexus, managers or abilities yet. This is enough to test cameras, nav and netcode with real ground movement. Spec:
## docs/pawn/PLAYER_AND_CAMERA.md. Claude 2026-11-07: it now has managers and abilities (docs/pawn/PAWN_SPEC.md); still no nexus. The old CharacterPawn3D is untouched, and carries on working in test scene.tscn.
##
## How to use it: use assets/scenes/pawn/pawn.tscn as it is, or inherit from it. Something writes this pawn's input each tick,
## such as a PlayerController, or an AI script on the server. Its abilities make that into movement.
##
## Claude 2026-11-07: parts and input, pawn spec steps 3 to 6.
##   - When it enters the tree, GameMode's PawnInitializer adds the default parts its scene doesn't have: ControllerManager (with an
##     AIController), StatManager (with movement stats) and AbilityManager (with Walk, Jump and Sprint). fill_in_default_parts and
##     skip_default_parts opt out.
##   - Each tick, in its input phase, it asks its ControllerManager for input from whoever is in charge: this machine's player, or
##     else its AI controller. It only asks where its input is decided here. A client's pawn on the server gets its input over the
##     network instead.
##   - Each tick, its AbilityManager runs the abilities, which write velocity and facing. Then the pawn adds gravity and makes the one
##     move_and_slide call. Claude 2026-11-07: this replaced GroundMovement and MovementModule, which are gone.
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
##
## What happens in odd cases (all checked in tests/pawn_selftest.gd):
##   - No TickDriver: it ticks itself from _physics_process.
##   - AI pawn in unloaded ground: AIActivationManager stops its ticks, and it keeps all its state.
##   - On the server, a client's input goes missing: the last one repeats for missing_input_hold_ticks, then its direction fades out
##     over missing_input_fade_ticks. Held actions keep repeating, so a key still held when input comes back isn't a new press. Both
##     settings default to -1, which uses NetworkSession's settings of the same names.
class_name Pawn
extends CharacterBody3D

## Sent when a player takes this pawn, or lets it go.
signal possession_changed(pawn: Pawn, has_player: bool)

## Whether a player may take control of this pawn. Turn it off on pawns players should never control.
# Claude 2026-11-07: on by default, the owner's choice. Off, people would be left wondering why their pawn doesn't work. Something
# still has to ask for a possession, so a wrong one is a clear bug that gets looked at.
@export var possessable := true
## On: an AI pawn keeps the world loaded around it, as a player's pawn always does. Off, it's switched off wherever no
## source keeps the ground loaded, which is what you want for a horde.
@export var ai_loads_chunks := false:
	set(value):
		ai_loads_chunks = value
		_refresh_source()
## On: the camera arm exists all the time, so taking this pawn has no delay at all. For a handful of hero pawns. Leave it off
## for anything there are many of, or a horde gets thousands of arms that do nothing.
@export var always_has_camera_arm := false
## How far this pawn keeps the world loaded, when it does, in metres.
@export var streaming_load_distance := 320.0
## How far nav is built around it, in metres.
@export var streaming_nav_distance := 128.0
## The arm's settings, for a pawn that wants its own. Empty means the defaults.
@export var camera_preset: CameraPreset
## On the server: when a client's input goes missing, the last one repeats in full for this many ticks. -1 uses NetworkSession's
## setting of the same name, which is the game-wide rule. Set a number only for a pawn that needs its own.
# Claude 2026-11-07: -1 by default, so the rule is set once per game on NetworkSession rather than on every pawn.
@export_range(-1, 60, 1, "or_greater") var missing_input_hold_ticks := -1
## Then its direction fades to nothing over this many ticks. -1 uses NetworkSession's setting.
@export_range(-1, 60, 1, "or_greater") var missing_input_fade_ticks := -1
## Claude 2026-11-07: on, GameMode's PawnInitializer adds every default part this pawn's scene doesn't already have. Off, the pawn
## gets only what its scene has.
@export var fill_in_default_parts := true
## Claude 2026-11-07: how strongly it falls, in metres per second per second. Below 0, the project's gravity setting. Moved here from
## GroundMovement: the pawn adds gravity, and abilities only steer.
@export var gravity := -1.0
## Claude 2026-11-07: default parts to leave out, by name, such as &"AbilityManager". A part with that name in the scene is kept
## either way.
@export var skip_default_parts: Array[StringName] = []

# This tick's input, as plain data. Listed in the TickState, so it goes over the network and rolls back.
var move_input := Vector3.ZERO ## the direction to go, in world space, up to length 1
# Claude 2026-11-07: replaces wants_sprint and wants_jump. Bits from InputActions.
var held_actions := 0 ## which named actions are held this tick
var look_yaw := 0.0 ## where the player is looking, which is often not where the pawn is facing
var look_pitch := 0.0

# State that affects the next tick. Listed in the TickState too.
## Claude 2026-11-07: last tick's held_actions, so a press can be told from a hold. It's in the TickState's state list, so the
## server's value reaches clients in snapshots and a correction fixes it, like position. From the audit of 6df1464: reading it back
## from the client's own saved input instead went wrong when the server never got a press. Protocol 5 made it 2 bytes per pawn.
var previous_held_actions := 0
var yaw := 0.0
## Our own copy of "on the floor", because rollback has to restore it, and is_on_floor() can't be set.
var grounded := false

## Claude 2026-11-07: runs this pawn's abilities, which steer it. Null if it has none. Replaces the old movement module.
var ability_manager: AbilityManager = null
## Claude 2026-11-07: this pawn's stats, which abilities read. Null if it has none, and then abilities use their fallbacks.
var stat_manager: StatManager = null
## Claude 2026-11-07: picks whose input this pawn follows. Null if the pawn has none, and then nothing writes its input for it.
var controller_manager: ControllerManager = null

var _driver: Node = null
var _entity: NetworkEntity = null
var _has_player := false
var _source: StreamingSource = null
var _visual: Node3D = null
var _model: Node3D = null
var _previous_position := Vector3.ZERO # the body before and after the last tick, for smoothing Visual
var _current_position := Vector3.ZERO
var _previous_yaw := 0.0
var _current_yaw := 0.0
var _correction_offset := Vector3.ZERO # what's left of a correction, fading to nothing
var _fallback_tick := 0
var _simulating := true
var _missing_input_ticks := 0 # on the server: how many ticks in a row a client's input has been missing
var _input_missing_this_tick := false


func _init() -> void:
	floor_snap_length = 0.3
	floor_max_angle = deg_to_rad(50.0)
	# Godot's default margin is exactly 1 mm, and TickState rounds positions to exact 1 mm steps. That parks a standing body on
	# the edge of "touching the floor", so float noise flips the contact. A margin between two steps avoids it.
	safe_margin = 0.0014


func _enter_tree() -> void:
	add_to_group(TerrainBodyLifter.GROUP)
	# Claude 2026-11-07: default parts first, so they're children before anything below or any _ready looks for them. A node may
	# add children to itself here: Godot enters them right after.
	var game_mode: Node = get_node_or_null("/root/GameMode")
	if game_mode and game_mode.pawn_initializer:
		game_mode.pawn_initializer.initialize(self)
	_driver = get_node_or_null("/root/TickDriver")
	if _driver:
		_driver.register(self)


func _exit_tree() -> void:
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
		elif child is NetworkEntity:
			_entity = child
		elif child is ControllerManager and controller_manager == null: # Claude 2026-11-07
			controller_manager = child
	_visual = get_node_or_null(^"Visual")
	if _visual:
		_visual.top_level = true # it's placed by _process, between ticks, not by the body
		_model = _visual.get_node_or_null(^"Model")
	_previous_position = global_position
	_current_position = global_position
	_previous_yaw = yaw
	_current_yaw = yaw
	_refresh_source()
	_refresh_ai_activity()
	if always_has_camera_arm:
		make_camera_arm()


# --- Things other scripts can call ---


## True if a player controls this pawn. On a client, that's any player, not only this machine's.
func has_player() -> bool:
	return _has_player


## PossessionCoordinator tells the pawn. Nothing else should call this.
func set_has_player(value: bool) -> void:
	if _has_player == value:
		return
	_has_player = value
	# Claude 2026-11-07: with nobody driving it, a pawn stands idle. The last tick's input would otherwise repeat forever, which is
	# what happened offline. Claude 2026-11-07: from the next tick its ControllerManager hands it to its AI controller, if it has one.
	if not value and _is_simulated_here():
		_clear_input()
	_refresh_source()
	_refresh_ai_activity()
	possession_changed.emit(self, value)


## What a controller gives the pawn each tick.
# Claude 2026-11-07: replaces apply_player_input(move, yaw, pitch, sprint, jump).
func apply_input(command: InputCommand) -> void:
	move_input = command.move
	look_yaw = command.look_yaw
	look_pitch = command.look_pitch
	held_actions = command.held_actions


## True while this named action is held, such as &"sprint".
func is_action_held(action: StringName) -> bool:
	return held_actions & InputActions.mask_of(action) != 0


## True on the one tick this named action became held, such as &"jump". Holding it down doesn't repeat it.
func was_action_pressed(action: StringName) -> bool:
	var bit := InputActions.mask_of(action)
	return held_actions & bit != 0 and previous_held_actions & bit == 0


## The node that follows the body smoothly, for hanging things from. With no Visual, it's the body.
func get_visual() -> Node3D:
	return _visual if _visual else self


## This pawn's arm, or null. An arm placed in the scene counts.
func get_camera_arm() -> CameraArm:
	var parent := get_visual()
	for child in parent.get_children():
		if child is CameraArm:
			return child
	return null


## Makes the arm, from camera_preset or the defaults, if there isn't one. It's created idle.
func make_camera_arm() -> CameraArm:
	var arm := get_camera_arm()
	if arm:
		return arm
	arm = CameraArm.new()
	arm.name = "CameraArm"
	arm.preset = camera_preset if camera_preset else CameraPreset.new()
	arm.spawned_by_possession = not always_has_camera_arm
	get_visual().add_child(arm)
	arm.ignore_body(self)
	return arm


## The view a camera should attach to when this pawn is possessed: the first VirtualCamera in its scene, or null.
func get_default_view() -> VirtualCamera:
	var arm := get_camera_arm()
	if arm:
		return arm.get_view()
	return _find_view(self)


## AIActivationManager calls this. Everything about the pawn stays as it is, and it simply stops ticking.
# Claude 2026-11-07: through the NetworkEntity, because it decides what ticks. This only stopped the pawn itself, and left its entity and
# TickState running: 2,000 pawns that were off still cost 53 ms a tick.
func set_simulation_active(active: bool) -> void:
	if _simulating == active:
		return
	_simulating = active
	if _driver == null:
		set_physics_process(active)
	elif _entity:
		_entity.set_paused(not active)
	elif active:
		_driver.register(self)
	else:
		_driver.unregister(self)


func is_simulation_active() -> bool:
	return _simulating


# --- Ticks ---


## Claude 2026-11-07: the input phase. Asks the controller in charge for this tick's input, where this pawn's input is decided here.
## A script that writes input itself, such as a test brain, can still do so later in the same phase and win.
func _tick_input(_dt: float, tick: int) -> void:
	if controller_manager == null or not _decides_own_input():
		return
	var command := controller_manager.take_input_command(tick)
	if command:
		apply_input(command)


func _tick_simulate(dt: float, _tick: int) -> void:
	_previous_position = _current_position
	_previous_yaw = _current_yaw
	# Claude 2026-11-07: abilities steer, then gravity, then one move_and_slide. Gravity goes by whether it was on the ground when the
	# tick began, as GroundMovement did, so a jump that starts this tick isn't pulled down in the same tick.
	var was_grounded := grounded
	if ability_manager:
		ability_manager.tick_abilities(dt)
	if not was_grounded:
		velocity.y -= _gravity_strength() * dt
	# move_and_slide uses Godot's physics delta. This scales it so that one tick moves velocity * tick dt.
	var factor: float = _driver.get_physics_factor() if _driver else 1.0
	velocity *= factor
	move_and_slide()
	velocity /= factor
	grounded = is_on_floor()
	_current_position = global_position
	_current_yaw = yaw
	# Claude 2026-11-07: what was held this tick, so the next tick can tell a press from a hold.
	previous_held_actions = held_actions
	# Claude 2026-11-07: a tick with real input ends a run of missing ones.
	if not _input_missing_this_tick:
		_missing_input_ticks = 0
	_input_missing_this_tick = false


## TickState restored our properties, but CharacterBody3D also keeps a private "on floor" flag that still holds what the body is
## doing now. Nothing can set it directly, so this makes the engine work it out again, then puts things back.
func _on_state_loaded(_tick: int) -> void:
	# Claude 2026-11-07: previous_held_actions is restored by the TickState itself now, as rollback state.
	var saved_position := position
	var saved_velocity := velocity
	var saved_snap := floor_snap_length
	floor_snap_length = 0.0
	velocity = Vector3.ZERO
	move_and_slide()
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
	# Fades over about 100 ms, so the player sees a quick slide rather than a jump (netcode spec section 6.2).
	_correction_offset = _correction_offset.lerp(Vector3.ZERO, 1.0 - exp(-delta / 0.04))
	var fraction: float = _driver.get_interpolation_fraction() if _driver else 1.0
	_visual.global_position = _previous_position.lerp(_current_position, fraction) + _correction_offset
	if _model:
		_model.rotation.y = lerp_angle(_previous_yaw, _current_yaw, fraction)


# --- Multiplayer: optional hooks from NetworkEntity ---


## Works for a role that changes while running, as swapping pawns does.
func _on_network_role(entity: NetworkEntity) -> void:
	_entity = entity
	# The server runs it now: it stops doing what the last player's final input said.
	if entity.role == NetworkEntity.Role.AUTHORITY and entity.owner_peer == 0:
		_clear_input()
	if is_node_ready():
		_refresh_source()
		_refresh_ai_activity()


## On the server: a client's input is never trusted. Wrong types are replaced, and direction is limited to full speed.
func sanitize_network_input(values: Dictionary) -> Dictionary:
	var clean := values.duplicate()
	var wanted: Variant = values.get("move_input", Vector3.ZERO)
	clean["move_input"] = wanted.limit_length(1.0) if wanted is Vector3 and wanted.is_finite() else Vector3.ZERO
	# Claude 2026-11-07: replaces the two bools. Bits for actions that aren't listed are thrown away.
	var held: Variant = values.get("held_actions", 0)
	clean["held_actions"] = held & InputActions.all_listed_mask() if held is int else 0
	for angle: String in ["look_yaw", "look_pitch"]:
		var value: Variant = values.get(angle, 0.0)
		clean[angle] = value if value is float and is_finite(value) else 0.0
	return clean


## On the server: this tick's input never arrived, so the last one repeats. A held direction repeats fine, and a press doesn't.
# Claude 2026-11-07: a press can't repeat any more, because a repeated hold isn't "newly held". New: after missing_input_hold_ticks,
# the direction fades out. Held actions are left alone, so a key still held when input comes back doesn't count as a new press.
func _network_input_missing() -> void:
	_input_missing_this_tick = true
	_missing_input_ticks += 1
	# Claude 2026-11-07: -1 means NetworkSession's rule. With no session at all, 3 and 6, the same as its defaults.
	var session: Node = get_node_or_null("/root/NetworkSession")
	var hold: int = missing_input_hold_ticks if missing_input_hold_ticks >= 0 else (session.missing_input_hold_ticks if session else 3)
	var fade: int = missing_input_fade_ticks if missing_input_fade_ticks >= 0 else (session.missing_input_fade_ticks if session else 6)
	if _missing_input_ticks <= hold:
		return
	if fade <= 0:
		move_input = Vector3.ZERO
	else:
		# A full-length direction reaches zero in "fade" ticks. A shorter one gets there sooner.
		move_input = move_input.move_toward(Vector3.ZERO, 1.0 / fade)


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


func _find_view(node: Node) -> VirtualCamera:
	for child in node.get_children():
		if child is VirtualCamera:
			return child
		var found := _find_view(child)
		if found:
			return found
	return null


func _clear_input() -> void:
	# Claude 2026-11-07: keeps the look direction, as before.
	move_input = Vector3.ZERO
	held_actions = 0


## A pawn only has a source if something wants the world kept loaded around it, so a horde doesn't carry thousands of them.
func _refresh_source() -> void:
	if not is_inside_tree():
		return
	# On a client, another player's pawn needs nothing loaded here. It's drawn from snapshots.
	var wanted := _is_simulated_here() and (_has_player or ai_loads_chunks)
	if wanted and _source == null:
		_source = StreamingSource.new()
		_source.name = "StreamingSource"
		_source.load_distance = streaming_load_distance
		_source.nav_distance = streaming_nav_distance
		add_child(_source)
	elif not wanted and _source != null:
		_source.queue_free()
		_source = null


## Claude 2026-11-07: gravity in metres per second per second, from the gravity setting or else the project's.
func _gravity_strength() -> float:
	if gravity >= 0.0:
		return gravity
	return ProjectSettings.get_setting("physics/3d/default_gravity", 9.8)


## Claude 2026-11-07: true where this pawn's input is decided: offline, its owner's machine, or the server for a pawn nobody owns. False
## on the server for a client's pawn, whose input arrives over the network, and on a client for anyone else's pawn.
func _decides_own_input() -> bool:
	return _entity == null or _entity.is_local or (_entity.role == NetworkEntity.Role.AUTHORITY and _entity.owner_peer == 0)


## False for a pawn on a client that belongs to someone else.
func _is_simulated_here() -> bool:
	return _entity == null or _entity.is_local or _entity.role == NetworkEntity.Role.AUTHORITY


## An AI pawn is switched off where there's no ground. A pawn with a source always has ground, so it's never watched.
func _refresh_ai_activity() -> void:
	var ai := _ai_activation_manager()
	if ai == null:
		return
	if _source != null or _has_player or not _is_simulated_here():
		ai.remove_pawn(self)
	else:
		ai.add_pawn(self)


func _ai_activation_manager() -> AIActivationManager: # Claude 2026-11-07: renamed with the module
	var game_mode: Node = get_node_or_null("/root/GameMode") if is_inside_tree() else null
	return game_mode.ai_activation_manager if game_mode else null
