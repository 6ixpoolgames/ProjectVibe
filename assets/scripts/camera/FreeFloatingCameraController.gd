extends PlayerCamera3D

@export var speed: float = 10

@onready var inputDirection = Vector3.ZERO

func _ready() -> void:
	is_child_of_pawn()
	super()

func _physics_process(delta: float) -> void:
	is_child_of_pawn() #should probably hook this up to the pawn possession event signal but I'm too lazy right now lol
	if isFreeFloating == true and Input.is_action_pressed("right_click"): #checks if is owned by pawn, if not and rightclick is held down, freefloat around lol
		set_position_on_input_direction(delta)
	set_position_on_scroll_zoom(delta)
		
func _process(delta: float) -> void:
	#get direciton and normalize
	inputDirection.x = Input.get_action_strength("move_right") - Input.get_action_strength("move_left")
	inputDirection.z = Input.get_action_strength("move_backward") - Input.get_action_strength("move_forward")
	inputDirection.y = Input.get_action_strength("move_upward") - Input.get_action_strength("move_downward")
	inputDirection = inputDirection.normalized()
	super(delta)
		
##moves the camera around by setting its position
func set_position_on_input_direction(delta: float) -> void:
	position.x += inputDirection.x * delta * speed
	position.y += inputDirection.y * delta * speed
	position.z += inputDirection.z * delta * speed
	
func set_position_on_scroll_zoom(delta) -> void:
	if Input.is_action_just_pressed("scrollWheel_up"): #zoom in
		position.y -= delta * speed
	if Input.is_action_just_pressed("scrollWheel_down"): #zoom out
		position.y += delta * speed


var isFreeFloating: bool = true #default is that camera is freefloating.
##checks if the camera is attached (possessing) a pawn
func is_child_of_pawn() -> void:
	var thisParent = get_parent_node_3d()
	if thisParent is SpringArm3D or thisParent is CharacterPawn3D:
		isFreeFloating = false
	else:
		isFreeFloating = true
