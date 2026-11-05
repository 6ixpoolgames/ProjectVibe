## Written by Claude (claude-opus-5-5), 2026-11-04: sample pawn showing how to hook gameplay onto the tick driver (NetworkTime).
## A teaching example, deliberately all in one script. The real pawn splits these jobs across the controller,
## abilities (Walk, Jump) and the motor (pawn spec), but the tick pattern is exactly this.
##
## What it shows:
##   - registering with NetworkTime, and an escape clause when the autoload is missing
##   - _tick_input: deciding what the pawn WANTS this tick (player keys, or a seeded random wander), as plain data
##   - _tick_simulate: acting on it with the fixed tick dt (steer, turn, gravity, jump, move_and_slide)
##   - rollback: the TickState child node (TickStateComponent) lists move_dir, position, velocity and so on in the
##     inspector, and handles saving, rounding and replaying them. The pawn needs no rollback code. # Claude 2026-11-04
##   - repeatable randomness with NetworkTime.tick_rng, and a cosmetic effect that doesn't replay # Claude 2026-11-04
##   - timers in ticks, seconds only in the inspector
##   - latching a key press between rendered frames and ticks, so a press is never lost or doubled
##   - smoothing the visible model between ticks with the interpolation fraction
##   - multiplayer, with a NetworkEntity child: the _network and _on_network methods near the end. Offline, none of them run # Claude 2026-11-04
extends CharacterBody3D
class_name TickSamplePawn

# Claude 2026-11-04: NETWORK means the input comes from somewhere else: the network code writes it.
enum Brain { PLAYER, WANDER, IDLE, NETWORK }

@export var brain: Brain = Brain.WANDER
@export var body_color: Color = Color(0.85, 0.3, 0.3)
@export_group("Movement")
@export var max_speed: float = 5.0
@export var sprint_multiplier: float = 1.8
@export var acceleration: float = 30.0
@export var deceleration: float = 40.0
@export var turn_rate_deg: float = 720.0
@export var jump_velocity: float = 5.0
@export_group("Wander")
## Seconds between wander decisions; converted to ticks.
@export var wander_change_seconds: float = 1.5
## Claude 2026-11-05: how far ahead a wandering pawn looks for ground, in meters. It has to be further than the pawn travels
## while turning around, about 0.5 m at the default speed. 0 turns the check off.
@export var wander_look_ahead: float = 1.5
## Claude 2026-11-05: ground further below the pawn than this counts as a drop, in meters.
@export var wander_max_drop: float = 1.5
@export_group("Visuals")
## Blend the visible model between ticks. Turn off to see the raw tick steps (most visible at low tick rates).
@export var smooth_visuals: bool = true
@export var model_path: NodePath = ^"Model"

# This tick's input command: what the pawn wants. Plain data, so it could later be sent over the network.
var move_dir := Vector3.ZERO
var wants_sprint := false
var wants_jump := false

# Claude 2026-11-04: our own copy of "on the floor", because rollback has to be able to restore it and
# CharacterBody3D.is_on_floor() can't be set. Listed in TickState's state_properties.
var grounded := false
# Claude 2026-11-04: facing is a plain number, and the physics body itself never rotates; only the model turns. Writing
# rotation every tick goes through Godot's Euler and scale conversion, which adds a float error each time, so the body's
# scale slowly drifted (about 0.99995 in testing) and differently in a replay. That changed the collision capsule's size
# and made the physics results differ. A capsule looks the same from every side, so nothing is lost.
var yaw := 0.0
## How many jump effects have played. Stands in for a sound or particle: only counts real jumps, not replayed ones.
var jump_effects_played := 0

var _driver: Node = null         # the NetworkTime autoload, or null (escape clause: we tick ourselves)
var _fallback_tick := 0
var _jump_latched := false       # set per rendered frame, consumed by the next tick
var _rng := RandomNumberGenerator.new() # only used without the tick driver
var _wander_key := 0
var _next_wander_tick := 0
var _model: Node3D = null
var _model_offset := Transform3D.IDENTITY
var _prev_xform := Transform3D.IDENTITY # body transform before and after the last tick, for smoothing
var _curr_xform := Transform3D.IDENTITY
var _gravity: float = 9.8
var _correction_offset := Vector3.ZERO # Claude 2026-11-04: the visible model's leftover from a correction, fading to nothing


func _enter_tree() -> void:
	add_to_group(&"tick_sample_pawns") # so the sample HUD can find us
	_driver = get_node_or_null("/root/NetworkTime")
	if _driver:
		_driver.register(self)
	else:
		push_warning("[TickSamplePawn] no NetworkTime autoload; ticking from _physics_process instead")


func _exit_tree() -> void:
	if _driver:
		_driver.unregister(self)


func _ready() -> void:
	# The driver calls us, so our own physics callback stays off. This must be in _ready, not _enter_tree:
	# Godot switches _physics_process on at ready for any script that defines it, which would tick us twice.
	set_physics_process(_driver == null)
	# Claude 2026-11-04: Godot's default margin is exactly 1 mm, and TickState rounds positions to exact 1 mm steps. That
	# parks a standing body precisely on the edge of "touching the floor", so float noise flips the contact and the engine
	# snaps it about 6 mm into the floor. A margin between two steps keeps the rounded height clearly inside contact.
	safe_margin = 0.0014
	_gravity = ProjectSettings.get_setting("physics/3d/default_gravity", 9.8)
	_wander_key = hash(String(name)) # the same pawn wanders the same way on every machine
	_rng.seed = _wander_key
	_model = get_node_or_null(model_path)
	if _model:
		_model_offset = _model.transform
		_model.top_level = true # the model is placed by _process, between ticks, not by the body
		_apply_color()
	yaw = rotation.y # whatever the scene placed it at; from here on the body itself stays unrotated
	rotation = Vector3.ZERO
	_prev_xform = _visual_transform()
	_curr_xform = _prev_xform


# --- Phase 1: input -------------------------------------------------------------------------------

func _tick_input(_dt: float, tick: int) -> void:
	match brain:
		Brain.PLAYER:
			var v := Input.get_vector(&"move_left", &"move_right", &"move_forward", &"move_backward")
			move_dir = _camera_relative(v)
			wants_sprint = Input.is_action_pressed(&"move_sprint")
			wants_jump = _jump_latched
			_jump_latched = false
		Brain.WANDER:
			if tick >= _next_wander_tick:
				# Claude 2026-11-04: tick_rng rolls repeat on every machine and in a replay, with no generator state to save
				var rng: RandomNumberGenerator = _driver.tick_rng(_wander_key) if _driver else _rng
				var angle := rng.randf() * TAU
				var walking := rng.randf() > 0.25 # sometimes stand still for a while
				move_dir = Vector3(cos(angle), 0.0, sin(angle)) if walking else Vector3.ZERO
				_next_wander_tick = tick + _seconds_to_ticks(wander_change_seconds)
			# Claude 2026-11-05: checked every tick, since one wander decision can walk about 7 m. Wandering pawns kept walking
			# off the floor in the samples. This runs only where the wander is decided, never in a replay or on a client.
			move_dir = _away_from_drops(move_dir)
			wants_sprint = false
			wants_jump = false
		Brain.IDLE:
			move_dir = Vector3.ZERO
			wants_sprint = false
			wants_jump = false
		Brain.NETWORK:
			pass # already written by NetworkEntity, or held from last time


# --- Phase 2: simulate ----------------------------------------------------------------------------

func _tick_simulate(dt: float, _tick: int) -> void:
	_prev_xform = _visual_transform()

	# Steer: accelerate the horizontal velocity toward what we want (Walk's job in the real pawn).
	var speed := max_speed * (sprint_multiplier if wants_sprint else 1.0)
	var target := move_dir.limit_length(1.0) * speed
	var horizontal := Vector3(velocity.x, 0.0, velocity.z)
	var rate := acceleration if target.length_squared() > 0.0001 else deceleration
	horizontal = horizontal.move_toward(target, rate * dt)
	velocity.x = horizontal.x
	velocity.z = horizontal.z

	# Gravity and jump (the motor's and Jump's jobs).
	# Claude 2026-11-04: reads our own grounded, not is_on_floor(), so a replay starts from the restored value. The input
	# is no longer cleared here, because a replay restores it per tick and it's only read in this tick.
	if not grounded:
		velocity.y -= _gravity * dt
	elif wants_jump:
		velocity.y = jump_velocity
		if not (_driver and _driver.is_resimulating()):
			jump_effects_played += 1 # a real game plays a sound here; a replay must not play it again

	# Face where we're moving. Godot's forward is -Z.
	if horizontal.length_squared() > 0.01:
		var target_yaw := atan2(-horizontal.x, -horizontal.z)
		yaw = rotate_toward(yaw, target_yaw, deg_to_rad(turn_rate_deg) * dt)

	# move_and_slide uses Godot's physics delta; scale so one tick moves velocity * tick dt.
	var factor: float = _driver.get_physics_factor() if _driver else 1.0
	velocity *= factor
	move_and_slide()
	velocity /= factor
	grounded = is_on_floor() # Claude 2026-11-04: see the note on grounded above

	_curr_xform = _visual_transform()


# --- After a rollback load -------------------------------------------------------------------------

## Claude 2026-11-04: TickState restored our properties, but CharacterBody3D also keeps a private "on floor" flag that
## still holds what the body is doing NOW. Left alone, move_and_slide would snap an airborne pawn down to the floor or
## drop a grounded one out of its floor contact on the first replayed tick. Nothing can set that flag directly, so this
## makes the engine work it out again, then puts position and velocity back. The real motor will do the same.
func _on_state_loaded(_tick: int) -> void:
	var saved_position := position
	var saved_velocity := velocity
	var saved_snap := floor_snap_length
	floor_snap_length = 0.0 # stops the stale flag snapping us while we refresh it
	velocity = Vector3.ZERO
	move_and_slide()
	floor_snap_length = saved_snap
	if grounded and not is_on_floor():
		apply_floor_snap()
	position = saved_position
	velocity = saved_velocity
	# Keep the visible model honest even if no ticks get replayed after this load.
	_prev_xform = _visual_transform()
	_curr_xform = _prev_xform


# --- Per rendered frame: presses and visuals ------------------------------------------------------

func _process(_delta: float) -> void:
	# A press lasts one rendered frame. Ticks may run zero or several times per frame, so remember the
	# press until the next tick takes it, instead of reading is_action_just_pressed inside the tick.
	if brain == Brain.PLAYER and Input.is_action_just_pressed(&"move_jump"):
		_jump_latched = true

	# Claude 2026-11-04: a correction moves the body at once. The model keeps the difference and fades it over about 100 ms,
	# so the player sees a quick slide rather than a jump (netcode spec section 6.2).
	_correction_offset = _correction_offset.lerp(Vector3.ZERO, 1.0 - exp(-_delta / 0.04))
	if _model:
		var f: float = 1.0
		if smooth_visuals and _driver:
			f = _driver.get_interpolation_fraction()
		var placed := _prev_xform.interpolate_with(_curr_xform, f) * _model_offset
		placed.origin += _correction_offset
		_model.global_transform = placed


# --- Multiplayer --------------------------------------------------------------------------------
# Claude 2026-11-04: all optional hooks from NetworkEntity. A real pawn would have the same ones.

## Before entering the tree: where does our input come from? Your own pawn reads the keys. Anything a client owns, on the
## server, gets its input from the network. A pawn nobody owns keeps the brain it has, which is how AI runs on the server.
func _on_network_role(entity: NetworkEntity) -> void:
	if entity.is_local:
		brain = Brain.PLAYER
	elif entity.owner_peer != 0 or entity.role != NetworkEntity.Role.AUTHORITY:
		brain = Brain.NETWORK


## On the server: a client's input is never trusted. Wrong types are replaced, and direction is limited to full speed.
func sanitize_network_input(values: Dictionary) -> Dictionary:
	var clean := values.duplicate()
	var wanted: Variant = values.get("move_dir", Vector3.ZERO)
	clean["move_dir"] = wanted.limit_length(1.0) if wanted is Vector3 and wanted.is_finite() else Vector3.ZERO
	clean["wants_sprint"] = values.get("wants_sprint", false) is bool and values.get("wants_sprint", false)
	clean["wants_jump"] = values.get("wants_jump", false) is bool and values.get("wants_jump", false)
	return clean


## On the server: this tick's input never arrived, so the last one repeats. A held direction repeats fine, a press doesn't.
func _network_input_missing() -> void:
	wants_jump = false


## On a client, for a pawn someone else controls: it was just moved between snapshots, so the model follows.
func _on_network_interpolated() -> void:
	_prev_xform = _curr_xform
	_curr_xform = _visual_transform()


## On a client: a correction moved our body by this much.
func _on_network_corrected(jump: Variant) -> void:
	if jump is Vector3:
		_correction_offset += jump


# --- Escape clause: no tick driver ----------------------------------------------------------------

func _physics_process(delta: float) -> void:
	_fallback_tick += 1
	_tick_input(delta, _fallback_tick)
	_tick_simulate(delta, _fallback_tick)


# --- Helpers ----------------------------------------------------------------------------------------

## Where the model should be: the body's position, turned to our facing.
func _visual_transform() -> Transform3D:
	return Transform3D(Basis(Vector3.UP, yaw), global_position)


## Claude 2026-11-05: keeps a wander on the ground. If there's no ground ahead it turns around, and if there's none behind
## either it stands still. A simple stand-in for real navigation: it only sees drops, and walls are left to move_and_slide.
func _away_from_drops(direction: Vector3) -> Vector3:
	if wander_look_ahead <= 0.0 or direction == Vector3.ZERO or _has_ground_toward(direction):
		return direction
	return -direction if _has_ground_toward(-direction) else Vector3.ZERO


## Claude 2026-11-05: a ray straight down, wander_look_ahead in front of us. It starts 1 m up so that it also finds a slope rising ahead.
func _has_ground_toward(direction: Vector3) -> bool:
	var ahead := global_position + direction.normalized() * wander_look_ahead
	var ray := PhysicsRayQueryParameters3D.create(ahead + Vector3.UP, ahead + Vector3.DOWN * wander_max_drop, collision_mask, [get_rid()])
	return not get_world_3d().direct_space_state.intersect_ray(ray).is_empty()


func _seconds_to_ticks(seconds: float) -> int:
	if _driver:
		return _driver.seconds_to_ticks(seconds)
	return maxi(1, ceili(seconds * Engine.physics_ticks_per_second))


## Turns stick/WASD input into a world direction relative to the camera's facing (flattened).
func _camera_relative(v: Vector2) -> Vector3:
	var cam := get_viewport().get_camera_3d() if is_inside_tree() else null
	if cam == null:
		return Vector3(v.x, 0.0, v.y)
	var forward := -cam.global_basis.z
	forward.y = 0.0
	var right := cam.global_basis.x
	right.y = 0.0
	return right.normalized() * v.x + forward.normalized() * -v.y


func _apply_color() -> void:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = body_color
	for child in _model.find_children("*", "MeshInstance3D", true, false):
		child.material_override = mat
