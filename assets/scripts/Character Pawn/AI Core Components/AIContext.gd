## Written by Claude (claude-opus-5-5), 2026-11-03: everything a behaviour may need, handed to it in one object.
## The behaviour manager owns one AIContext per pawn and passes it into every behaviour call
## (is_available, score, enter, tick, exit), so behaviours never fetch references themselves.
##
## Escape clauses: any field can be null (a pawn without memory, a test with no pawn at all).
## The helper methods check for that and just return false, so a behaviour never crashes on a missing part.
extends RefCounted
class_name AIContext

var pawn: CharacterPawn3D
var nexus: PawnNexusComponent
var aiCore: AICoreComponent
var memory: AIMemoryComponent
var sensing: AISensingComponent
var statManager: CharacterStatManager
var movement: MovementControllerManager
var currentState: StringName = &"" ## the state manager's current state, or &"" if none is known

var blackboard: Dictionary = {} ## free scratch space shared by this pawn's behaviours


##re-reads the pawn's components. Called by the manager before each decision; cheap.
##Fields with no source are left as they are, so tests can fill them by hand.
func refresh() -> void:
	if aiCore == null:
		return
	nexus = aiCore.nexus
	if nexus:
		pawn = nexus.pawn
		statManager = nexus.statManager
		if statManager == null and pawn: # Claude 2026-11-04: the stat manager registers on the pawn, not the nexus
			statManager = pawn.statManager
		if movement == null or not is_instance_valid(movement):
			movement = _find_movement_manager()
	memory = aiCore.aiMemory
	sensing = aiCore.sensingComponent
	var stateManager = aiCore.aiStateManager
	if stateManager and stateManager.has_method("get_current_state_name"):
		currentState = stateManager.get_current_state_name()


#region building blocks for behaviours
##asks the pawn's AI movement controller to walk to [param position]. False if the pawn has none.
func move_to(position: Vector3) -> bool:
	var ai := _ai_controller()
	if ai == null:
		return false
	ai.move_to(position)
	return true


##stops AI-driven movement. False if the pawn has no AI movement controller.
func stop_moving() -> bool:
	var ai := _ai_controller()
	if ai == null:
		return false
	ai.stop_navigation()
	return true


##true if this pawn has an AI movement controller, i.e. move_to() will do something
func can_move() -> bool:
	return _ai_controller() != null


##true while the AI movement controller is still heading somewhere
func is_moving() -> bool:
	var ai := _ai_controller()
	return ai != null and ai.navigationToggle


## Claude 2026-11-04: stat helpers for states and behaviours.
##current value of stat [param stat_name], or [param fallback] if the pawn has no such stat
func get_stat(stat_name: String, fallback: float = -1.0) -> float:
	var stat := _find_stat(stat_name)
	return stat.get_current_value() if stat else fallback


##current / max of stat [param stat_name] (0..1), or [param fallback] if the pawn has no such stat
func get_stat_fraction(stat_name: String, fallback: float = -1.0) -> float:
	var stat := _find_stat(stat_name)
	if stat == null or stat.get_max_value() <= 0.0:
		return fallback
	return stat.get_current_value() / stat.get_max_value()


##the pawn's position, or Vector3.ZERO if there is no pawn
func get_position() -> Vector3:
	return pawn.global_position if pawn else Vector3.ZERO
#endregion


func _ai_controller() -> AIControllerBase:
	if movement and is_instance_valid(movement) and movement.aiController and is_instance_valid(movement.aiController):
		return movement.aiController
	return null


#checks statNames first: CharacterStatManager.get_stat_with_name() returns the LAST stat for an unknown name
func _find_stat(stat_name: String) -> StatComponentBase:
	if statManager == null or not is_instance_valid(statManager) or not statManager.statNames.has(stat_name):
		return null
	return statManager.get_stat_with_name(stat_name)


func _find_movement_manager() -> MovementControllerManager:
	for c in nexus.get_children():
		if c is MovementControllerManager:
			return c
	return null
