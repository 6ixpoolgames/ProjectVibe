extends Node3D

class_name AIStateManagerComponent

enum AIState {Idle, Alerted, Aggressive, Routed, Incapacitated, Dead}

var currState:= AIState.Idle

#node reference
var pawn: CharacterPawn3D
var AIManager: AIUnitManager
var sensingComponent: AISensingComponent

var referencesUpdated:= false

func _ready() -> void:
	initialize()
	if get_parent_node_3d() is AIUnitManager:
		AIManager = get_parent_node_3d()
		AIManager.component_has_intialized(self)

func initialize():
	pass

func _physics_process(_delta: float) -> void:	
	if pawn and AIManager.poll_now():
		check_idle()
		check_alerted()
		check_aggresive()
	check_dead()
	if GlobalTools.go_print:
		print(pawn, " current AI state: ", currState)
	pass

func check_dead():
	if pawn != null and pawn.StatManager.statNames.has("Health"):
		if pawn.StatManager.request_get_current_value("Health") <= 0:
			currState = AIState.Dead

func check_idle():
	if pawn!= null and sensingComponent != null and not currState == AIState.Dead:
		if sensingComponent.entitiesInLOS.size() <= 0 and sensingComponent.entitiesInDetectionAngle.size() <= 0:
			currState = AIState.Idle
			if GlobalTools.go_print:
				print("set to idle")
				
func check_alerted():
	if pawn!= null and sensingComponent != null and not currState == AIState.Dead:
		if sensingComponent.entitiesInLOS.size() <= 0 and sensingComponent.entitiesInDetectionAngle.size() > 0:
			currState = AIState.Alerted
			if GlobalTools.go_print:
				print("set to alerted")

func check_aggresive():
	if pawn!= null and sensingComponent != null and not currState == AIState.Dead:
		if sensingComponent.entitiesInLOS.size() > 0:
			currState = AIState.Aggressive
			if GlobalTools.go_print:
				print("set to aggresive")
