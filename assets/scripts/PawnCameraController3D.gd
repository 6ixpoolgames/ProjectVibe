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
@export var dampingFactor: float = 0.008

var mousePosition = Vector2.ZERO

@onready var cursorX: float = mousePosition.x
@onready var lastCursorX: float = mousePosition.x
@onready var cursorY: float = mousePosition.y
@onready var lastCursorY: float = mousePosition.y
@onready var viewportX: float = get_viewport().size.x
@onready var viewportY: float = get_viewport().size.y


##yaws camera towards the mouse position. With a smooth step function to ease camera rotation when at the deadspace (percentage as percentage of screen space)
func rotateCameraYawBy():
	var rotateXBy: float = 0
	cursorX =  mousePosition.x
	if cursorX > (viewportX - (viewportX * deadSpace)): 
		rotateXBy = deg_to_rad(cameraRotSpeedX * -1)*smoothstep(viewportX - (viewportX * deadSpace),viewportX,cursorX)*dampingFactor
	elif  cursorX < (0 + (deadSpace * viewportX)):
		rotateXBy = deg_to_rad(cameraRotSpeedX)*smoothstep((deadSpace * viewportX),0,cursorX)*dampingFactor
	else:
		cursorX = mousePosition.x
		rotateXBy = deg_to_rad((lastCursorX - cursorX)/get_viewport().size.x * cameraRotSpeedX)
		lastCursorX = cursorX
	return rotateXBy

##pitches camera based on mouse position. NO deadspace or smoothing built in yet
func rotateCameraPitchBy():
	cursorY = mousePosition.y
	var rotateYBy = deg_to_rad((cursorY - lastCursorY )/get_viewport().size.y * cameraRotSpeedY)
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
	mousePosition = get_viewport().get_mouse_position() #set mousePosition every frame
