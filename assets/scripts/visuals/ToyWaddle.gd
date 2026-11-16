## Written by Claude (claude-opus-5-5), 2026-11-12: makes a pawn's model move like a toy being played with, the owner's request: it
## rocks from side to side and hops a little with each step instead of walking with legs, leans into a dash, tips back when knocked
## back, and falls over when it dies. Put it under the pawn's Visual/Model, with nothing else needed: it makes the model itself from
## toy_scene, and stands it on a coloured base like a figurine's, so teams can be told apart.
##
## What it is and isn't:
##   - Visual only. It runs once per rendered frame (_process), only reads the pawn, and changes nothing the game simulates, so it
##     needs no rollback and works the same on the server, on a client predicting its own pawn, and on a client drawing other pawns.
##   - It moves only itself (this node). The pawn turns Visual/Model to face the way the pawn faces, and this sits inside that, so
##     "forward" here is always the pawn's forward (-Z) and "side to side" is its left and right.
##   - Its origin is at the pawn's feet, so rocking and tipping over pivot on the ground, as a toy standing on a table does.
##
## How fast it waddles comes from how fast the drawn model moves (Visual, smoothed between ticks), not from the pawn's velocity, so
## a pawn drawn from snapshots on a client waddles too. The step rate grows with speed: steps_per_metre steps for every metre.
##
## The model: toy_scene is instanced as a child at toy_scale (turned round if turn_model_round is on). If it has an AnimationPlayer,
## the first frame of pose_animation holds the model in a still pose for the waddle to move.
## Claude 2026-11-16 (with the owner's call not to track the sword on a server): with no display (a headless server or test), the figure
## isn't built and its per-frame waddle never runs, since nothing can see it (RunEnvironment.runs_visuals). A host playing in a window
## still draws it.
class_name ToyWaddle
extends Node3D

## The model to show, such as a Kenney character's .glb. Empty: nothing is made, and this only moves whatever children it already has.
@export var toy_scene: PackedScene
## How much bigger the model is drawn. Kenney's mini characters are about 0.8 m tall; 2.2 makes them about the height of the pawn's
## 1.8 m capsule.
@export_range(0.1, 10.0, 0.05, "or_greater") var toy_scale := 2.2
## On: the model is turned round 180 degrees, for a model that faces +Z, as Kenney's characters do (glTF's front is +Z). The pawn's
## forward is -Z.
@export var turn_model_round := true
## The animation whose first frame holds the model still, if it has an AnimationPlayer with one. Kenney's characters have "idle",
## whose first frame has the arms down ("static" holds them straight out).
@export var pose_animation: StringName = &"idle"
## The colour of the round base the figure stands on, like a toy figurine's. Fully clear (alpha 0): no base.
@export var stand_color := Color(0.9, 0.75, 0.3, 1.0)
## The base's radius, in metres.
@export_range(0.05, 3.0, 0.01, "or_greater") var stand_radius := 0.45

@export_group("Waddle")
## How far it rocks from side to side at full walking speed, in degrees each way.
@export_range(0.0, 45.0, 0.5) var rock_degrees := 10.0
## How high each step's little hop is at full walking speed, in metres.
@export_range(0.0, 1.0, 0.01) var hop_height := 0.09
## Steps per metre walked. Each step is one rock to a side and one hop.
@export_range(0.1, 10.0, 0.1, "or_greater") var steps_per_metre := 1.6
## How far it leans forward while moving at full walking speed, in degrees.
@export_range(0.0, 45.0, 0.5) var lean_degrees := 6.0
## The speed counted as full walking speed, in metres per second, for the amounts above. Faster (sprinting) rocks and hops a little
## more, up to one and a half times.
@export_range(0.1, 20.0, 0.1, "or_greater") var walk_speed := 5.0
## Standing still: how far it bobs up and down, in metres, and how many times a second.
@export_range(0.0, 0.2, 0.005) var breathe_height := 0.015
@export_range(0.0, 5.0, 0.05) var breathe_rate := 0.8

@export_group("Moments")
## While dashing: how far it leans forward, in degrees.
@export_range(0.0, 80.0, 0.5) var dash_lean_degrees := 28.0
## While being knocked back: how far it tips backward, in degrees.
@export_range(0.0, 80.0, 0.5) var knockback_tilt_degrees := 22.0
## While off the ground: how far it tilts back, in degrees.
@export_range(0.0, 45.0, 0.5) var air_tilt_degrees := 8.0
## When it dies: how far it falls over onto its side, in degrees (90 is flat), and how fast it settles there.
@export_range(0.0, 120.0, 1.0) var death_fall_degrees := 90.0
## How quickly it eases toward a new lean or tilt: higher is snappier. Each frame it closes this fraction of the gap per second,
## roughly; 12 settles in about a quarter of a second.
@export_range(0.5, 60.0, 0.5, "or_greater") var ease_rate := 12.0

var _pawn: Pawn = null
var _visual: Node3D = null
var _bound := false
var _toy: Node3D = null
var _dash: AbilityBase = null
var _knockback: AbilityBase = null
var _last_position := Vector3.ZERO
var _speed := 0.0 # metres per second the drawn model moves, smoothed
var _step_phase := 0.0 # in radians: one step is half a turn
var _breath_phase := 0.0
var _lean := 0.0 # radians, forward is negative (see _process)
var _fall := 0.0 # radians, toward the pawn's right side


func _ready() -> void:
	# Claude 2026-11-16: nothing to draw on, so nothing to build or move (see the top of the file).
	if not RunEnvironment.runs_visuals():
		set_process(false)
		return
	_pawn = _find_pawn()
	if toy_scene:
		_toy = toy_scene.instantiate() as Node3D
		if _toy:
			_toy.scale = Vector3.ONE * toy_scale
			if turn_model_round:
				_toy.rotation.y = PI
			add_child(_toy)
			_hold_pose(_toy)
	if stand_color.a > 0.0:
		add_child(_make_stand())


# The pawn's Visual and abilities, found on the first frame. Not in _ready: a pawn finds its own parts in its _ready, which Godot runs
# after its children's, this one included.
func _bind() -> void:
	_bound = true
	_visual = _pawn.get_visual()
	# GDScript note: "is" checks the class, so a scene's own Dash subclass counts.
	if _pawn.ability_manager:
		for ability in _pawn.ability_manager.get_abilities():
			if ability is DashAbility and _dash == null:
				_dash = ability
			elif ability is KnockbackAbility and _knockback == null:
				_knockback = ability
	_last_position = _visual.global_position


func _process(delta: float) -> void:
	var started := PerfScopes.begin() # Claude 2026-11-16: timed for diagnostics (PerfScopes)
	_animate(delta)
	PerfScopes.end(&"animation.waddle", started) # Claude 2026-11-16: was visuals.waddle, now in diagnostics' animation category


# Claude 2026-11-16: the work itself, timed by _process.
func _animate(delta: float) -> void:
	if _pawn == null or delta <= 0.0:
		return
	if not _bound:
		_bind()
	# How fast the drawn model moves along the ground, smoothed so a correction's jump doesn't make it hop wildly.
	var at := _visual.global_position
	var moved := at - _last_position
	moved.y = 0.0
	_last_position = at
	# Claude 2026-11-12: named blend, not ease, which is one of Godot's own functions (the editor warned about the clash).
	var blend := 1.0 - exp(-ease_rate * delta) # GDScript note: exp() gives the same easing at any frame rate
	_speed = lerpf(_speed, moved.length() / delta, blend)
	var dead := _pawn.is_dead()
	var amount := 0.0 if dead else clampf(_speed / walk_speed, 0.0, 1.5) # 0 standing, 1 walking, up to 1.5 sprinting

	# Steps: the phase moves on with distance, so a step always covers the same ground, whatever the speed.
	_step_phase = fmod(_step_phase + _speed * delta * steps_per_metre * PI, TAU)
	_breath_phase = fmod(_breath_phase + delta * breathe_rate * TAU, TAU)
	var rock := sin(_step_phase) * deg_to_rad(rock_degrees) * minf(amount, 1.5)
	var hop := absf(sin(_step_phase)) * hop_height * minf(amount, 1.5)
	var breathe := (sin(_breath_phase) * 0.5 + 0.5) * breathe_height * clampf(1.0 - amount * 2.0, 0.0, 1.0)

	# Leaning: forward (top toward -Z) is a negative turn about X, backward positive. The strongest moment wins.
	var lean_target := -deg_to_rad(lean_degrees) * minf(amount, 1.0)
	if not _pawn.grounded:
		lean_target = deg_to_rad(air_tilt_degrees)
	if _knockback and _knockback.is_running_timed():
		lean_target = deg_to_rad(knockback_tilt_degrees)
	if _dash and _dash.is_running_timed():
		lean_target = -deg_to_rad(dash_lean_degrees)
	if dead:
		lean_target = 0.0
	_lean = lerpf(_lean, lean_target, blend)
	# Falling over when it dies, and standing back up when revived. Slower than a lean, like a toy toppling.
	_fall = lerpf(_fall, deg_to_rad(death_fall_degrees) if dead else 0.0, 1.0 - exp(-ease_rate * 0.5 * delta))

	position = Vector3(0.0, hop + breathe, 0.0)
	# GDScript note: rotation is in radians, x then y then z. z turns it to its side (rocking, falling); x tips it forward or back.
	rotation = Vector3(_lean, 0.0, -(rock + _fall))


# The pawn this belongs to: the nearest Pawn above it.
func _find_pawn() -> Pawn:
	var at := get_parent()
	while at and not at is Pawn:
		at = at.get_parent()
	return at as Pawn


# Holds the first frame of pose_animation on the model's AnimationPlayer, if it has one, so the model keeps a still pose.
func _hold_pose(model: Node) -> void:
	if pose_animation == &"":
		return
	for player: AnimationPlayer in model.find_children("*", "AnimationPlayer", true, false):
		if player.has_animation(pose_animation):
			# GDScript note: play() then pause() at the start shows that frame and leaves it there.
			player.play(pose_animation)
			player.seek(0.0, true)
			player.pause()


# A thin disc under the feet, in stand_color: the figurine's base.
func _make_stand() -> MeshInstance3D:
	var mesh := CylinderMesh.new()
	mesh.top_radius = stand_radius
	mesh.bottom_radius = stand_radius * 1.08
	mesh.height = 0.06
	mesh.radial_segments = 20
	var material := StandardMaterial3D.new()
	material.albedo_color = stand_color
	mesh.material = material
	var stand := MeshInstance3D.new()
	stand.name = "Stand"
	stand.mesh = mesh
	stand.position.y = 0.03
	stand.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return stand
