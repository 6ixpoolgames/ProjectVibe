extends Node3D
class_name PawnNexusComponent

#unique subcomponent node reference variables
var pawn: CharacterPawn3D
var characterModel: MeshInstance3D
var characterCollision: CollisionShape3D
var controllerManager: MovementControllerManager
var controllerNavAgent3D: NavigationAgent3D
var statManager: CharacterStatManager
var cameraControllerArm: PawnCameraController
var aiCore: AICoreComponent
var sensingComponent: AISensingComponent
var aiStateManager: AIStateManagerComponent
var aiBehaviourManager: AIBehaviourManagerComponent
#var CombatManager: CombatManagerComponent				#still pending implementation

@export var allow_overwrites = {
	"Pawn":false,
	"CharacterModel":true,
	"CharacterCollision":true,
	"ControllerManager":false,
	"StatManager":false,
	"cameraControllerArm":false,
	"AICore":false,
	"AISensingComponent":false,
	"AIStateManager":false,
	"AIBehaviourManager":false
#	"combatManager":false
}

func _enter_tree() -> void:
	print_stack()
	var node = get_parent()
	if node and is_instance_valid(node) and node is CharacterPawn3D:
		pawn = node


func _ready() -> void:
	await get_tree().physics_frame
	await get_tree().physics_frame
	await get_tree().physics_frame
	await get_tree().physics_frame
	print_tree_pretty()
