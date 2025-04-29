class_name CharacterPawn3D
extends CharacterBody3D

@export var speed: float = 5 #max speed
@export var acceleration: float = 20 #accel on move input
@export var deceleration: float = 50 #decel when input released
@export var gravity_multiplier: float = 1
@export var turn_speed_yaw: float = 720 #rotation speed in deg/sec
@export var turn_speed_pitch: float = 720 #rotation speed in deg/sec
@export var turn_speed_tilt: float = 720 #rotation speed in deg/sec
@export var jump_velocity: float = 5 #jump power
@export var air_control: float = 0.66
@export var is_floating: bool = false
var isCommandedMovement: bool = false
var gravity: float  = ProjectSettings.get_setting("physics/3d/default_gravity")
var moveDirection = Vector3.ZERO ##direction character will move in

#model rotation variables
@onready var currentYaw: float = self.rotation.y
@onready var currentPitch: float = self.rotation.x
@onready var currentTilt: float = self.rotation.z
var targetYaw: float = 0
var targetPitch: float = 0
var targetTilt: float = 0
var lastInputRotationYaw: float = targetYaw
var lastInputRotationPitch: float = targetPitch
var lastInputRotationTilt: float = targetTilt

#ready variables
var isReadyTrigger = false
var activeCamera: Camera3D
var allChildren: Array[Node]
func _ready():
		allChildren = GlobalTools.get_all_descendants(self)
		init_stat_manager()
	#if shouldInitialize:
		ready_active_camera()
		pass_down_references()
		pawn_is_ready()
	#set_references_hard()
	#init_controller_manager()
	#init_camera_spring_arm()

func _enter_tree() -> void:
	if shouldInitialize:
		init_camera_controller_arm()
		init_controller_manager()
		#init_stat_manager()

#node reference variables
var CharacterModel: MeshInstance3D
var CollisionCapsule: CollisionShape3D
var ControllerManager: MovementControllerManager
var StatManager: CharacterStatManager
var cameraControllerArm: PawnCameraController
var AICore: AICoreComponent
var SensingComponent: AISensingComponent
var AIStateManager: AIStateManagerComponent
func pass_down_references():
	allChildren = GlobalTools.get_all_descendants(self)
	var references: Array[Node]
	var pwn: CharacterPawn3D = self
	references.append(pwn)
	for c in allChildren:
		if c.name == "CharacterModel":
			CharacterModel = c
			references.append(c)
		if c.name == "CollisionCapsule":
			CollisionCapsule = c
			references.append(c)
		if c is MovementControllerManager:
			ControllerManager = c
			references.append(c)
		if c is CharacterStatManager:
			StatManager = c
			references.append(c)
		if c is PawnCameraController:
			cameraControllerArm = c
			references.append(c)
		if c is AICoreComponent:
			AICore = c
			references.append(c)
		if c is AISensingComponent:
			SensingComponent = c
			references.append(c)
		if c is AIStateManagerComponent:
			AIStateManager = c
			references.append(c)
	for r in allChildren:
		if r.has_method("set_references"):
			r.set_references(references)
			print(r, " set_references called")
	print(self, " references passed")
	
func pawn_is_ready()->void:
	allChildren = GlobalTools.get_all_descendants(self)
	for c in allChildren:
		if c.has_method("pawn_ready"):
			c.pawn_ready()
			
##checks if controller manager is already added. If not, creates a new one. Part of functions to overhaul during refactor
func init_controller_manager()->void:
	if ControllerManager:
		print(self, " already has movement controller manager component")
		return
	ControllerManager = MovementControllerManager.new()
	ControllerManager.name = "MovementControllerManager"
	self.add_child(ControllerManager)
	#print("added movementControllerComponent: ", movementController)


var unitHalfHeight: float = 1
##Creates a PawnCameraController3D (spring arm) if there isn't one. Candidate for refactor. Code kinda messy, but functional
func init_camera_controller_arm()->void:
	if cameraControllerArm:
		print(self, " already has camera controller")
		return
	if CollisionCapsule:
			unitHalfHeight = CollisionCapsule.shape.height/2
	cameraControllerArm = PawnCameraController.new()
	cameraControllerArm.name = "PawnCameraController" #refactor with the spring arm reference code bullshit
	self.add_child(cameraControllerArm)
	cameraControllerArm.position = Vector3(0,unitHalfHeight,0)
	cameraControllerArm.rotation.x = deg_to_rad(cameraControllerArm.initial_camera_pitch)
	#print("added PawnCameraController3D: ", cameraControllerArm)
		
##sets the current viewport camera to the active camera. Can be combined with a larger initializer function on refactor. 
##Also should code for checking if its a PlayerCamera3D in situations where there's more than 1 active viewport
func ready_active_camera()-> void:
	activeCamera = get_viewport().get_camera_3d()
	activeCamera.connect("possession_event", _on_possession_event)

func init_stat_manager()->void:
	if StatManager or $CharacterStatManager:
		print("-------------already has stat manager component")
		return
	StatManager = CharacterStatManager.new()
	StatManager.name = "StatManagerComponent"
	self.add_child(StatManager)
	GlobalTools.print_sequence_counter(self, "init_stat_manager")
	print(self, "statManager initialized ", StatManager)
	

func init_AI_core_component()->void:
	if AICore:
		print(self, " already has AI unit manager")
		return
	AICore = AICoreComponent.new()
	AICore.name = "AICoreComponent"
	self.add_child(AICore)
func _physics_process(delta: float) -> void:
	#if isReadyTrigger == true:
	GlobalTools.printFuncRationalizer(50)
	yaw_to_facing(delta)
	apply_gravity(delta)
	move_in_direction(moveDirection, delta)
	move_and_slide()
	is_stuck(delta)
	unstucker()
	#if goPrint:
	#	print(isCommandedMovement, moveDirection)
	
## apply velocity for movement in a target direction of vector3.
##[param moveDir] vector3 direction
##[param delta] the time delta, either from _physics_process, or _process
func move_in_direction(moveDir: Vector3, delta: float) -> void:
	moveDir = moveDir.normalized()
	var airCont = 1.0 if is_on_floor() else air_control #Apply aircontrol modifier when not on the ground
	if is_floating:     #does not exclude Y axis for floating pawns
		if isCommandedMovement == true:
			velocity = velocity.move_toward(speed * moveDir, acceleration * delta * airCont)          
		else:  # Decelerate when no input
			velocity = velocity.move_toward(Vector3.ZERO, deceleration * delta * airCont)
	else:	#excludes Y axis for floating pawns
		if isCommandedMovement == true:             
			velocity.x = move_toward(velocity.x, speed * moveDir.x, acceleration * delta * airCont)
			velocity.z = move_toward(velocity.z, speed * moveDir.z, acceleration * delta * airCont)
		else:  # Decelerate when no input
			velocity.x = move_toward(velocity.x, 0, deceleration * delta * airCont)
			velocity.z = move_toward(velocity.z, 0, deceleration * delta * airCont)
	#print("movDir: ", moveDir, " vel: ", velocity)
	
##function to set the move direction, designed to be called from the controller script or elsewhere every (physics)frame
## [param inputDir] direction of desired movement
##if inputDir is a zero vector, treats it as no input commands given and sets isCommandedMovement flag to false
func give_move_command(inputDir:Vector3)-> void:
	if not inputDir.is_zero_approx(): #if with inputs
		moveDirection = inputDir
		isCommandedMovement = true
	else:
		moveDirection = Vector3.ZERO
		isCommandedMovement = false

##apply gravity every tick, with coyote time code. Possibly refactor this
func apply_gravity(delta:float):
	if not is_on_floor():
		velocity.y -= gravity * gravity_multiplier * delta		
		
var camAttachmentPoint: Node3D
##gets a reference to the pawn's camera controller (spring arm). If null for some reason, returns a reference to self
func get_camera_attachment_point()->Node3D:
	if cameraControllerArm:
		camAttachmentPoint = cameraControllerArm
	else:
		camAttachmentPoint = self
	return camAttachmentPoint

##rotates character model to target facing with yaw
func yaw_to_facing(delta: float)->void:
	var currRot = currentYaw
	lastInputRotationYaw = currRot
	#target is movement direction if commanded, else is last input
	if isCommandedMovement: 
		targetYaw = atan2(moveDirection.x * -1, moveDirection.z * -1)
	else:
		targetYaw = lastInputRotationYaw
	#math for lerp weight as factor of turn speed over distance to rotate
	var dist = abs(wrapf(targetYaw - currRot, -PI, PI)) #wrap around angles
	var wt = clamp((deg_to_rad(turn_speed_yaw) * delta) / dist, 0.0, 1.0) if dist > 0.001 else 1.0 # if statement to stop turn locking
	#apply rotation
	currentYaw = lerp_angle(currRot, targetYaw, wt)
	CharacterModel.rotation.y = currentYaw


var isPossessed = false
##sets isPossessed to TRUE if the main camera is a child. For refactoring once possession manager is in, but might keep it as a validation mechanism
func _on_possession_event(_emitter)->void:
	activeCamera = get_viewport().get_camera_3d()
	allChildren = GlobalTools.get_all_descendants(self)
	if allChildren.has(activeCamera):
		isPossessed = true
	
#	var children = get_children()
#	isPossessed = false
#	for child in children.size():
#		if children[child] == activeCamera:
#			isPossessed = true
#		#print(child," child: ", children[child], " camera ", activeCamera," isPossessed ", isPossessed)
#		var subChildren = children[child].get_children()
#		for subChild in subChildren.size():
#			if subChildren[subChild] == activeCamera:
#				isPossessed = true
#			#print(subChild, "subC: ", subChildren[subChild]," camera ", activeCamera," isPossessed ", isPossessed)
#			var sub2Children = subChildren[subChild].get_children()
#			for sub2Child in sub2Children.size():
#				if sub2Children[sub2Child] == activeCamera:
#					isPossessed = true
	print("posses signal recieved ", isPossessed)
 
@onready var lastPos = global_position
var stuckTimer:float = 0 #seconds stuck before being considered stuck
var stuckTime = stuckTimer
var isStuck = false
##function to check if pawn has not moved despite being issued a movement command
func is_stuck(delta)->void:
	if isCommandedMovement:
		stuckTime -= delta
	else:
		stuckTime = stuckTimer
	if lastPos == global_position and isCommandedMovement and stuckTime <0:
		isStuck = true
		print("stuck!")
		stuckTime = stuckTimer
	else:
		lastPos = global_position
		isStuck = false
		
##to be run each frame/physics frame to check for collisions and ensure that the colliders don't overlap
func unstucker()->void:
	if isStuck:
		var colCount = get_slide_collision_count() 
		if colCount == 0: #only runs rest of code if there are collisions
			return
		for col in get_slide_collision_count(): #loops through all collisions 
			var collision = get_slide_collision(col)
			var normal = collision.get_normal()	
			var depth = collision.get_depth()
		# Nudge slightly away from the collision
			position += normal * depth  # Small push to unstick
			print("nudge ", collision.get_collider(), " d ", depth, " n ", normal)
	

#########################################

#not used anymore. for cleanup
var terColRef: CollisionShape3D
func _on_terrain_col_gen(terCol):
	terColRef = terCol
	#print("TCG signal recieved", terCol)
	return terCol
#not used anymore. for cleanup

##vestigial code. Consider for cleanup
func init_terrain_collision() -> void:
	var terrainCollision = $"../NavigationRegion3D/ProcGenTile/TerrainMesh"
	terrainCollision.connect("terrain_collision_generated", _on_terrain_col_gen)
	#print("cam: ",activeCamera,"tC: ", terrainCollision)


#debug
@export var shouldInitialize:= true
