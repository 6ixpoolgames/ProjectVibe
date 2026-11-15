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
##     Claude 2026-11-10 (pawn spec 8.11): replaced by a combo made of boosts, with no follow-up window. Three swings answer to Attack:
##     MeleeAttack (priority 10), SecondSwing (0, tagged combo.second) and FinisherSwing (-10, tagged combo.finisher). Starting
##     MeleeAttack boosts combo.second by 20 for 0.6 s, and starting SecondSwing boosts combo.finisher by 40 for 0.6 s
##     (resources/effects/combo_*_boost.tres). So clicking again quickly gives swing, second, finisher; slowly, swing, swing. A click
##     during a swing waits in its buffer, since the next swing can't cancel it (interrupt priority 10 against 15). MeleeAttack has no
##     cooldown here (_debug_cooldowns), so the boosts alone decide. Each swing's damage and knockback are its on-hit effects.
##   - Special (the right mouse button, the action secondary) is HeavyAttack: a slow, wide, hard-hitting swing on a 6 s cooldown.
##   - The goblins use the same requests: their Attack behaviour presses attack (and gets the combo's next swing when it presses
##     again quickly; Claude 2026-11-10), and a second one, HeavyAttack, presses special and scores higher (0.95 against 0.9), so they use it whenever
##     it's ready and they're in its range.
##
## Claude 2026-11-13, the owner's request: bigger teams, and NPCs on the players' team.
##   - team_size (8) is how many each team has. The red and blue spawners keep that many goblins alive (they kept 4).
##   - The AllySpawner keeps team_size minus the number of players alive: soldiers on the players' team (faction_ally.tscn, the
##     goblins' AI and abilities on team 0). So with 1 player there are 7, with 3 players 5, and with team_size players or more none.
##     The count is worked out again whenever a player joins or leaves. A player joining doesn't remove a soldier: there's one fewer
##     from the next soldier death on, because that one isn't replaced.
##   - Everyone has the usual Health again (100). It was ten times that, 2026-11-12, to watch the AI group up.
extends "res://assets/scripts/samples/ArenaSample.gd"

const FACTION_PLAYER_SCENE := preload("res://assets/scenes/samples/faction_player.tscn")
const RED_GOBLIN_SCENE := preload("res://assets/scenes/samples/faction_goblin.tscn")
const BLUE_GOBLIN_SCENE := preload("res://assets/scenes/samples/faction_goblin_blue.tscn")
const ALLY_SCENE := preload("res://assets/scenes/samples/faction_ally.tscn") # Claude 2026-11-13
# Claude 2026-11-10: GOBLINS_PER_TEAM is gone. The scene's RedSpawner and BlueSpawner keep four of each alive, 12 m either side of
# the middle and facing each other, and the arena's script switches them on when a game starts.
## The key action for the special attack. The project has none for the right mouse button, so this sample adds one.
const SPECIAL_KEY_ACTION := &"attack_secondary"

## Claude 2026-11-13: how many pawns each team has: red goblins, blue goblins, and the players with their soldiers together.
@export_range(0, 100, 1, "or_greater") var team_size := 8

var _special_key_bound := false
var _players := {} # Claude 2026-11-13: peer -> true for every player in the game (0 offline), for the soldier count


# Claude 2026-11-13: _health_multiplier() is gone from here, so everyone has the usual Health, the owner's request. It was 10 (1000
# Health) from 2026-11-12, so fights lasted long enough to watch the AI group up.


## Claude 2026-11-10: the arena's cooldowns without MeleeAttack's, so the combo is decided by its boosts alone (pawn spec 8.11).
func _debug_cooldowns() -> Dictionary:
	var cooldowns: Dictionary = super().duplicate()
	cooldowns.erase("MeleeAttack")
	return cooldowns


func _ready() -> void:
	super()
	# The same type names as the arena, so its spawning works unchanged, with this sample's scenes; every machine registers the same.
	NetworkSession.register_type("pawn", FACTION_PLAYER_SCENE)
	NetworkSession.register_type("goblin", RED_GOBLIN_SCENE)
	NetworkSession.register_type("goblin_blue", BLUE_GOBLIN_SCENE)
	NetworkSession.register_type("ally", ALLY_SCENE) # Claude 2026-11-13
	# Claude 2026-11-13: a player leaving frees a place on the players' team for a soldier.
	# GDScript note: a lambda can be connected to a signal like a function; it's given the signal's values (here the peer).
	NetworkSession.player_left.connect(func(peer: int) -> void:
		_players.erase(peer)
		_update_team_sizes())
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


# --- Claude 2026-11-13: team sizes ---


## Every player is counted before the spawners start, so the soldiers fill the rest of the team from the start.
func _start_offline() -> void:
	_players[0] = true
	super()


## Server: a player has arrived (the host too, when hosting), so there's one soldier fewer.
func _on_player_connected(peer: int) -> void:
	_players[peer] = true
	super(peer)
	_update_team_sizes()


func _start_spawners() -> void:
	_update_team_sizes()
	super()


## Sets how many each spawner keeps: team_size goblins of each colour, and the players' team topped up to team_size with soldiers.
func _update_team_sizes() -> void:
	$Spawning/RedSpawner.keep_alive = team_size
	$Spawning/BlueSpawner.keep_alive = team_size
	$Spawning/AllySpawner.keep_alive = maxi(0, team_size - _players.size())


## Soldiers are on the players' team but played by the AI, so they're told apart by scene: only the player scene is a player's.
func _is_npc(pawn: Pawn) -> bool:
	return pawn.scene_file_path != FACTION_PLAYER_SCENE.resource_path


# Claude 2026-11-10: _spawn_wave() is gone from here: the arena's version refills the spawners, which this scene has one per colour.


func _keys_text() -> String:
	# Claude 2026-11-10: the combo (pawn spec 8.11)
	return super() + "\nAttack: left mouse (quickly again: second swing, then finisher)    Special: right mouse (heavy, 6 s cooldown)    Red and blue goblins fight each other too; soldiers fight on your side"
