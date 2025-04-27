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
	if pawn:
		check_dead()
		check_incapacited() 
		if AIManager.poll_now():
			check_routed()
			check_idle()
			check_alerted()
			check_aggresive()
	
	if GlobalTools.go_print:
		print(pawn, " current AI state: ", currState)
	pass

func check_dead()->void:
	if pawn != null and pawn.StatManager.statNames.has("Health"):
		if pawn.StatManager.request_get_current_value("Health") <= 0:
			currState = AIState.Dead

func check_idle()->void:
	if pawn!= null and sensingComponent != null and not currState == AIState.Dead and not currState == AIState.Routed:
		if sensingComponent.entitiesInLOS.size() <= 0 and sensingComponent.entitiesInDetectionAngle.size() <= 0:
			currState = AIState.Idle
			if GlobalTools.go_print:
				print("set to idle")
				
func check_alerted()->void:
	if pawn!= null and sensingComponent != null and not currState == AIState.Dead and not currState == AIState.Routed:
		if sensingComponent.entitiesInLOS.size() <= 0 and sensingComponent.entitiesInDetectionAngle.size() > 0:
			currState = AIState.Alerted
			if GlobalTools.go_print:
				print("set to alerted")

func check_aggresive()->void:
	if pawn!= null and sensingComponent != null and not currState == AIState.Dead and not currState == AIState.Routed:
		if sensingComponent.entitiesInLOS.size() > 0:
			currState = AIState.Aggressive
			if GlobalTools.go_print:
				print("set to aggresive")

var routedHealthMultiplier: float = .15
func check_routed()->void:
	if pawn!= null and sensingComponent != null and not currState == AIState.Dead:
		var pawnHealth = pawn.StatManager.get_stat_with_name("Health").get_current_value()
		var maxPawnHealth = pawn.StatManager.get_stat_with_name("Health").get_max_value()
		if sensingComponent.entitiesInLOS.size() > 0 and pawnHealth < maxPawnHealth * routedHealthMultiplier:
			currState = AIState.Routed
			if GlobalTools.go_print:
				print("set to routed")

var isIncapacitated:= false
func check_incapacited()->void:
	if !isIncapacitated:
		return
	else:
		if pawn!= null and not currState == AIState.Dead:
			currState = AIState.Incapacitated
			if GlobalTools.go_print:
				print("set to incapacitated")
