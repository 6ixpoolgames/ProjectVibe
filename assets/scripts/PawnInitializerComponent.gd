class_name PawnInitializerComponent
extends Node

"""
@export var hasDebugAICore: bool = false:
	get:
		return hasDebugAICore
	set(value):
		if value != hasDebugAICore:
			hasDebugAICore = value
		if Engine.is_editor_hint() and hasDebugAICore:
			debug_initialize_AICore_and_subcomponents()
"""

"""
@export var hasDebugCapsule: bool = false:
	get:
		return hasDebugCapsule
	set(value):
		if value != hasDebugCapsule:
			hasDebugCapsule = value
		if Engine.is_editor_hint() and hasDebugCapsule:
			debug_generate_temp_capsule()
"""			

			
@export var spawnPlayerControllers:= false
@export var spawnAIControllers:= false
@export var spawnCameraControlArm:=true
@export var spawnStatManager:=false
@export var spawnAllAICoreComponents:= false

#node reference variables
var Pawn: CharacterPawn3D
var CharacterModel: MeshInstance3D
var CollisionCapsule: CollisionShape3D
var ControllerManager: MovementControllerManager
var StatManager: CharacterStatManager
var cameraControllerArm: PawnCameraController
var AICore: AICoreComponent
var SensingComponent: AISensingComponent
var AIStateManager: AIStateManagerComponent



var allPawnChildren: Array[Node] = []


func _enter_tree() -> void:
	set_pawn_reference()

func _ready():
	allPawnChildren = GlobalTools.get_all_descendants(Pawn)
	print("/////////",Pawn, " initializer added. Initial references set")
	print(allPawnChildren)
	init_controller_manager(spawnPlayerControllers,spawnPlayerControllers,spawnAIControllers)
	init_camera_controller_arm(spawnCameraControlArm)
	init_stat_manager(spawnStatManager)
	init_AI_core_component(spawnAllAICoreComponents,spawnAllAICoreComponents,spawnAllAICoreComponents)
	

func set_pawn_reference()->void:
	if get_parent() is CharacterPawn3D:
		Pawn = get_parent()
	else:
		printerr("parent is not a CharacterPawn3D!")

var references: Array[Node]
func pass_down_references():
	references.clear()
	references.append(Pawn)
	allPawnChildren = GlobalTools.get_all_descendants(Pawn)
	for c in allPawnChildren:
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
#		if c is AIBehaviourManagerComponent:
#			AIBehaviourManager = c
			references.append(c)
	for r in allPawnChildren:
		if r.has_method("set_references"):
			r.set_references(references)
			print(r, " set_references called")
	print(self, " references passed")
	
func pawn_is_ready()->void:
	allPawnChildren = GlobalTools.get_all_descendants(Pawn)
	for c in allPawnChildren:
		if c.has_method("pawn_ready"):
			c.pawn_ready()
			
##checks if controller manager is already added. If not, creates a new one. Part of functions to overhaul during refactor
func init_controller_manager(addPC:bool = false, addCC:bool = false, addAIC: bool = false, debug:bool = true)->void:
	if ControllerManager:
		print(Pawn, " already has movement controller manager component")
		return
	ControllerManager = MovementControllerManager.new(addPC,addCC,addAIC,debug)
	ControllerManager.name = "MovementControllerManager"
	Pawn.add_child(ControllerManager)
	#print("added movementControllerComponent: ", movementController)


var unitHalfHeight: float = 1
##Creates a PawnCameraController3D (spring arm) if there isn't one. Candidate for refactor. Code kinda messy, but functional
func init_camera_controller_arm(spawn:bool)->void:
	if not spawn:
		return
	if cameraControllerArm:
		print(self, " already has camera controller")
		return
	if CollisionCapsule:
			unitHalfHeight = CollisionCapsule.shape.height/2
			Pawn.unitHalfHeight = unitHalfHeight
	cameraControllerArm = PawnCameraController.new()
	cameraControllerArm.name = "PawnCameraController" #refactor with the spring arm reference code bullshit
	self.add_child(cameraControllerArm)
	cameraControllerArm.position = Vector3(0,unitHalfHeight,0)
	cameraControllerArm.rotation.x = deg_to_rad(cameraControllerArm.initial_camera_pitch)
	#print("added PawnCameraController3D: ", cameraControllerArm)

func init_stat_manager(with_stat:bool=false, stat_block:StatBlockRes = null)->void:
	print(StatManager, " ", $"../CharacterStatManager")
	if !StatManager or !$"../CharacterStatManager":
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
	

func init_AI_core_component(add_AIsensing:bool, add_AIStateManager:bool, add_AIBehaviourManager:bool)->void:
	if AICore:
		print(self, " already has AI unit manager")
		return
	AICore = AICoreComponent.new(add_AIsensing,add_AIStateManager,add_AIBehaviourManager)
	AICore.name = "AICoreComponent"
	self.add_child(AICore)
	GlobalTools.print_sequence_counter(self, "init_AI_core_component()")

func debug_initialize_AICore_and_subcomponents():
	if !allPawnChildren.has(AICoreComponent):
		init_AI_core_component(true, true, true)
		print(Pawn, " |->  initialize AICore and subcomponents")
	

func debug_generate_temp_capsule():
	if !allPawnChildren.has(CollisionShape3D):
		CharacterModel = MeshInstance3D.new()
		CollisionCapsule = CollisionShape3D.new()
		var mesh = CapsuleMesh.new()
		var shape = CapsuleShape3D.new()
		CharacterModel.mesh = mesh
		CollisionCapsule.shape = shape
		Pawn.add_child(CharacterModel)
		Pawn.add_child(CollisionCapsule)
		CharacterModel.y = CharacterModel.height/2
		CollisionCapsule.y = CharacterModel.y
		var material = StandardMaterial3D.new()
		material.albedo_color = Color.GRAY
		CharacterModel.set_surface_override_material(0, material)
		print(Pawn, " capsule set!")
	else:
		print(Pawn, " action failed || already has collider!")
		
		
