## Written by Claude (claude-opus-5-5), 2026-11-07: the tier -1 pawn: a body something can possess, with movement in a module.
## No nexus, managers or abilities yet. This is enough to test cameras, nav and netcode with real ground movement. Spec:
## docs/pawn/PLAYER_AND_CAMERA.md. The old CharacterPawn3D is untouched, and carries on working in test scene.tscn.
##
## How to use it: use assets/scenes/pawn/pawn.tscn as it is, or inherit from it. Something writes this pawn's input each tick,
## such as a PlayerController, or an AI script on the server. A GroundMovement child makes that into movement.
##
## What it needs in its scene, all optional:
##   - a MovementModule child. With none, it stands still.
##   - a TickStateComponent and a NetworkEntity child, for rollback and multiplayer. With none, it plays as single player.
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
## What happens in odd cases (all checked in tests/pawn_selftest.gd):
##   - No NetworkTime: it ticks itself from _physics_process.
##   - AI pawn in unloaded ground: AIActivityModule stops its ticks, and it keeps all its state.
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

# This tick's input: what the pawn wants, as plain data. Listed in the TickState, so it goes over the network and rolls back.
var move_input := Vector3.ZERO ## the direction to go, in world space, up to length 1
var wants_sprint := false
var wants_jump := false
var look_yaw := 0.0 ## where the player is looking, which is often not where the pawn is facing
var look_pitch := 0.0

# State that affects the next tick. Listed in the TickState too.
var yaw := 0.0
## Our own copy of "on the floor", because rollback has to restore it, and is_on_floor() can't be set.
var grounded := false

## Which movement module runs. Set it to change how this pawn moves.
var movement: MovementModule = null

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


func _init() -> void:
	floor_snap_length = 0.3
	floor_max_angle = deg_to_rad(50.0)
	# Godot's default margin is exactly 1 mm, and TickState rounds positions to exact 1 mm steps. That parks a standing body on
	# the edge of "touching the floor", so float noise flips the contact. A margin between two steps avoids it.
	safe_margin = 0.0014


func _enter_tree() -> void:
	add_to_group(TerrainBodyLifter.GROUP)
	_driver = get_node_or_null("/root/NetworkTime")
	if _driver:
		_driver.register(self)


func _exit_tree() -> void:
	# Claude 2026-11-07: this first, because leaving the list can switch the pawn back on, which would register it again.
	var ai := _ai_activity()
	if ai:
		ai.remove_pawn(self)
	if _driver:
		_driver.unregister(self)


func _ready() -> void:
	set_physics_process(_driver == null) # the driver calls us. Godot turns this on at ready for any script that defines it
	yaw = rotation.y # whatever the scene placed it at. From here on, the body itself stays unrotated
	rotation = Vector3.ZERO
	for child in get_children():
		if child is MovementModule and movement == null:
			movement = child
		elif child is NetworkEntity:
			_entity = child
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


## PossessionModule tells the pawn. Nothing else should call this.
func set_has_player(value: bool) -> void:
	if _has_player == value:
		return
	_has_player = value
	# Claude 2026-11-07: with nobody driving it, a pawn stands idle. The last tick's input would otherwise repeat forever, which is
	# what happened offline. A later controller manager will hand it to its AI controller here, if it has one.
	if not value and _is_simulated_here():
		_clear_input()
	_refresh_source()
	_refresh_ai_activity()
	possession_changed.emit(self, value)


## What a PlayerController gives the pawn each tick. Direction is in world space.
func apply_player_input(new_move: Vector3, new_look_yaw: float, new_look_pitch: float, new_sprint: bool, new_jump: bool) -> void:
	move_input = new_move
	look_yaw = new_look_yaw
	look_pitch = new_look_pitch
	wants_sprint = new_sprint
	wants_jump = new_jump


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


## AIActivityModule calls this. Everything about the pawn stays as it is, and it simply stops ticking.
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


func _tick_simulate(dt: float, _tick: int) -> void:
	_previous_position = _current_position
	_previous_yaw = _current_yaw
	if movement:
		movement.simulate(self, dt)
	# move_and_slide uses Godot's physics delta. This scales it so that one tick moves velocity * tick dt.
	var factor: float = _driver.get_physics_factor() if _driver else 1.0
	velocity *= factor
	move_and_slide()
	velocity /= factor
	grounded = is_on_floor()
	_current_position = global_position
	_current_yaw = yaw


## TickState restored our properties, but CharacterBody3D also keeps a private "on floor" flag that still holds what the body is
## doing now. Nothing can set it directly, so this makes the engine work it out again, then puts things back.
func _on_state_loaded(_tick: int) -> void:
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
	clean["wants_sprint"] = values.get("wants_sprint", false) is bool and values.get("wants_sprint", false)
	clean["wants_jump"] = values.get("wants_jump", false) is bool and values.get("wants_jump", false)
	for angle: String in ["look_yaw", "look_pitch"]:
		var value: Variant = values.get(angle, 0.0)
		clean[angle] = value if value is float and is_finite(value) else 0.0
	return clean


## On the server: this tick's input never arrived, so the last one repeats. A held direction repeats fine, and a press doesn't.
func _network_input_missing() -> void:
	wants_jump = false


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
	apply_player_input(Vector3.ZERO, look_yaw, look_pitch, false, false)


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


## False for a pawn on a client that belongs to someone else.
func _is_simulated_here() -> bool:
	return _entity == null or _entity.is_local or _entity.role == NetworkEntity.Role.AUTHORITY


## An AI pawn is switched off where there's no ground. A pawn with a source always has ground, so it's never watched.
func _refresh_ai_activity() -> void:
	var ai := _ai_activity()
	if ai == null:
		return
	if _source != null or _has_player or not _is_simulated_here():
		ai.remove_pawn(self)
	else:
		ai.add_pawn(self)


func _ai_activity() -> AIActivityModule:
	var game_mode: Node = get_node_or_null("/root/GameMode") if is_inside_tree() else null
	return game_mode.ai_activity if game_mode else null
