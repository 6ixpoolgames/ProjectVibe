extends Node

class_name AIStateManagerComponent

enum AIState {Idle, Alerted, Aggressive, Routed, Incapacitated, Dead}

var currState:= AIState.Idle
var isActive:= false

#node reference
#var pawn: CharacterPawn3D
#var AIManager: AIUnitManager
#var sensingComponent: AISensingComponent

var referencesUpdated:= false

func _ready() -> void:
	
	#initialize()
	#if get_parent_node_3d() is AIUnitManager:
	#	AIManager = get_parent_node_3d()
	#	AIManager.component_has_intialized(self)
	#GlobalTools.print_sequence_counter(self, "_ready")
	pass
	
func _enter_tree() -> void:
	pass
	
func pull_component_references(core:AICoreComponent,sense:AISensingComponent, statMan: CharacterStatManager):
	AICore = core
	Pawn = AICore.Pawn
	SensingComponent = sense
	StatManager = statMan
	referencesUpdated = true
	print("references passed! core: ", core, " pwn: ", Pawn, " sense:", SensingComponent, " statMan:" ,StatManager)

func _physics_process(_delta: float) -> void:
	check_all_references_valid()
	if isActive and referencesValid:
		if Pawn:
			check_dead()
			check_incapacited() 
			if AICore.poll_now():
				check_routed()
				check_idle()
				check_alerted()
				check_aggresive()
			if GlobalTools.go_print:
				print(Pawn, " current AI state: ", currState, "   [0=idle 1=alerted 2=aggressive 3=routed 4=incapacitated 5=dead]")
				print(" stat ", StatManager, " hp ", StatManager.get_stat_with_name("Health").get_current_value())
		else:
			if GlobalTools.go_print:
				print(Pawn,self ," StateManager is inactive! isActive",isActive, " referencesValid:",referencesValid)
	pass

func check_dead()->void:
	if Pawn != null and StatManager.statNames.has("Health"):
		if StatManager.request_get_current_value("Health") <= 0:
			currState = AIState.Dead

func check_idle()->void:
	if Pawn != null and SensingComponent != null and not currState == AIState.Dead and not currState == AIState.Routed:
		if SensingComponent.entitiesInLOS.size() <= 0 and SensingComponent.entitiesInDetectionAngle.size() <= 0:
			currState = AIState.Idle
			if GlobalTools.go_print:
				print("set to idle")
				
func check_alerted()->void:
	if Pawn != null and SensingComponent != null and not currState == AIState.Dead and not currState == AIState.Routed:
		if SensingComponent.entitiesInLOS.size() <= 0 and SensingComponent.entitiesInDetectionAngle.size() > 0:
			currState = AIState.Alerted
			if GlobalTools.go_print:
				print("set to alerted")

func check_aggresive()->void:
	if Pawn!= null and SensingComponent != null and not currState == AIState.Dead and not currState == AIState.Routed:
		if SensingComponent.entitiesInLOS.size() > 0:
			currState = AIState.Aggressive
			if GlobalTools.go_print:
				print("set to aggresive")

var routedHealthMultiplier: float = .15
func check_routed()->void:
	if Pawn != null and SensingComponent != null and not currState == AIState.Dead:
		var pawnHealth:float
		var maxPawnHealth:float
		if StatManager.get_stat_with_name("Health"):
			pawnHealth = StatManager.get_stat_with_name("Health").get_current_value()
			maxPawnHealth = StatManager.get_stat_with_name("Health").get_max_value()
		else:
			print("shits broken", Pawn, " ", StatManager)
		if SensingComponent.entitiesInLOS.size() > 0 and pawnHealth < maxPawnHealth * routedHealthMultiplier:
			currState = AIState.Routed
			if GlobalTools.go_print:
				print("set to routed ", pawnHealth, " ", maxPawnHealth)

var isIncapacitated:= false
func check_incapacited()->void:
	if !isIncapacitated:
		return
	else:
		if Pawn!= null and not currState == AIState.Dead:
			currState = AIState.Incapacitated
			if GlobalTools.go_print:
				print("set to incapacitated")
				

func set_is_state_manager_active(active:bool)->void:
	isActive = active

var referencesValid:= false
var doOnce:=false
func check_all_references_valid()->bool:
	if !doOnce:
		if StatManager:
			if Pawn:
				if AICore:
					if SensingComponent:
						referencesValid = true
						doOnce = true
		return referencesValid
	else:
		return referencesValid

#node references
var isReferenceSet:= false
var Pawn: CharacterPawn3D
#var CharacterModel: MeshInstance3D
#var CollisionCapsule: CollisionShape3D
#var ControllerManager: MovementControllerManager
var StatManager: CharacterStatManager
#var CameraControllerArm: PawnCameraController
var AICore: AICoreComponent
var SensingComponent: AISensingComponent
#var AIStateManager: AIStateManagerComponent
func set_references(references:Array[Node])->void:
	for r in references:
		if r is CharacterPawn3D:
			Pawn = r
#		if r.name == "CharacterModel":
#			CharacterModel = r
#		if r.name == "CollisionCapsule":
#			CollisionCapsule = r
#		if r is MovementControllerManager:
#			ControllerManager = r
		if r is CharacterStatManager:
			StatManager = r
#		if r is PawnCameraController:
#			CameraControllerArm = r
		if r is AICoreComponent:
			AICore = r
		if r is AISensingComponent:
			SensingComponent = r
#		if r is AIStateManagerComponent:
#			AIStateManager = r
#		if r is AIBehaviourManagerComponent:
#			AIBehaviourManager = r
	isReferenceSet = true
	print(">>>>references", references)
	GlobalTools.print_sequence_counter(self, "set_references")
	
