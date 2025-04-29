extends Camera3D
class_name PlayerCamera3D

##emitted when possession changes
## [param emitter] is a referrence to tge camera that did the possessing
signal possession_event(emitter)
##emitted when a click is registerd. Should probably refactor lol
## [param cursorPosition] returns cursor position during the click
signal emit_3D_cursor_position(cursorPosition)

var togglePossession = true
@onready var lastTransform = global_transform
@onready var testPawn:CharacterPawn3D = $"../HeroPawn"

func _ready() -> void:
	raycast = create_raycaster()

##Despite the name, actually reparents this camera to the [param pwn]'s SPRINGARM if available.
func attach_to_pawn(pwn:CharacterPawn3D):
	togglePossession = false
	lastTransform = global_transform
	rotation = Vector3.ZERO  # Reset local rotation to align with SpringArm3D
	reparent(get_pawn_camera_attachment_point(pwn))
	rotation_degrees = pwn.rotation_degrees
	make_current()
	
##gets camera attachment point for a pawn to be possessed. Consider moving to Possession manager singleton
func get_pawn_camera_attachment_point(pawn: CharacterPawn3D) -> Node3D:
	var attachTo: Node3D = pawn
	var index: int = pawn.allChildren.find(PawnCameraController)
	if index != -1:
		attachTo = pawn.allChildren[index]
	return attachTo
		
##debug function for testing. Press ` to possess and unposses the pawn in the demo scene. To be replaced by actual possession input code at a later time
func _input(event):	
	if event is InputEventKey and event.pressed:
		if event.keycode == KEY_QUOTELEFT:
			if togglePossession:
				attach_to_pawn(testPawn)
				togglePossession = false
			else:
				reparent(get_tree().root)
				self.transform = lastTransform
				togglePossession = true
			emit_signal("possession_event", self)
			#print(get_parent())

func _process(_delta: float) -> void:
	move_3D_cursor()	
	#click to emit signal that returns cursor world position
	if Input.is_action_just_pressed("left_click"):
		emit_signal("emit_3D_cursor_position", dSpherePos)
		print("click signal emitted")

#apply every frame to move the 3D cursor around
func move_3D_cursor()->void:
	#3D mouse cursor logic
	var mPos = get_viewport().get_mouse_position()
	var rOrg = project_ray_origin(mPos)
	var rDir = project_ray_normal(mPos)
	var rLen: float = 1000
	
	#raycast3d node cursor implementation. Should add a function later that returns array of objects collided by the raycast so functionality can be added
	if raycast == null:
		print("trolololol")
		return
	raycast.target_position = raycast.to_local(rOrg+rDir*rLen)
	if raycast.is_colliding():
		dSpherePos = raycast.get_collision_point()
		if debugSphereIsInit:
			debugSphere.global_position = dSpherePos
		else:
			create_debug_sphere()
			debugSphere.global_position = dSpherePos
	else:
		if debugSphereIsInit:
			debugSphere.global_position = dSpherePos
		else:
			create_debug_sphere()
			debugSphere.global_position = dSpherePos


#debug sphere representation for 3d cursor. Temporary placeholder. Replace with actual 3D cursor selector at a later time
var debugSphere = MeshInstance3D.new()
var debugSphereIsInit: bool = false
var dSpherePos = Vector3.ZERO
##returns world position of the 3D cursors
func get_3D_cursor_world_position():
	return dSpherePos #temporary placeholder. Replace with actual 3D cursor selector at a later time

##creates sphere representation for 3D cursor collision point location. Replace later with code to male an actual 3D cursor
func create_debug_sphere():
	#stops function if a debug sphere is already present
	var thisChildren = self.get_children()
	for c in thisChildren:
		if c is SphereMesh or c.name == "debugSphere":
			print("dSphere ERROR duplicate")
			return
	
	#initial variables for the debug sphere
	var debugSphereMesh = SphereMesh.new()
	debugSphereIsInit = true
	debugSphereMesh.height = 0.3
	debugSphereMesh.radius = .15
		
	#adds the sphere and colors it red
	add_child(debugSphere)
	debugSphere.name = "debugSphere"
	debugSphere.mesh = debugSphereMesh
	var material = StandardMaterial3D.new()
	material.albedo_color = Color.RED
	debugSphere.set_surface_override_material(0, material)
	#debug text
	#print("success ", $debugSphere)
			
var raycast: RayCast3D
##creates a raycast3D node as a child of this camera. called on ready
func create_raycaster() -> RayCast3D:
	var rc = RayCast3D.new()
	self.add_child(rc)
	#print("raycaster created. Parent  = ", rc.get_parent_node_3d())
	return rc


	
#space state physics ray query implementation
"""
	var rEnd = rOrg + rDir*rLen
	var spaceState = get_world_3d().direct_space_state
	var params = PhysicsRayQueryParameters3D.new()
	params.from = rOrg
	params.to = rEnd
		#var intersection = spaceState.intersect_ray(params)
	var correctedRay = rDir+adjusted_forward
	correctedRay = correctedRay.normalized()
	
	if not intersection.is_empty():
		if debugSphereIsInit:
			$debugSphere.global_position = intersection.position
			print("pos: ", $debugSphere.global_position)
		else:
			create_debug_sphere()
			$debugSphere.global_position = intersection.position
			print($debugSphere)
"""
