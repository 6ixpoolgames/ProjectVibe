extends Node
class_name AIBehaviourComponentBase

@export var behaviourID:StringName = &""
@export var stateName: StringName

var behaviourManager: AIBehaviourManagerComponent
var pawn: CharacterPawn3D
var aiCore: AICoreComponent
var pawnRID: RID

func _enter_tree() -> void:
	print_stack()
	if behaviourID == &"":
		behaviourID = StringName(self.name)
	else:
		self.name = behaviourID
	if !behaviourManager and get_parent() is AIBehaviourManagerComponent:
		behaviourManager = get_parent()
	else:
		printerr("error getting parent reference", get_parent(), behaviourManager)

func _ready() -> void:
	behaviourManager.request_register_behaviour_component(self)

func on_enter_state()->void:
	pass

func set_references(core:AICoreComponent, pwn:CharacterPawn3D):
	aiCore = core
	pawn = pwn
	pawnRID = pawn.pawnRID
