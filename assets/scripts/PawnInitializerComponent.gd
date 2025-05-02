@tool
class_name PawnInitializerComponent
extends Node


@export var reload_pawn:= false:
	set(value):
		if value and Engine.is_editor_hint():
			do_reload_pawn()
		reload_pawn = false


#check boxes to designate which components to spawn with initializer on _enter_tree()
@export var spawnMovementControllerManager:= false ##spawn a movement controller manager. No controllers attached by default
@export var spawnTheseControllers: = spawnControllerSelectorRes.new(false, false, false) ##specify which controllers to add using a resource file
@export var spawnCameraControlArm:=true ##spawns a PawnCameraController
@export var spawnCharStatManager:=false ##spawns an CharacterStateManager
@export var spawnAllAICoreComponents:= false ##spawns an AICore component with all the attached AI control components (sensing, State Manger, Behaviour Manager)
@export var spawnOverwritesPremades:= false ##dynamically spawned subcomponents (like with the spawn tickboxes above) will overwrite references to preexisting components on the pawn's scene tree

#unique subcomponent node reference variables
var Pawn: CharacterPawn3D
var CharacterModel: MeshInstance3D
var CharacterCollision: CollisionShape3D
var ControllerManager: MovementControllerManager
var StatManager: CharacterStatManager
var cameraControllerArm: PawnCameraController
var AICore: AICoreComponent
var SensingComponent: AISensingComponent
var AIStateManager: AIStateManagerComponent
#var AIBehaviourManager: AIBehaviourManagerComponent     #still pending implementation


func _init(overwrite_premades:= spawnOverwritesPremades, spawn_move_con_man:= spawnMovementControllerManager, spawn_con_res:= spawnTheseControllers, spawn_cam_arm:=spawnCameraControlArm, spawn_stat_man:= spawnCharStatManager, spawn_AI_core:= spawnAllAICoreComponents) -> void:
	spawnOverwritesPremades = overwrite_premades
	spawnMovementControllerManager = spawn_move_con_man
	spawnTheseControllers = spawn_con_res
	spawnCameraControlArm = spawn_cam_arm
	spawnCharStatManager = spawn_stat_man
	spawnAllAICoreComponents = spawn_AI_core

func _enter_tree() -> void:
	notify_pawn_initializer_entered()
	pass

func pawn_ready_set()->void:
	set_pawn_reference()
	set_unique_subcomponent_references()
	#checks for abscence or overwrite, and initializes as appropriate
	if !ControllerManager or spawnOverwritesPremades:
		if ControllerManager:
			ControllerManager.queue_free()
			ControllerManager = null
		init_controller_manager(spawnTheseControllers)
	if !cameraControllerArm or spawnOverwritesPremades:
		if cameraControllerArm:
			cameraControllerArm.queue_free()
			cameraControllerArm = null
	init_camera_controller_arm(spawnCameraControlArm)
	if !StatManager or spawnOverwritesPremades:
		if StatManager:
			StatManager.queue_free()
			StatManager = null
		init_stat_manager(spawnCharStatManager)
	if !AICore or spawnOverwritesPremades:
		if AICore:
			AICore.queue_free()
			AICore = null
		init_AI_core_component(spawnAllAICoreComponents,spawnAllAICoreComponents,spawnAllAICoreComponents)
	#done with housekeeping
	initializer_completed()

func set_pawn_reference()->void:	
	if get_parent() is CharacterPawn3D:
		Pawn = get_parent()
	else:
		printerr("parent is not a CharacterPawn3D!")
		
func notify_pawn_initializer_entered()-> PawnInitializerComponent:
	if Pawn:
		Pawn.initializerEntered = true
		Pawn.pawnInitializer = self
	else:
		Pawn = get_parent()
		Pawn.initializerEntered = true
		Pawn.pawnInitializer = self
	return self

var allPawnChildren: Array[Node] = []
func initializer_completed()->void:
	#allPawnChildren = GlobalTools.get_all_descendants(Pawn)
	pass_subcomponent_references()
	
func pass_subcomponent_references():
	Pawn.cameraControllerArm = cameraControllerArm
	Pawn.CharacterModel = CharacterModel
			
	
##checks if controller manager is already added. If not, creates a new one. Part of functions to overhaul during refactor
func init_controller_manager(controller_res:= spawnTheseControllers, debug:= true)->void:
	if ControllerManager:
		print(Pawn, " already has movement controller manager component")
		return
	ControllerManager = MovementControllerManager.new(controller_res.player_controller,controller_res.click_move_controller,controller_res.AI_movement_controller, debug)
	ControllerManager.name = "MovementControllerManager"
	Pawn.add_child(ControllerManager)
	#print("added movementControllerComponent: ", movementController)


var unitHalfHeight: float = 1
##Creates a PawnCameraController3D (spring arm) if there isn't one. Candidate for refactor. Code kinda messy, but functional
func init_camera_controller_arm(spawn:= spawnCameraControlArm)->void:
	if !spawn:
		return
	if cameraControllerArm:
		print(self, " already has camera controller")
		return
	if CharacterCollision:
			unitHalfHeight = CharacterCollision.shape.height/2
			Pawn.unitHalfHeight = unitHalfHeight
	if !Pawn or !is_instance_valid(Pawn):
		print("pawn not valid! ", Pawn)
		return
	cameraControllerArm = PawnCameraController.new()
	cameraControllerArm.name = "PawnCameraController" #refactor with the spring arm reference code bullshit
	Pawn.add_child(cameraControllerArm)
	cameraControllerArm.position = Vector3(0,unitHalfHeight,0)
	print("camPos: ", cameraControllerArm.position)
	cameraControllerArm.rotation.x = deg_to_rad(cameraControllerArm.initial_camera_pitch)
	print("added: ", cameraControllerArm, " to: ", Pawn)
	print("at: ", cameraControllerArm.global_position, " rel: ", Pawn.global_position)

func init_stat_manager(with_stat:=true, stat_block:StatBlockRes = null)->void:
	if !StatManager:
		StatManager = CharacterStatManager.new()
		StatManager.name = "StatManagerComponent"
		Pawn.add_child(StatManager)
		if with_stat:
			if stat_block == null:
				stat_block = StatBlockRes.new("Health")
			var statComp = StatComponentBase.new(stat_block)
			StatManager.add_child(statComp)
		GlobalTools.print_sequence_counter(self, "init_stat_manager")
		print(self, "statManager initialized ", StatManager)
	

func init_AI_core_component(add_AIsensing:=true, add_AIStateManager:=true, add_AIBehaviourManager:=true)->void:
	if AICore:
		print(self, " already has AI unit manager")
		return
	AICore = AICoreComponent.new(add_AIsensing,add_AIStateManager,add_AIBehaviourManager)
	AICore.name = "AICoreComponent"
	Pawn.add_child(AICore)
	AICore.position = Pawn.position
	GlobalTools.print_sequence_counter(self, "init_AI_core_component()")


func debug_generate_temp_capsule():
	if !allPawnChildren.has(CollisionShape3D):
		CharacterModel = MeshInstance3D.new()
		CharacterCollision = CollisionShape3D.new()
		var mesh = CapsuleMesh.new()
		var shape = CapsuleShape3D.new()
		CharacterModel.mesh = mesh
		CharacterCollision.shape = shape
		Pawn.add_child(CharacterModel)
		Pawn.add_child(CharacterCollision)
		CharacterModel.y = CharacterModel.height/2
		CharacterCollision.y = CharacterModel.y
		var material = StandardMaterial3D.new()
		material.albedo_color = Color.GRAY
		CharacterModel.set_surface_override_material(0, material)
		print(Pawn, " capsule set!")
	else:
		print(Pawn, " action failed || already has collider!")
		

var uniqueSubComponentRef: Array[Node] = []
func set_unique_subcomponent_references()->Array[Node]:
	set_subcomponent_ref_to_null()
	allPawnChildren = GlobalTools.get_all_descendants(Pawn)
	uniqueSubComponentRef.clear()
	for c in allPawnChildren:
		if c.name == "CharacterModel" and c is MeshInstance3D:
			CharacterModel = c
			uniqueSubComponentRef.append(c)
		if c.name == "CharacterCollision" and c is CollisionShape3D:
			CharacterCollision = c
			uniqueSubComponentRef.append(c)
		if c is MovementControllerManager:
			ControllerManager = c
			uniqueSubComponentRef.append(c)
		if c is CharacterStatManager:
			StatManager = c
			uniqueSubComponentRef.append(c)
		if c is PawnCameraController:
			cameraControllerArm = c
			uniqueSubComponentRef.append(c)
		if c is AICoreComponent:
			AICore = c
			uniqueSubComponentRef.append(c)
		if c is AISensingComponent:
			SensingComponent = c
			uniqueSubComponentRef.append(c)
		if c is AIStateManagerComponent:
			AIStateManager = c
			uniqueSubComponentRef.append(c)
		#if c = AIBehaviourManagerComponent:        #not yet implemented
		#	AIBehaviourManager = c
		#	uniqueSubComponentRef.append(c)
	return uniqueSubComponentRef

func set_subcomponent_ref_to_null()->void:
	uniqueSubComponentRef.clear()
	CharacterModel = null
	uniqueSubComponentRef.append(CharacterModel)
	CharacterCollision = null
	uniqueSubComponentRef.append(CharacterCollision)
	ControllerManager = null
	uniqueSubComponentRef.append(ControllerManager)
	StatManager = null
	uniqueSubComponentRef.append(StatManager)
	cameraControllerArm = null
	uniqueSubComponentRef.append(cameraControllerArm)
	AICore = null
	uniqueSubComponentRef.append(AICore)
	SensingComponent = null
	uniqueSubComponentRef.append(SensingComponent)
	AIStateManager = null
	uniqueSubComponentRef.append(AIStateManager)
#	AIBehaviourManager = null                       	#not yet implemented
#	uniqueSubComponentRef.append(AIBehaviourManager)	#not yet implemented

func clear_subcomponents_from_pawn()->void:
	CharacterModel.queue_free()
	CharacterCollision.queue_free()
	ControllerManager.queue_free()
	StatManager.queue_free()
	cameraControllerArm.queue_free()
	AICore.queue_free()
	set_subcomponent_ref_to_null()

##make sure uniqueSubComponentRef is updated before calling!
func remove_unreferrenced_unique_subcomponents()->void:
	allPawnChildren = GlobalTools.get_all_descendants(Pawn)
	for c in allPawnChildren:
		#character model not handled
		#character collision not handled
		if c is MovementControllerManager and !ControllerManager:
			c.queue_free()
		if c is CharacterStatManager and !StatManager:
			c.queue_free()
		if c is PawnCameraController and !cameraControllerArm:
			c.queue_free()
		if c is AICoreComponent and !AICore:
			c.queue_free()
		if c is AISensingComponent and !SensingComponent:
			c.queue_free()
		if c is AIStateManagerComponent and !AIStateManager:
			c.queue_free()
		#if c = AIBehaviourManagerComponent and !AIBehaviourManager:        #not yet implemented
		#	c.queue_free()
	call_deferred("update_all_pawn_children")

func update_all_pawn_children()->void:
	allPawnChildren = GlobalTools.get_all_descendants(Pawn)

var canReload:= false
func do_reload_pawn()->void:
	if canReload: #debug stop. remove for implementation.
		var pwn = get_parent()
		var par = pwn.get_parent()
		var pwnTrans = pwn.global_transform
		par.remove_child(pwn)
		par.add_child(pwn)
		pwn.global_transform = pwnTrans
