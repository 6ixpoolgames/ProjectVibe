extends PlayerMovementController#"res://assets/scripts/PlayerMovementController.gd"

func create_nav_agent(overwrite:bool):
	var thisChildren = self.get_children()
	var navAgent = NavigationAgent3D.new()
	navAgent.name = "playerNavAgent"
	
