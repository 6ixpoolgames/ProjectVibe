## Written by Claude (claude-opus-5-5), 2026-11-15: runs mass_battle_sample.tscn, the owner's large test: three factions of team_size
## (50 by default, up to 100 or more) march from spawners far apart to a meeting point in the middle and fight there. For seeing how
## close a big fight gets to the edge of what a tick can hold, with chunk streaming, freezing and unfreezing AI, and everything else
## going on at once. It's the faction arena (FactionArenaSample.gd, which this extends) made big:
##
## The level (mass_battle_sample.tscn):
##   - Smaller chunks than the other samples (64 m, not 128), and every source loads ground 160 m around it (not 320), so a spread-out
##     level fits in a test. Load distances are on each StreamingSource node, and load_distance below for players and heroes (Claude 2026-11-16: the game's
##     setting for every pawn that keeps the world loaded, PawnDefaultsRes.world_load_distance, set while this level runs).
##   - Three faction spawners, 300 m from the middle and 120 degrees apart: red goblins, blue goblins, and the players' soldiers. Each
##     has a StreamingSource child, so the ground around it is always loaded, wherever the players are. Each faction's hero has its
##     own spawner beside it, which brings it back 30 s after it dies.
##   - A RallyPoint in the middle (the rally_point group). Every AI pawn has AIGoToPointBehaviour, so an idle one marches there; it
##     fights whatever it meets on the way, and mills about once it's there.
##   - A CentreSource in the middle, a StreamingSource the C key switches on and off. With it on, the spawners' ground (160 m in from
##     300 m out) meets the middle's (160 m out), so the whole way is loaded. With it off there's a gap in the middle, and the AI
##     switch-off (AIActivationManager) freezes every AI pawn there, unless a hero or a player is near enough to keep the ground loaded.
##   - Heroes (hero_red.tscn, hero_blue.tscn, hero_ally.tscn): a bigger figure on a 1.5 times bigger capsule, 1000 Health, 15% slower,
##     hitting 1.5 times as hard with a little more reach, and keeps the world loaded itself (its PawnStreamingSource's keeps_world_loaded). H switches every hero's
##     source on and off, apart from the centre's.
##   - The player starts at the players' spawner, 285 m from the middle, so they can watch the march or walk in.
##
## Keys, besides the faction arena's: C the centre's source, H the heroes' sources, V the overview of the middle (Claude 2026-11-16,
## the owner's call: as U, it lets go of your pawn, which its AI takes over, and you fly the spectator, starting at the overview point
## high above the middle; pressed while flying, it only takes you back there; U takes your pawn back), = and - team_size up or down by 10 (the
## spawners top up to it; lowering it removes nobody, those that die just aren't replaced). F3 still shows the readouts and debug
## shapes, which are off to begin with: hundreds of floating labels cost more than the AI. The AI debug timeline (← to step back)
## isn't recorded here, for the same reason; P still pauses.
## The team sizes, how many of each faction are alive, and the switches are in the status text at the top left.
##
## Claude 2026-11-16: performance is diagnostics v0's (docs/diagnostics/DIAGNOSTICS_SPEC.md), in every debug build: F1 lists its keys,
## F4 shows the timings, and a session log is written per instance. The PerformanceOverlay this sample had (F4) is gone. For runs
## from the command line, after "--":
##   --perf-log       prints the diagnostics summary every 5 s, as the session log has it
##   --near-middle    the player's pawn starts 30 m from the middle instead of at its spawner, so the fight comes to it
##   --overhead       starts at the overview of the middle (V), the owner's way of watching the fight
##
## Claude 2026-11-16: the spectator here doesn't keep the world loaded, as V's old camera didn't: the spawners, heroes and the centre
## have their own sources, and C still freezes the middle while you watch it from above. A player's pawn let go of (U or V) follows the
## heroes' switch (H), the owner's call: it keeps the world loaded around it while H is on, and not while it's off.
extends "res://assets/scripts/samples/FactionArenaSample.gd"

const HERO_RED_SCENE := preload("res://assets/scenes/samples/hero_red.tscn")
const HERO_BLUE_SCENE := preload("res://assets/scenes/samples/hero_blue.tscn")
const HERO_ALLY_SCENE := preload("res://assets/scenes/samples/hero_ally.tscn")

## How far players' pawns and heroes keep ground loaded here, in metres, the same as the level's other sources. Claude 2026-11-16 (pawn M2): the
## game's setting now (PawnDefaultsRes.world_load_distance), so this level sets it on its copy of the defaults while it runs
## (ArenaSample makes the copy and puts the old ones back). A setter, so the start menu's match options can change it too.
@export_range(0.0, 2000.0, 1.0, "or_greater") var load_distance := 160.0:
	set(value):
		load_distance = value
		var defaults := _level_defaults() # Claude 2026-11-16 (audit): ArenaSample's copy, or null before the level is set up
		if defaults:
			defaults.world_load_distance = value
## Claude 2026-11-16 (the owner's request: spawns closer together, for a quick peak-capacity test): how far the factions' spawners
## are from the middle, in metres. The scene is laid out at 300, where the march takes about a minute; at 40 they meet within seconds.
## The heroes' spawners and the player's start keep their distances from their faction's spawner. From the command line:
## --spawn-distance=40.
@export_range(10.0, 1000.0, 5.0, "or_greater") var spawn_distance := 300.0:
	set(value):
		spawn_distance = value
		if is_node_ready():
			_place_spawners()
## Claude 2026-11-16: the centre's source (C) and the heroes' (H) as settings, so the start menu's match options can set them.
var centre_source_on: bool:
	get:
		return is_centre_source_on() if is_node_ready() else true
	set(value):
		if is_node_ready():
			set_centre_source(value)
var hero_sources_on: bool:
	get:
		return _hero_sources_on
	set(value):
		set_hero_sources(value)

## Claude 2026-11-16: the distance the scene's spawners are laid out at.
const LAID_OUT_SPAWN_DISTANCE := 300.0

var _laid_out := {} # Claude 2026-11-16: each spawning node -> its position as the scene lays it out

var _heroes: Array[Pawn] = []
var _player_pawns: Array[Pawn] = [] # Claude 2026-11-16: players' pawns, which follow H once let go of
var _hero_sources_on := true
# Claude 2026-11-16: _overhead and _camera_before are gone: V flies the spectator now, so there's no view to switch back to.
var _perf_log := false # Claude 2026-11-16: diagnostics, see the top of the file
var _near_middle := false
var _next_print_msec := 0


func _ready() -> void:
	super()
	NetworkSession.register_type("hero_red", HERO_RED_SCENE)
	NetworkSession.register_type("hero_blue", HERO_BLUE_SCENE)
	NetworkSession.register_type("hero_ally", HERO_ALLY_SCENE)
	# Claude 2026-11-16 (pawn M2): this level's load distance, as the game's setting while it runs.
	# Claude 2026-11-16: on ArenaSample's copy of the defaults (it makes it, with the AI brain, and puts the old ones back)
	load_distance = load_distance # Claude 2026-11-16 (audit): its setter puts it on the level's defaults, now they exist
	# Off to begin with: with hundreds of pawns, the readouts and shapes cost more than what they show. F3 brings them back.
	_show_readouts = false
	_debug_draw.visible = false
	# Claude 2026-11-16: diagnostics (see the top of the file)
	for argument in OS.get_cmdline_user_args():
		if argument == "--perf-log":
			_perf_log = true
		elif argument == "--near-middle":
			_near_middle = true
		elif argument == "--overhead":
			_go_to_overview.call_deferred() # once the scene's cameras are ready. Claude 2026-11-16: was _toggle_overhead
		elif argument.begins_with("--spawn-distance="): # Claude 2026-11-16
			spawn_distance = float(argument.trim_prefix("--spawn-distance="))
	_place_spawners() # Claude 2026-11-16: also when nothing changed it, since the setter waits for the level to be ready


# Claude 2026-11-16: --perf-log prints the diagnostics summary every 5 s. Samples, like debug tools, aren't in release builds, so a
# sample may name DiagnosticsManager; without the module (the project setting changed), it prints nothing.
func _process(delta: float) -> void:
	super(delta)
	if not _perf_log or Time.get_ticks_msec() < _next_print_msec:
		return
	_next_print_msec = Time.get_ticks_msec() + 5000
	var diagnostics := GameMode.get_module(DiagnosticsManager) as DiagnosticsManager
	if diagnostics:
		print(diagnostics.summary_text(diagnostics.get_summary(5.0)))



func _records_timeline() -> bool:
	return false


func _on_entity_spawned(entity: NetworkEntity) -> void:
	super(entity)
	var pawn := entity.get_parent() as Pawn
	if pawn == null:
		return
	if pawn.scene_file_path == FACTION_PLAYER_SCENE.resource_path:
		if _near_middle: # Claude 2026-11-16: diagnostics
			pawn.global_position = $RallyPoint.global_position + Vector3(0, 3, 30)
		# Claude 2026-11-16: follows H. While a player has it, it keeps the world loaded whatever this says.
		_player_pawns.append(pawn)
		pawn.streaming_source.keeps_world_loaded = _hero_sources_on
	elif _is_hero(pawn):
		_heroes.append(pawn)
		if not _hero_sources_on:
			pawn.streaming_source.keeps_world_loaded = false # Claude 2026-11-16 (pawn M2): was ai_loads_chunks


func _unhandled_key_input(event: InputEvent) -> void:
	var key := event as InputEventKey
	if key and key.pressed and not key.echo:
		match key.physical_keycode:
			KEY_C:
				set_centre_source(not is_centre_source_on())
				return
			KEY_H:
				set_hero_sources(not _hero_sources_on)
				return
			KEY_V:
				_go_to_overview() # Claude 2026-11-16: was _toggle_overhead
				return
			KEY_EQUAL:
				_change_team_size(10)
				return
			KEY_MINUS:
				_change_team_size(-10)
				return
	super(event)


## Claude 2026-11-16: moves every spawner, hero spawner and the player's start in or out along its line from the middle, so the
## factions start spawn_distance away. Each keeps its distance from the others on its line (a hero 15 m behind its faction, the
## player 15 m in front), and nothing comes closer than 5 m.
func _place_spawners() -> void:
	if _laid_out.is_empty():
		for node in $Spawning.get_children():
			if node is Node3D:
				_laid_out[node] = (node as Node3D).position
	for node: Node3D in _laid_out:
		var at: Vector3 = _laid_out[node]
		var flat := Vector2(at.x, at.z)
		if flat.length() < 0.01:
			continue
		var moved := flat.normalized() * maxf(flat.length() - LAID_OUT_SPAWN_DISTANCE + spawn_distance, 5.0)
		node.position = Vector3(moved.x, at.y, moved.y)


## Claude 2026-11-16: this level's settings for the start menu's match options (ArenaSample._build_match_options).
func _level_match_options() -> PackedStringArray:
	return PackedStringArray(["team_size", "spawn_distance", "centre_source_on", "hero_sources_on", "load_distance"])


## True while the middle's StreamingSource is on.
func is_centre_source_on() -> bool:
	return $CentreSource.active


## Switches the middle's StreamingSource on or off. Off, the ground there unloads (once no hero or player is near), and the AI
## pawns there freeze until it's back.
func set_centre_source(on: bool) -> void:
	$CentreSource.active = on


## Switches every hero's chunk source on or off, now and for heroes spawned later.
func set_hero_sources(on: bool) -> void:
	_hero_sources_on = on
	for hero in get_heroes():
		hero.streaming_source.keeps_world_loaded = on # Claude 2026-11-16 (pawn M2): was ai_loads_chunks
	# Claude 2026-11-16: and players' pawns, which counts once nobody plays them (U or V).
	for i in range(_player_pawns.size() - 1, -1, -1):
		if is_instance_valid(_player_pawns[i]):
			_player_pawns[i].streaming_source.keeps_world_loaded = on
		else:
			_player_pawns.remove_at(i)


# Claude 2026-11-16: a player's pawn let go of follows H here, rather than always keeping the world loaded as in the other arenas.
func _on_pawn_released(_peer: int, pawn: Pawn) -> void:
	if NetworkSession.is_client() or not is_instance_valid(pawn) or _is_npc(pawn):
		return
	pawn.streaming_source.keeps_world_loaded = _hero_sources_on


## The heroes alive in the level right now.
func get_heroes() -> Array[Pawn]:
	# Freed heroes drop out. GDScript note: walking backwards so removing doesn't skip the next one; and not filter(), which
	# returns a plain Array that can't be put back into this typed Array[Pawn] (a script error once a hero had died).
	for i in range(_heroes.size() - 1, -1, -1):
		if not is_instance_valid(_heroes[i]):
			_heroes.remove_at(i)
	return _heroes


func _is_hero(pawn: Pawn) -> bool:
	var path := pawn.scene_file_path
	return path == HERO_RED_SCENE.resource_path or path == HERO_BLUE_SCENE.resource_path or path == HERO_ALLY_SCENE.resource_path


func _change_team_size(by: int) -> void:
	team_size = maxi(team_size + by, 0)
	_update_team_sizes()


# Claude 2026-11-16: the arena's spectating (U, and V below), with the spectator keeping nothing loaded here (see the top of the file).
func _start_spectating() -> FreeFlyCamera:
	var spectator := super()
	if spectator:
		spectator.keeps_world_loaded = false
	return spectator


# Claude 2026-11-16 (the owner's call; was _toggle_overhead, which switched to the waiting camera and back): V. Not spectating, it does
# what U does, letting go of your pawn and flying the spectator, and then puts the spectator at the overview point (the waiting camera,
# high above the middle, facing the same way). Spectating, it only puts it there. U takes your pawn back. The spectator here keeps
# nothing loaded (see the top of the file).
func _go_to_overview() -> void:
	var coordinator := GameMode.possession_coordinator
	if coordinator == null or coordinator.controller == null:
		return
	if not coordinator.is_spectating():
		_start_spectating()
	var point: Node3D = $WaitingCamera
	coordinator.controller.place_spectator(point.global_transform)


# Claude 2026-11-16: the mass battle's lines in the status text (they were the PerformanceOverlay's extra lines): each faction's living
# pawns, the switches, and the team size.
func _status_text() -> String:
	return super() + "\n" + _mass_battle_lines()


func _mass_battle_lines() -> String:
	var alive := {0: 0, 1: 0, 2: 0}
	for pawn: Pawn in _readouts:
		if is_instance_valid(pawn) and not pawn.is_dead():
			alive[pawn.team] = alive.get(pawn.team, 0) + 1
	var heroes := get_heroes().size()
	return "team_size %d (= and -)    spawns %.0f m out    alive: red %d, blue %d, soldiers %d    heroes %d\ncentre source %s (C)    hero sources %s (H)    V: fly over the middle%s" % [
		team_size, spawn_distance, alive[1], alive[2], alive[0], heroes, "on" if is_centre_source_on() else "off", "on" if _hero_sources_on else "off",
		" (flying: U goes back to your pawn)" if GameMode.possession_coordinator and GameMode.possession_coordinator.is_spectating() else ""]


func _keys_text() -> String:
	return super() + "\nMass battle: C centre source, H hero sources, V fly over the middle, = and - team size, F3 readouts (off). F1 diagnostics"
