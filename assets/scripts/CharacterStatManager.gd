extends Node
class_name CharacterStatManager

var allStats: Array[StatComponentBase]
var statNames: Array[String]

#var pawn: CharacterPawn3D


##consider adding a check if all children that are statComponents have been added to the manager to set a flag that manager is fully "ready". Not seeing a need for such a flag though quite yet.
func _ready() -> void:
	#if get_parent() is CharacterPawn3D:
		#pawn = get_parent()
	#readySet = true
	GlobalTools.print_sequence_counter(self, "_ready")
	pass

var readySet:= false
func pawn_ready()->void:
	GlobalTools.print_sequence_counter(self, "pawn_ready")
	print("pr ", self.get_parent(), " ", allStats, " ", statNames)
	readySet = true

##called by statComponent base to add itself to the manager's arrays
func request_add_stat_to_manager(stat: StatComponentBase)->void:
	if not allStats.has(stat):
		allStats.append(stat)
		statNames.append(stat.name)
		GlobalTools.print_sequence_counter(self, "request_add_stat_to_manager")
		print(self, " stat added: ", stat.name)
		print("&&& all stats",allStats, " ", statNames)

##check statNames array for stat component with [param statName] and calls its increase_stat() method w/ [param value]. Returns true/false for success/failure to find and modify stat.
func request_increase_stat(statName: String, value: float) -> bool:
	var index = statNames.find(statName)
	if index == -1:
		return false
	else:
		allStats[index].increase_stat(value)
		return true

##check statNames array for stat component with [param statName] and calls its decrease_stat() method w/ [param value]. Returns true/false for success/failure to find and modify stat.
func request_decrease_stat(statName: String, value: float) -> bool:
	var index = statNames.find(statName)
	if index == -1:
		return false
	else:
		allStats[index].decrease_stat(value)
		return true

##check statNames array for stat component with [param statName] and calls its set_stat_limit() method w/ [param value]. Returns true/false for success/failure to find and modify stat.
func request_set_stat_limit(statName: String, value: float) -> bool:
	var index = statNames.find(statName)
	if index == -1:
		return false
	else:
		allStats[index].set_stat_limit(value)
		return true

##check statNames array for stat component with [param statName] and calls its set_stat_min() method w/ [param value]. Returns true/false for success/failure to find and modify stat.
func request_set_stat_min(statName: String, value: float) -> bool:
	var index = statNames.find(statName)
	if index == -1:
		return false
	else:
		allStats[index].set_stat_min(value)
		return true


##check statNames array for stat component with [param statName] and calls its set_stat_regen() method w/ [param value]. Returns true/false for success/failure to find and modify stat.
func request_set_stat_regen(statName: String, value: float) -> bool:
	var index = statNames.find(statName)
	if index == -1:
		return false
	else:
		allStats[index].set_stat_regen(value)
		return true

##check statNames array for stat component with [param statName] and calls its get_current_value() method. Returns true/false for success/failure to find and modify stat. Defaults to 0 if invalid
func request_get_current_value(statName: String) -> float:
	var index = statNames.find(statName)
	if index == -1:
		printerr("invalid stat name: ", statName, " !")
		return 0
	else:
		var result := allStats[index].get_current_value()
		return result

##check statNames array for stat component with [param statName] and calls its get_max_value() method. Returns true/false for success/failure to find and modify stat. Defaults to 0 if invalid
func request_get_max_value(statName: String) -> float:
	var index = statNames.find(statName)
	if index == -1:
		printerr("invalid stat name: ", statName, " !")
		return 0
	else:
		var result := allStats[index].get_max_value()
		return result

##check statNames array for stat component with [param statName] and calls its get_regen_rate() method. Returns true/false for success/failure to find and modify stat. Defaults to 0 if invalid
func request_get_regen_rate(statName: String) -> float:
	var index = statNames.find(statName)
	if index == -1:
		printerr("invalid stat name: ", statName, " !")
		return 0
	else:
		var result := allStats[index].get_regen_rate()
		return result

func get_stat_with_name(stat_name:String) -> StatComponentBase:
	print(statNames, " " ,  self.get_parent())
	if !statNames.is_empty():
		var index = statNames.find(stat_name)
	#if index >= 0:
		return allStats[index]
	else:
		print(self, " returned NULL")
		return null
