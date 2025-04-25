extends Node

## Returns an array of all ascendant nodes (parent, grandparent, etc.) up to the root.
## If the node has no parent, returns an empty array.
##should probably move to a global tools singleton
func get_all_ascendants(target:Node) -> Array[Node]:
	var ascendants: Array[Node] = []
	var current: Node = target.get_parent()    
	while current:
		ascendants.append(current)
		current = current.get_parent()    
	return ascendants

##returns array of all descendant nodes. Can be offloaded to global tools singleton probably
func get_all_descendants(node: Node, descendants: Array = []) -> Array:
	for child in node.get_children():
		descendants.append(child)
		get_all_descendants(child, descendants)
	return descendants
	
#consider moving to a global tools singleton
var printTimer: int = -1
var go_print: bool = false
##counts down printTime number of frames before setting "go_print" to true, sets it to false every other frame. To apply, just add "if goPrint:" before calling a debug print output to 'rationalize' it
## [param printTime] is number of frames before setting go_print to true.
func printFuncRationalizer(printTime: int):
	if printTimer > 0:
		printTimer -= 1
		go_print = false
	else:
		printTimer = printTime
		go_print = true
		
func _physics_process(delta: float) -> void:
	printFuncRationalizer(60)
	
