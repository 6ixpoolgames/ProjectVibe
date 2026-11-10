## Written by Claude (claude-opus-5-5), 2026-11-09: runs faction_arena_sample.tscn, the arena with three factions, the owner's request:
## red goblins (team 1) and blue goblins (team 2), which fight each other and the players, and the players (team 0): the host and
## everyone who joins. For testing how the AI's behaviours and abilities choose, with the arena's debug keys (P to pause, ←/→ to step
## and scrub back, F3 for the readouts and debug shapes).
##
## Everything else is the arena (ArenaSample.gd, which this extends): Offline, Host or Join, R to refill the spawners, Tab to possess.
##
## The attacks, for players and goblins alike (faction_abilities.tscn):
##   - Attack (the left mouse button, the action primary) is a request: it starts the normal swing, MeleeAttack, when that's ready,
##     and otherwise, within 0.6 s of a normal swing ending, the quicker, lighter FollowUpAttack. The normal swing has a 0.8 s cooldown
##     here (the arena's DEBUG_COOLDOWNS; Claude 2026-11-10: was 1.5), so swing, then click again quickly for the follow-up. Priority picks: higher wins, with no
##     jitter on these two.
##   - Special (the right mouse button, the action secondary) is HeavyAttack: a slow, wide, hard-hitting swing on a 6 s cooldown.
##   - The goblins use the same requests: their Attack behaviour presses attack (and gets the follow-up when the normal swing is
##     cooling down), and a second one, HeavyAttack, presses special and scores higher (0.95 against 0.9), so they use it whenever
##     it's ready and they're in its range.
extends "res://assets/scripts/samples/ArenaSample.gd"

const FACTION_PLAYER_SCENE := preload("res://assets/scenes/samples/faction_player.tscn")
const RED_GOBLIN_SCENE := preload("res://assets/scenes/samples/faction_goblin.tscn")
const BLUE_GOBLIN_SCENE := preload("res://assets/scenes/samples/faction_goblin_blue.tscn")
# Claude 2026-11-10: GOBLINS_PER_TEAM is gone. The scene's RedSpawner and BlueSpawner keep four of each alive, 12 m either side of
# the middle and facing each other, and the arena's script switches them on when a game starts.
## The key action for the special attack. The project has none for the right mouse button, so this sample adds one.
const SPECIAL_KEY_ACTION := &"attack_secondary"

var _special_key_bound := false


func _ready() -> void:
	super()
	# The same type names as the arena, so its spawning works unchanged, with this sample's scenes; every machine registers the same.
	NetworkSession.register_type("pawn", FACTION_PLAYER_SCENE)
	NetworkSession.register_type("goblin", RED_GOBLIN_SCENE)
	NetworkSession.register_type("goblin_blue", BLUE_GOBLIN_SCENE)
	if not InputMap.has_action(SPECIAL_KEY_ACTION):
		InputMap.add_action(SPECIAL_KEY_ACTION)
		var click := InputEventMouseButton.new()
		click.button_index = MOUSE_BUTTON_RIGHT
		InputMap.action_add_event(SPECIAL_KEY_ACTION, click)


func _process(delta: float) -> void:
	super(delta)
	# The player controller is made by the game mode when it's first needed, so this binds the special attack once it exists.
	if not _special_key_bound and GameMode.possession_coordinator and GameMode.possession_coordinator.controller:
		GameMode.possession_coordinator.controller.action_keys[&"secondary"] = SPECIAL_KEY_ACTION
		_special_key_bound = true


# Claude 2026-11-10: _spawn_wave() is gone from here: the arena's version refills the spawners, which this scene has one per colour.


func _keys_text() -> String:
	return super() + "\nAttack: left mouse (again quickly: follow-up)    Special: right mouse (heavy, 6 s cooldown)    Red and blue goblins fight each other too"
