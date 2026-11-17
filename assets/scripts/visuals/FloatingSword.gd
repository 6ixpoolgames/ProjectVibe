# Written by Claude (claude-opus-5-5), 2026-11-12. History: visuals/CHANGELOG.md.
## A sword that floats beside the pawn and swings through each attack, exactly where the hit is checked.
##
## Part of the toy look (pawn spec 8.12): the pawn doesn't hold it; it hovers at its right side, about chest high, blade up. Put it
## under the pawn's Visual (not Model, which rocks with the waddle); it makes the sword from [member sword_scene]. A running
## MeleeAttackAbility drives it through windup, hit (the blade sweeps the path the hits check, [code]hit_offset_at[/code]) and
## recovery; a running ParryAbility makes it guard in front of the chest; death drops it flat.
## [br]
## Visual only: it runs once per rendered frame and only reads the pawn (swing progress is ability state, which rolls back and
## reaches clients in snapshots), so it changes nothing simulated. With no display it builds nothing and never runs
## (RunEnvironment.runs_visuals).
# REFACTOR: it finds MeleeAttackAbility and ParryAbility by class, so a new kind of attack or guard needs code here (extensible). The
# modular animation work could give abilities a pose to report instead. See CHANGELOG.md.
class_name FloatingSword
extends Node3D

## The sword to show, such as Kenney's weapon-sword.glb, with its blade along +Y and its grip at its origin. Empty: a plain box blade.
@export var sword_scene: PackedScene
## How much bigger the sword is drawn. Kenney's is about 0.45 m long; 2.2 makes it about 1 m.
@export_range(0.1, 10.0, 0.05, "or_greater") var sword_scale := 2.2

@export_group("Hovering")
## Where it hovers, from the pawn's feet: this far to the pawn's right, and this high, in metres.
@export var hover_side := 0.8
@export var hover_height := 1.0
## How far it bobs up and down, in metres, and how many times a second.
@export_range(0.0, 0.5, 0.005) var bob_height := 0.06
@export_range(0.0, 5.0, 0.05) var bob_rate := 1.1
## How far the blade leans out from straight up, away from the pawn, in degrees.
@export_range(0.0, 90.0, 0.5) var hover_lean_degrees := 14.0

@export_group("Swinging")
## How high the blade's pivot is above the pawn's feet during a swing, in metres: about the chest. The blade points from here
## through the spot the hit checks.
@export var swing_pivot_height := 1.1
## How far out from that pivot the grip is during a swing, in metres.
@export_range(0.0, 2.0, 0.01) var grip_distance := 0.5
## How far before the hit's start the windup pulls back, as a fraction of the sweep: 0.2 is a fifth of the sweep further back.
@export_range(0.0, 1.0, 0.01) var windup_pull_back := 0.2
## How long it takes to glide to its new pose when what it shows changes at once: a swing cancelled halfway, a new swing starting
## before the last one settled, or the pawn dying. The rest of the time it follows the swing exactly, with no lag, so even a fast
## chop is drawn where the hit is.
@export_range(0.0, 1.0, 0.01, "or_greater") var settle_seconds := 0.12
## Seconds with no swing before it goes back to the pawn's right from the side the last swing ended on.
@export_range(0.0, 10.0, 0.05, "or_greater") var return_seconds := 0.8
## How long that trip round the front takes, in seconds.
@export_range(0.01, 3.0, 0.01, "or_greater") var side_change_seconds := 0.35

@export_group("Parrying")
## While a parry runs, how far in front of the pawn the guarding sword is, and how high, in metres.
@export var guard_forward := 0.6
@export var guard_height := 1.15

var _pawn: Pawn = null
var _visual: Node3D = null
var _model: Node3D = null
var _swings: Array[MeleeAttackAbility] = []
var _parries: Array[ParryAbility] = []
var _bound := false
var _sword: Node3D = null
var _bob_phase := 0.0
var _shown_key := -1 # what it showed last frame: the running parry's or swing's instance id, 0 hovering, 1 dead
var _settle_from := Transform3D.IDENTITY # where it was drawn when that changed
var _settled := 1.0 # 0 just after a change, 1 once it has glided to its new pose
# Where it rests, as an angle round the pawn from its right: 0 right, PI/2 in front, PI left. Where it's heading,
# and how long since the last swing.
var _rest_angle := 0.0
var _rest_target := 0.0
var _idle_seconds := 0.0


func _ready() -> void:
	# Nothing to draw on, so nothing to build or move (see the class description).
	if not RunEnvironment.runs_visuals():
		set_process(false)
		return
	top_level = true # placed in world space each frame, whatever its parents do
	_pawn = _find_pawn()
	if sword_scene:
		_sword = sword_scene.instantiate() as Node3D
	if _sword == null:
		_sword = _make_box_blade()
	_sword.scale = Vector3.ONE * sword_scale
	add_child(_sword)


# The pawn's Visual, model and swings, found on the first frame: a pawn finds its own parts in its _ready, after its children's.
func _bind() -> void:
	_bound = true
	_visual = _pawn.get_visual()
	_model = _visual.get_node_or_null(^"Model") as Node3D
	if _pawn.ability_manager:
		for ability in _pawn.ability_manager.get_abilities():
			if ability is MeleeAttackAbility:
				_swings.append(ability)
			elif ability is ParryAbility:
				_parries.append(ability)
	_read_pawn()
	global_transform = _target(_facing())
	_shown_key = _shown()


func _process(delta: float) -> void:
	var started := PerfScopes.begin() # timed for diagnostics, in its animation category
	_animate(delta)
	PerfScopes.end(&"animation.sword", started)


# The work itself, timed by _process.
func _animate(delta: float) -> void:
	if _pawn == null:
		return
	if not _bound:
		_bind()
	_read_pawn()
	_bob_phase = fmod(_bob_phase + delta * bob_rate * TAU, TAU)
	_update_rest_side(delta, _facing())
	var target := _target(_facing())
	var key := _shown()
	if key != _shown_key:
		_shown_key = key
		_settle_from = global_transform
		_settled = 0.0 if settle_seconds > 0.0 else 1.0
	_settled = minf(_settled + delta / maxf(settle_seconds, 0.001), 1.0)
	# interpolate_with blends both the place and the turn.
	global_transform = target if _settled >= 1.0 else _settle_from.interpolate_with(target, _ease_in_out(_settled))


# What it's showing: 1 dead, the running parry's or swing's instance id, or 0 hovering. A change starts a short glide (settle_seconds).
func _shown() -> int:
	if _dead_now:
		return 1
	if _parry_now:
		return _parry_now.get_instance_id()
	return _swing_now.get_instance_id() if _swing_now else 0


## Where the sword should be this frame, in world space: hovering, swinging or lying on the ground.
func _target(facing: float) -> Transform3D:
	var feet := _visual.global_position
	var right := Vector3(cos(facing), 0.0, -sin(facing))
	if _dead_now:
		# Flat on the ground at its right, blade pointing forward.
		var forward := Vector3(-sin(facing), 0.0, -cos(facing))
		return Transform3D(_blade_basis(forward, Vector3.UP), feet + right * hover_side + Vector3(0.0, 0.05, 0.0))
	var hover := _hover(feet, right)
	# Guarding during a parry: in front of the chest, blade flat across the pawn, edge facing out.
	if _parry_now:
		var ahead := Vector3(-sin(facing), 0.0, -cos(facing))
		return Transform3D(_blade_basis(right, ahead), feet + ahead * guard_forward + Vector3(0.0, guard_height, 0.0) - right * 0.5)
	var swing := _swing_now
	if swing == null:
		return hover
	# Where the swing is comes from its steps (swing_phase, pawn spec 8.20), since a windup can wait for its turn. The progress is
	# smooth between ticks.
	var phase := _phase_now
	match phase.phase:
		"windup":
			return hover.interpolate_with(_swing_pose(swing, feet, facing, -windup_pull_back), _ease_out(phase.progress))
		"hit":
			return _swing_pose(swing, feet, facing, phase.progress)
		"recovery":
			return _swing_pose(swing, feet, facing, 1.0).interpolate_with(hover, _ease_in_out(phase.progress))
	return hover


# Hovering beside the pawn, bobbing, the blade leaning out a little and swaying with the bob, on the side it rests on (_rest_angle):
# right, left, or partway round the front while it changes sides.
func _hover(feet: Vector3, right: Vector3) -> Transform3D:
	var forward := Vector3(right.z, 0.0, -right.x) # a quarter turn left of right is forward
	var out := right * cos(_rest_angle) + forward * sin(_rest_angle)
	var bob := sin(_bob_phase)
	var blade := (Vector3.UP + out * tan(deg_to_rad(hover_lean_degrees + bob * 3.0))).normalized()
	var place := feet + out * hover_side + Vector3(0.0, hover_height + bob * bob_height, 0.0)
	return Transform3D(_blade_basis(blade, out.cross(Vector3.UP)), place)


# Which side it rests on. Once a swing's hit is over, the side its sweep ended on; with no swing for
# return_seconds, the right again, moving round the front over side_change_seconds.
func _update_rest_side(delta: float, facing: float) -> void:
	var swing := _swing_now
	if swing:
		_idle_seconds = 0.0
		if _phase_now.phase == "recovery":
			var right := Vector3(cos(facing), 0.0, -sin(facing))
			var end := swing.hit_offset_at(1.0, facing)
			end.y = 0.0
			var across := end.normalized().dot(right) # 1 at the pawn's right, -1 at its left, about 0 straight ahead
			if across < -0.25:
				_rest_target = PI
			elif across > 0.25:
				_rest_target = 0.0
			_rest_angle = _rest_target # the sword is at the sweep's end already, and recovery glides from there
		return
	_idle_seconds += delta
	if _idle_seconds >= return_seconds:
		_rest_target = 0.0
	_rest_angle = move_toward(_rest_angle, _rest_target, delta * PI / side_change_seconds)


# The sword at this point of the swing's sweep (0 its start, 1 its end; below 0 is before the start, for the windup): its grip out
# from the chest pivot, its blade pointing through the spot the hit checks, its edge leading the way the sweep moves.
func _swing_pose(swing: MeleeAttackAbility, feet: Vector3, facing: float, progress: float) -> Transform3D:
	var pivot := Vector3(0.0, swing_pivot_height, 0.0)
	var spot := swing.hit_offset_at(progress, facing)
	var blade := (spot - pivot).normalized()
	var moving := swing.hit_offset_at(progress + 0.02, facing) - swing.hit_offset_at(progress - 0.02, facing)
	return Transform3D(_blade_basis(blade, moving), feet + pivot + blade * grip_distance)


# A turn that points the sword's blade (its +Y) along blade, with its edge (its +X) as close to edge_toward as it can be.
func _blade_basis(blade: Vector3, edge_toward: Vector3) -> Basis:
	var y := blade.normalized()
	var x := edge_toward - y * edge_toward.dot(y) # the part of edge_toward square to the blade
	if x.length_squared() < 0.0001:
		x = Vector3.RIGHT if absf(y.x) < 0.9 else Vector3.FORWARD
		x = x - y * x.dot(y)
	x = x.normalized()
	var z := x.cross(y)
	return Basis(x, y, z)


# What the pawn is doing this frame, read once at the top of _animate and used by everything below, since swing_phase() makes a new
# Dictionary each time.
var _dead_now := false
var _parry_now: ParryAbility = null
var _swing_now: MeleeAttackAbility = null
var _phase_now: Dictionary = {}

func _read_pawn() -> void:
	_dead_now = _pawn.is_dead()
	_parry_now = _running_parry()
	_swing_now = _running_swing()
	_phase_now = _swing_now.swing_phase() if _swing_now else {}


# The running swing, or null. Only one can run at a time: each locks out the others.
func _running_swing() -> MeleeAttackAbility:
	for swing in _swings:
		if swing.is_running_timed():
			return swing
	return null


# The running parry, or null.
func _running_parry() -> ParryAbility:
	for parry in _parries:
		if parry.is_running_timed():
			return parry
	return null


# The facing the pawn is drawn with this frame (its model's turn, smoothed between ticks), or its facing if it has no model.
func _facing() -> float:
	return _model.rotation.y if _model else _pawn.yaw


func _find_pawn() -> Pawn:
	var at := get_parent()
	while at and not at is Pawn:
		at = at.get_parent()
	return at as Pawn


# With no sword_scene: a plain grey box blade with its grip at the origin, so a missing model still shows the swing.
func _make_box_blade() -> Node3D:
	var mesh := BoxMesh.new()
	mesh.size = Vector3(0.06, 0.4, 0.02)
	var blade := MeshInstance3D.new()
	blade.mesh = mesh
	blade.position.y = 0.2
	var holder := Node3D.new()
	holder.add_child(blade)
	return holder


static func _ease_out(t: float) -> float:
	t = clampf(t, 0.0, 1.0)
	return 1.0 - (1.0 - t) * (1.0 - t)


static func _ease_in_out(t: float) -> float:
	t = clampf(t, 0.0, 1.0)
	return t * t * (3.0 - 2.0 * t)
