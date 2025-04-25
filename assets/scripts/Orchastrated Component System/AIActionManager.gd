extends Node3D

class_name AIActionManagerClass

var attachedActions: Array[ActionComponentBase]

func get_attached_actions()->Array[ActionComponentBase]:
	var buffer = get_children()
	attachedActions.clear()
	for a in buffer:
		if a is ActionComponentBase:
			attachedActions.append(a)
	return attachedActions

var validActions: Array[ActionComponentBase]
func poll_valid_actions():
	validActions.clear()
	for a in attachedActions:
		if a.is_valid():
			validActions.append(a)
		
		
func select_valid_action():
	validActions
	
