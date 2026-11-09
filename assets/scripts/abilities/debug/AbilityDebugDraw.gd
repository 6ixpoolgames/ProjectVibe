## Written by Claude (claude-opus-5-5), 2026-11-09: debug shapes for abilities, so a fight can be read by eye. Not part of the base: a
## sample or a test adds one and calls watch() for each pawn it wants drawn. The arena sample uses it (F3 hides it).
##
## What it draws, each a see-through shape that fades out in a straight line and is then removed:
##   - A melee swing's hit sphere, where and how big it was, left behind for attack_seconds (2 s). Drawn when the swing's hit
##     window opens (MeleeAttackAbility.hit_window_started), whether or not it hit anything.
##     Claude 2026-11-09: a swing that hits labels its sphere with each pawn it hit and the damage, one per line ("pawn_3 -20"),
##     from MeleeAttackAbility.hit_landed. Hits are decided on the server, so a client's own spheres stay unlabelled.
##   - A dash's trail: a copy of the pawn's capsule every physics frame while it dashes, each left behind for dash_seconds (1 s).
##
## Where it shows: on the machine whose abilities run the swing or dash. That's every pawn offline and on the server, and a
## client's own pawn. A client doesn't draw other players' or the AI's shapes, because it doesn't run their abilities.
##
## How to use it:
##   var draw := AbilityDebugDraw.new()
##   add_child(draw)
##   draw.watch(pawn)        # for each pawn; a freed pawn is dropped by itself
##   draw.visible = false    # hides every shape, and draws no new ones while hidden
class_name AbilityDebugDraw
extends Node3D

## How long a swing's hit sphere stays, in seconds, fading the whole time.
@export var attack_seconds := 2.0
## A swing's hit sphere colour. Its alpha is where the fade starts.
@export var attack_colour := Color(1.0, 0.3, 0.2, 0.35)
## How long each copy of a dashing pawn's capsule stays, in seconds, fading the whole time.
@export var dash_seconds := 1.0
## A dash trail's colour. Its alpha is where the fade starts.
@export var dash_colour := Color(0.35, 0.7, 1.0, 0.3)

var _dashes: Array = [] # [pawn, DashAbility] pairs to watch each physics frame
var _swings := {} # Claude 2026-11-09: MeleeAttackAbility -> its latest sphere, so a hit can label the sphere of its own swing
var _fading: Array = [] # [MeshInstance3D, StandardMaterial3D, seconds left, seconds in all, starting alpha]
var _sphere_mesh: SphereMesh = null


func _ready() -> void:
	# GDScript note: top_level means this node ignores its parent's transform, so the shapes' global positions are world positions
	# wherever the module is added.
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
			# Claude 2026-11-09: _swings stops a second watch() of the same pawn from drawing everything twice (it was is_connected,
			# which doesn't work with bind). GDScript note: bind() adds the ability as an extra last argument to each call.
			if not _swings.has(ability):
				_swings[ability] = null
				ability.hit_window_started.connect(_on_hit_window_started.bind(ability))
				ability.hit_landed.connect(_on_hit_landed)
		elif ability is DashAbility:
			var already := false
			for pair in _dashes:
				if pair[1] == ability:
					already = true
			if not already:
				_dashes.append([pawn, ability])


func _physics_process(_delta: float) -> void:
	# A copy of the capsule for every pawn dashing right now. Freed pawns are dropped, walking the list backwards so removing is safe.
	for i in range(_dashes.size() - 1, -1, -1):
		var pawn: Pawn = _dashes[i][0] if is_instance_valid(_dashes[i][0]) else null
		if pawn == null or not is_instance_valid(_dashes[i][1]):
			_dashes.remove_at(i)
			continue
		if visible and _dashes[i][1].is_running_timed():
			_leave_capsule(pawn)
	# Claude 2026-11-09: forget swings whose pawn is gone. GDScript note: keys() is a copy, so erasing while looping over it is safe.
	for swing in _swings.keys():
		if not is_instance_valid(swing):
			_swings.erase(swing)


func _process(delta: float) -> void:
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
		# Claude 2026-11-09: a sphere's label fades with it, from fully visible.
		var label := entry[0].get_node_or_null("Hits") as Label3D
		if label:
			label.modulate.a = left
			label.outline_modulate.a = left


# Claude 2026-11-09: the ability comes from bind() in watch(), so a hit can find this swing's sphere.
func _on_hit_window_started(centre: Vector3, radius: float, swing: MeleeAttackAbility) -> void:
	if not visible:
		return
	var shape := _add_shape("AttackSphere", _sphere_mesh, attack_colour, attack_seconds)
	shape.global_position = centre
	shape.scale = Vector3.ONE * radius
	_swings[swing] = shape


## Claude 2026-11-09: adds the pawn hit, and the damage, to its swing's sphere, one line per hit. The label is made on the first hit.
func _on_hit_landed(hit: HitInfo) -> void:
	# GDScript note: untyped first, because putting an already freed object into a typed variable is an error.
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
		label.text = "%s -%d" % [hit.target.name, hit.damage]
	else:
		label.text += "\n%s -%d" % [hit.target.name, hit.damage]


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
	# GDScript note: true asks for readable names when two share one (AttackSphere2, AttackSphere3) instead of Godot's "@" names.
	add_child(shape, true)
	_fading.append([shape, material, seconds, seconds, colour.a])
	return shape
