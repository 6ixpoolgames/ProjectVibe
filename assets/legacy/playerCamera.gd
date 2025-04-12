extends SpringArm3D

@export var cameraDistMin: float = 1
@export var cameraDistMax: float = 20
@export var cameraDistDefault: float = 7
@export var cameraZoomSpeed: float = .5
@export var cameraRotSpeedX: float = 260     #in degrees
@export var cameraRotSpeedY: float = 205     #in degrees
@export var cameraPitchMax: float = -20      #in degrees
@export var cameraPitchMin: float = -60      #in degrees
@export var deadSpace: float = 0.125

@onready var camera = $Camera3D
@onready var cursorX: float = camera.get_viewport().get_mouse_position().x
@onready var lastCursorX: float = camera.get_viewport().get_mouse_position().x
@onready var cursorY: float = camera.get_viewport().get_mouse_position().y
@onready var lastCursorY: float = camera.get_viewport().get_mouse_position().y
@onready var viewportX: float = camera.get_viewport().size.x
@onready var viewportY: float = camera.get_viewport().size.y

	
func rotateCameraYawBy():
	var rotateXBy: float = 0
	var dampingFactor: float = 0.008
	cursorX = camera.get_viewport().get_mouse_position().x
	if cursorX > (viewportX - (viewportX * deadSpace)): 
		rotateXBy = deg_to_rad(cameraRotSpeedX * -1)*smoothstep(viewportX - (viewportX * deadSpace),viewportX,cursorX)*dampingFactor
	elif  cursorX < (0 + (deadSpace * viewportX)):
		rotateXBy = deg_to_rad(cameraRotSpeedX)*smoothstep((deadSpace * viewportX),0,cursorX)*dampingFactor
	else:
		cursorX = camera.get_viewport().get_mouse_position().x
		rotateXBy = deg_to_rad((lastCursorX - cursorX)/camera.get_viewport().size.x * cameraRotSpeedX)
		lastCursorX = cursorX
	return rotateXBy

func rotateCameraPitchBy():
	cursorY = camera.get_viewport().get_mouse_position().y
	var rotateYBy = deg_to_rad((cursorY - lastCursorY )/camera.get_viewport().size.y * cameraRotSpeedY)
	lastCursorY = cursorY
	return -rotateYBy
	
func _physics_process(delta: float) -> void:
	#camera zoom adjustment
	if Input.is_action_just_pressed("scrollWheel_up"):
		self.spring_length -= cameraZoomSpeed
	if Input.is_action_just_pressed("scrollWheel_down"):
		self.spring_length += cameraZoomSpeed
	if Input.is_action_just_pressed("middleMouse_button"):
		self.spring_length = cameraDistDefault
	self.spring_length = clampf(self.spring_length, cameraDistMin, cameraDistMax)

	#camera rotation
	self.rotation.y += clamp(rotateCameraYawBy(), deg_to_rad(-cameraRotSpeedX*delta), deg_to_rad(cameraRotSpeedX*delta))
	self.rotation.x += rotateCameraPitchBy()

	#clamp rotation
	self.rotation.x = clampf(self.rotation.x, deg_to_rad(cameraPitchMin), deg_to_rad(cameraPitchMax))


func _process(delta: float) -> void:
	
	#3D mouse cursor logic
	var mPos = camera.get_viewport().get_mouse_position()
	var rOrg = camera.project_ray_origin(mPos)
	var rDir = camera.project_ray_normal(mPos)
	var rLen: float = 1000
	
	#raycast3d node cursor implementation
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
			
#debug sphere representation for 3d cursor
@onready var raycast = $Camera3D/RayCast3D
var debugSphere = MeshInstance3D.new()
var debugSphereIsInit: bool = false
var dSpherePos = Vector3.ZERO

func create_debug_sphere():
	var debugSphereMesh = SphereMesh.new()
	debugSphereIsInit = true
	debugSphereMesh.height = 0.3
	debugSphereMesh.radius = .15
	
	add_child(debugSphere)
	debugSphere.name = "debugSphere"
	debugSphere.mesh = debugSphereMesh
	var material = StandardMaterial3D.new()
	material.albedo_color = Color.RED
	debugSphere.set_surface_override_material(0, material)
	
	print("success ", $debugSphere)

func get_3D_cursor_world_position():
	return dSpherePos
