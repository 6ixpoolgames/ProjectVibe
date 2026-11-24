# Written by Claude (claude-opus-5-5), 2026-11-09. History: abilities/CHANGELOG.md.
## Debug shapes for abilities, so a fight can be read by eye: swing spheres, dash trails and parry shields.
##
## Not part of the base: a sample or a test adds one and calls [method watch] for each pawn it wants drawn. Each shape is see-through
## and fades out in a straight line. It draws on the machine whose abilities run the swing or dash: every pawn offline and on the
## server, and a client's own pawn only. A swing that hits labels its sphere with each pawn hit and the damage.
## [codeblock]
## var draw := AbilityDebugDraw.new()
## add_child(draw)
## draw.watch(pawn)        # for each pawn; a freed pawn is dropped by itself
## draw.visible = false    # hides every shape, and draws no new ones while hidden
## [/codeblock]
class_name AbilityDebugDraw
extends Node3D

## How long a swing's hit sphere stays, in seconds, fading throughout.
@export var attack_seconds := 2.0
## A swing's hit sphere colour. Its alpha is where the fade starts.
@export var attack_colour := Color(1.0, 0.3, 0.2, 0.35)
## How long each copy of a dashing pawn's capsule stays, in seconds, fading throughout.
@export var dash_seconds := 1.0
## A dash trail's colour. Its alpha is where the fade starts.
@export var dash_colour := Color(0.35, 0.7, 1.0, 0.3)

## A parry shield's colour.
@export var parry_colour := Color(0.55, 0.85, 1.0, 0.35)
## The flash on a parried attacker's colour.
@export var parry_flash_colour := Color(1.0, 0.95, 0.4, 0.6)
## How long the flash stays, in seconds.
@export var parry_flash_seconds := 0.6

var _dashes: Array = [] # [pawn, DashAbility] pairs to watch each physics frame
var _parries := {} # ParryAbility -> true, so watching a pawn twice doesn't draw its parries twice
var _shield_meshes := {} # front_degrees -> the shield mesh for that width, made once
var _swings := {} # MeleeAttackAbility -> its latest sphere, so a hit can label the sphere of its own swing
var _fading: Array = [] # [MeshInstance3D, StandardMaterial3D, seconds left, seconds in all, starting alpha]
var _sphere_mesh: SphereMesh = null


func _ready() -> void:
	# top_level: the shapes' global positions are world positions wherever this is added.
	top_level = true
	_sphere_mesh = SphereMesh.new()
	_sphere_mesh.radius = 1.0 # scaled to each swing's radius
	_sphere_mesh.height = 2.0


## Draws this pawn's swings and dashes from now on. Pawns without those abilities are fine: there's just nothing to draw.
func watch(pawn: Pawn) -> void:
	if pawn == null or pawn.ability_manager == null:
		return
	for ability in pawn.ability_manager.get_abilities():
		if ability is MeleeAttackAbility:
			# _swings stops a second watch() of the same pawn from drawing everything twice. is_connected can't tell two abilities'
			# bound connections to one signal apart (a second connect with another bind is refused), hence the dictionary; the parry
			# check below is one connection per manager, where is_connected is right.
			if not _swings.has(ability):
				_swings[ability] = null
				ability.hit_window_started.connect(_on_hit_window_started.bind(ability))
				ability.hit_landed.connect(_on_hit_landed)
				ability.hit_area_moved.connect(_on_hit_area_moved)
		elif ability is ParryAbility:
			_parries[ability] = true
		elif ability is DashAbility:
			var already := false
			for pair in _dashes:
				if pair[1] == ability:
					already = true
			if not already:
				_dashes.append([pawn, ability])
	# A parry's shield is drawn when it starts.
	if not _parries.is_empty() and not pawn.ability_manager.ability_started.is_connected(_on_ability_started):
		pawn.ability_manager.ability_started.connect(_on_ability_started.bind(pawn))
	# A hit parried or dodged flashes over the attacker (pawn spec 16.7).
	if not pawn.ability_manager.hit_blocked.is_connected(_on_hit_blocked):
		pawn.ability_manager.hit_blocked.connect(_on_hit_blocked)


func _physics_process(_delta: float) -> void:
	# A copy of the capsule for every pawn dashing right now. Freed pawns are dropped, walking the list backwards so removing is safe.
	for i in range(_dashes.size() - 1, -1, -1):
		var pawn: Pawn = _dashes[i][0] if is_instance_valid(_dashes[i][0]) else null
		if pawn == null or not is_instance_valid(_dashes[i][1]):
			_dashes.remove_at(i)
			continue
		if visible and _dashes[i][1].is_running_timed():
			_leave_capsule(pawn)
	# Forget swings whose pawn is gone (keys() is a copy, so erasing while looping is safe).
	for swing in _swings.keys():
		if not is_instance_valid(swing):
			_swings.erase(swing)
	for parry in _parries.keys():
		if not is_instance_valid(parry):
			_parries.erase(parry)


func _process(delta: float) -> void:
	var started := PerfScopes.begin() # timed for diagnostics (PerfScopes)
	_fade_shapes(delta)
	PerfScopes.end(&"debug.ability_draw", started)


# The work itself, timed by _process.
func _fade_shapes(delta: float) -> void:
	# Each shape's alpha goes down in a straight line from its starting alpha to 0, then the shape is removed.
	for i in range(_fading.size() - 1, -1, -1):
		var entry: Array = _fading[i]
		entry[2] -= delta
		if entry[2] <= 0.0 or not is_instance_valid(entry[0]):
			if is_instance_valid(entry[0]):
				entry[0].queue_free()
			_fading.remove_at(i)
			continue
		var material: StandardMaterial3D = entry[1]
		var left: float = entry[2] / entry[3] # 1 when new, 0 when gone
		material.albedo_color.a = entry[4] * left
		# A sphere's label fades with it, from fully visible.
		var label := entry[0].get_node_or_null("Hits") as Label3D
		if label:
			label.modulate.a = left
			label.outline_modulate.a = left


# The ability comes from bind() in watch(), so a hit can find this swing's sphere.
func _on_hit_window_started(centre: Vector3, radius: float, swing: MeleeAttackAbility) -> void:
	if not visible:
		return
	var shape := _add_shape("AttackSphere", _sphere_mesh, attack_colour, attack_seconds)
	shape.global_position = centre
	shape.scale = Vector3.ONE * radius
	_swings[swing] = shape


## One step of a swing's sweep, at half the starting sphere's alpha, so the arc shows without hiding the first sphere.
func _on_hit_area_moved(_from: Vector3, to: Vector3, radius: float) -> void:
	if not visible:
		return
	var colour := attack_colour
	colour.a *= 0.5
	var shape := _add_shape("SweepSphere", _sphere_mesh, colour, attack_seconds)
	shape.global_position = to
	shape.scale = Vector3.ONE * radius


## Adds the pawn hit and the damage to its swing's sphere, one line per hit. The label is made on the first hit.
func _on_hit_landed(hit: HitInfo) -> void:
	# Untyped first: an already freed object in a typed variable is an error.
	var found = _swings.get(hit.ability)
	if not is_instance_valid(found) or not is_instance_valid(hit.target):
		return
	var sphere: MeshInstance3D = found
	var label := sphere.get_node_or_null("Hits") as Label3D
	if label == null:
		label = Label3D.new()
		label.name = "Hits"
		label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		label.no_depth_test = true
		label.font_size = 40
		label.outline_size = 10
		label.pixel_size = 0.004
		label.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM # it grows upwards as hits are added
		# The sphere is scaled to the swing's radius; undoing that here keeps the text the same size for every swing.
		label.scale = Vector3.ONE / sphere.scale.x
		label.position = Vector3(0.0, 1.1, 0.0) # just above the sphere's top, in its own unit-sized space
		sphere.add_child(label)
		label.text = "%s -%d" % [hit.target.name, hit.planned_damage()] # from its effects, before it lands
	else:
		label.text += "\n%s -%d" % [hit.target.name, hit.planned_damage()]


# A parry started: its shield goes on the pawn's model, so it turns with the pawn, and fades over the parry's run.
func _on_ability_started(ability: AbilityBase, pawn: Pawn) -> void:
	if not visible or not (ability is ParryAbility) or not is_instance_valid(pawn):
		return
	var parry := ability as ParryAbility
	var visual := pawn.get_visual()
	if visual == null:
		return
	var holder: Node3D = visual.get_node_or_null("Model") if visual.has_node("Model") else visual
	var guard := parry.guard() # the front's width is its running effect's ParryModifier (pawn spec 16.7)
	if guard == null:
		return
	var shape := _add_shape("ParryShield", _shield_mesh(guard.front_degrees), parry_colour, maxf(parry.settings.duration_ticks / 60.0, 0.05))
	# keep_global_transform false puts it at the new parent's origin.
	shape.reparent(holder, false)
	shape.top_level = false
	shape.position = Vector3.ZERO
	shape.rotation = Vector3.ZERO


# A hit was parried or dodged (pawn spec 16.7): a flash on the attacker, in the world where it was, labelled PARRIED or DODGED. A hit
# on a dead pawn shows nothing.
func _on_hit_blocked(hit: HitInfo, reason: StringName) -> void:
	if not visible or hit == null or not is_instance_valid(hit.attacker) or reason == ReceiveHitAbility.BLOCKED_DEAD:
		return
	var flash := _add_shape("ParryFlash", _sphere_mesh, parry_flash_colour, parry_flash_seconds)
	flash.global_position = hit.attacker.global_position + Vector3(0.0, 1.0, 0.0)
	flash.scale = Vector3.ONE * 0.9
	var label := Label3D.new()
	label.name = "Hits" # faded with its shape in _process, like a swing's hit labels
	label.text = "PARRIED" if reason == ReceiveHitAbility.BLOCKED_PARRIED else "DODGED"
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.no_depth_test = true
	label.font_size = 48
	label.outline_size = 12
	label.pixel_size = 0.005
	label.modulate = Color(1.0, 0.95, 0.5)
	label.scale = Vector3.ONE / flash.scale.x
	label.position = Vector3(0.0, 1.3, 0.0)
	flash.add_child(label)


# A curved band in front of the pawn, front_degrees wide, 1 m out, from 0.2 to 1.9 m up. Forward is -Z. Made once per width.
func _shield_mesh(front_degrees: float) -> Mesh:
	if _shield_meshes.has(front_degrees):
		return _shield_meshes[front_degrees]
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	var steps := 16
	var half := deg_to_rad(front_degrees * 0.5)
	for i in steps:
		var a0 := lerpf(-half, half, float(i) / steps)
		var a1 := lerpf(-half, half, float(i + 1) / steps)
		var p0 := Vector3(sin(a0), 0.0, -cos(a0))
		var p1 := Vector3(sin(a1), 0.0, -cos(a1))
		var low := Vector3(0.0, 0.2, 0.0)
		var high := Vector3(0.0, 1.9, 0.0)
		# Two triangles for each slice of the band.
		for corner in [p0 + low, p1 + low, p1 + high, p0 + low, p1 + high, p0 + high]:
			surface.add_vertex(corner)
	var mesh := surface.commit()
	_shield_meshes[front_degrees] = mesh
	return mesh


func _leave_capsule(pawn: Pawn) -> void:
	# The pawn's own capsule: the first CollisionShape3D child with a capsule shape, at its place right now.
	for child in pawn.get_children():
		if child is CollisionShape3D and child.shape is CapsuleShape3D:
			var capsule: CapsuleShape3D = child.shape
			var mesh := CapsuleMesh.new()
			mesh.radius = capsule.radius
			mesh.height = capsule.height
			var shape := _add_shape("DashGhost", mesh, dash_colour, dash_seconds)
			shape.global_transform = child.global_transform
			return


func _add_shape(shape_name: String, mesh: Mesh, colour: Color, seconds: float) -> MeshInstance3D:
	var material := StandardMaterial3D.new()
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.cull_mode = BaseMaterial3D.CULL_DISABLED # seen from inside too, when the camera is in a sphere
	material.albedo_color = colour
	var shape := MeshInstance3D.new()
	shape.name = shape_name
	shape.mesh = mesh
	shape.material_override = material
	shape.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# true: readable names when two share one (AttackSphere2), not Godot's "@" names.
	add_child(shape, true)
	_fading.append([shape, material, seconds, seconds, colour.a])
	return shape
