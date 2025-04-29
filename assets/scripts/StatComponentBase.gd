extends Node
class_name StatComponentBase

signal stat_changed(current: float, change: float)
signal limit_changed(newMin: float, newLimit: float)

@export var statName: String ##sets name to string
@export var maxValue:float = 10 ##base MAX value of the stat
@export var currValue:float = maxValue ##CURRENT value of the stat. Set to maxValue if < 0.
@export var baseRegen: float = 0 ##base regeneration rate of the stat per second. if negative, constantly damages
var regenValue: float
var limitValue:float ##the current max value of the stat. For handling buffs/debuffs 
var minValue: float = 0

var StatManager: CharacterStatManager

func _init(statBlock:StatBlockRes = null)->void:
	if statBlock == null:
		return
	set_all_values(statBlock)

func _ready():
	set_physics_process(regenValue != 0)
	if currValue < 0 or currValue > maxValue:
		currValue = limitValue
	if !StatManager:
		if get_parent() is CharacterStatManager:
			StatManager = get_parent() #kinda relies on proper node heirarchy on declaration so be sure to make it so
			StatManager.request_add_stat_to_manager(self)
			print("requested ", StatManager, " to add ", self)
		else:
			printerr("StatComponent not child of CharacterStatManager")
	
func _enter_tree() -> void:
	if statName != "":
		name = statName
	limitValue = maxValue
	regenValue = baseRegen
	
	
func _physics_process(delta: float) -> void:
	delta_stat(regenValue, delta)

##add [param value] to CURRENT stat amount, up to max. generally used for healing
func increase_stat(value:float):
	currValue += value
	currValue = clampf(currValue, minValue, limitValue)
	stat_changed.emit(currValue, value)

##subtract [param value] from CURRENT stat amount, down to min. generally used for damage
func decrease_stat(value:float):
	currValue -= value
	currValue = clampf(currValue, minValue, limitValue)
	stat_changed.emit(currValue, value)

##set the stats max value. used for handling buffs/debuffs generally 
func set_stat_limit(value:float):
	limitValue = value
	currValue = clampf(currValue, minValue, limitValue)
	stat_changed.emit(currValue, value)
	limit_changed.emit(minValue, limitValue)

##added for completion. Might be useful for last stand or immortality effects
func set_stat_min(value:float):
	minValue = value
	limit_changed.emit(minValue, limitValue)

##sets stat regen to [param value] per second	
func set_stat_regen(value:float):
	regenValue = value
	set_physics_process(regenValue != 0)
	pass
	
##stat value change per second. generally used for stat regen (e.g. STAMINA).
##[param value] is change/sec, [param delta] is dTime from process/physics process
func delta_stat(value:float, delta:float):
	currValue += value * delta
	currValue = clampf(currValue,minValue,limitValue)
	stat_changed.emit(currValue, value)

func set_stat_name(newName: String)-> void:
	#statName = newName
	name = newName

func set_all_values(statBlock:StatBlockRes)->void:
	name = statBlock.statName
	maxValue = statBlock.maxValue
	currValue = clampf(statBlock.currValue,minValue,maxValue)
	baseRegen = statBlock.baseRegen

## Getters for external access
func get_current_value() -> float:
	return currValue

func get_max_value() -> float:
	return limitValue

func get_regen_rate() -> float:
	return regenValue
