## Written by Claude (claude-opus-5-5), 2026-11-15: runs mass_battle_sample.tscn, the owner's large test: three factions of team_size
## (50 by default, up to 100 or more) march from spawners far apart to a meeting point in the middle and fight there. For seeing how
## close a big fight gets to the edge of what a tick can hold, with chunk streaming, freezing and unfreezing AI, and everything else
## going on at once. It's the faction arena (FactionArenaSample.gd, which this extends) made big:
##
## The level (mass_battle_sample.tscn):
##   - Smaller chunks than the other samples (64 m, not 128), and every source loads ground 160 m around it (not 320), so a spread-out
##     level fits in a test. Load distances are on each StreamingSource node, and load_distance below for players and heroes.
##   - Three faction spawners, 300 m from the middle and 120 degrees apart: red goblins, blue goblins, and the players' soldiers. Each
##     has a StreamingSource child, so the ground around it is always loaded, wherever the players are. Each faction's hero has its
##     own spawner beside it, which brings it back 30 s after it dies.
##   - A RallyPoint in the middle (the rally_point group). Every AI pawn has AIGoToPointBehaviour, so an idle one marches there; it
##     fights whatever it meets on the way, and mills about once it's there.
##   - A CentreSource in the middle, a StreamingSource the C key switches on and off. With it on, the spawners' ground (160 m in from
##     300 m out) meets the middle's (160 m out), so the whole way is loaded. With it off there's a gap in the middle, and the AI
##     switch-off (AIActivationManager) freezes every AI pawn there, unless a hero or a player is near enough to keep the ground loaded.
##   - Heroes (hero_red.tscn, hero_blue.tscn, hero_ally.tscn): a bigger figure on a 1.5 times bigger capsule, 1000 Health, 15% slower,
##     hitting 1.5 times as hard with a little more reach, and a chunk source of its own (ai_loads_chunks). H switches every hero's
##     source on and off, apart from the centre's.
##   - The player starts at the players' spawner, 285 m from the middle, so they can watch the march or walk in.
##
## Keys, besides the faction arena's: C the centre's source, H the heroes' sources, V an overhead view of the middle (the camera
## only: your pawn stays where it is), F4 the performance overlay (PerformanceOverlay), = and - team_size up or down by 10 (the
## spawners top up to it; lowering it removes nobody, those that die just aren't replaced). F3 still shows the readouts and debug
## shapes, which are off to begin with: hundreds of floating labels cost more than the AI. The AI debug timeline (← to step back)
## isn't recorded here, for the same reason; P still pauses.
extends "res://assets/scripts/samples/FactionArenaSample.gd"

const HERO_RED_SCENE := preload("res://assets/scenes/samples/hero_red.tscn")
const HERO_BLUE_SCENE := preload("res://assets/scenes/samples/hero_blue.tscn")
const HERO_ALLY_SCENE := preload("res://assets/scenes/samples/hero_ally.tscn")

## How far players' pawns keep ground loaded here, in metres, the same as the level's other sources. Set as a player's pawn spawns.
@export_range(0.0, 2000.0, 1.0, "or_greater") var load_distance := 160.0

var _overlay: PerformanceOverlay = null
var _heroes: Array[Pawn] = []
var _hero_sources_on := true
var _overhead := false
var _camera_before: Camera3D = null


func _ready() -> void:
	super()
	NetworkSession.register_type("hero_red", HERO_RED_SCENE)
	NetworkSession.register_type("hero_blue", HERO_BLUE_SCENE)
	NetworkSession.register_type("hero_ally", HERO_ALLY_SCENE)
	# Off to begin with: with hundreds of pawns, the readouts and shapes cost more than what they show. F3 brings them back.
	_show_readouts = false
	_debug_draw.visible = false
	_overlay = PerformanceOverlay.new()
	_overlay.name = "PerformanceOverlay"
	_overlay.streamer = $World/ChunkStreamer
	_overlay.extra_text = _overlay_lines
	$Display.add_child(_overlay)


func _records_timeline() -> bool:
	return false


func _on_entity_spawned(entity: NetworkEntity) -> void:
	super(entity)
	var pawn := entity.get_parent() as Pawn
	if pawn == null:
		return
	if pawn.scene_file_path == FACTION_PLAYER_SCENE.resource_path:
		# Before it's possessed, which is when it makes its StreamingSource (Pawn._refresh_source).
		pawn.streaming_load_distance = load_distance
	elif _is_hero(pawn):
		_heroes.append(pawn)
		if not _hero_sources_on:
			pawn.ai_loads_chunks = false


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
				_toggle_overhead()
				return
			KEY_F4:
				_overlay.visible = not _overlay.visible
				return
			KEY_EQUAL:
				_change_team_size(10)
				return
			KEY_MINUS:
				_change_team_size(-10)
				return
	super(event)


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
		hero.ai_loads_chunks = on


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


# V: the waiting camera, high above the middle, and back to whatever camera was showing. Only the view moves: nothing loads ground there.
func _toggle_overhead() -> void:
	var camera: Camera3D = $WaitingCamera
	_overhead = not _overhead
	if _overhead:
		_camera_before = get_viewport().get_camera_3d()
		camera.make_current()
	elif is_instance_valid(_camera_before):
		_camera_before.make_current()


# The overlay's extra lines: each faction's living pawns, the switches, and the team size.
func _overlay_lines() -> String:
	var alive := {0: 0, 1: 0, 2: 0}
	for pawn: Pawn in _readouts:
		if is_instance_valid(pawn) and not pawn.is_dead():
			alive[pawn.team] = alive.get(pawn.team, 0) + 1
	var heroes := get_heroes().size()
	return "team_size %d (= and -)    alive: red %d, blue %d, soldiers %d    heroes %d\ncentre source %s (C)    hero sources %s (H)    overhead view %s (V)" % [
		team_size, alive[1], alive[2], alive[0], heroes, "on" if is_centre_source_on() else "off", "on" if _hero_sources_on else "off", "on" if _overhead else "off"]


func _keys_text() -> String:
	return super() + "\nMass battle: C centre source, H hero sources, V view the middle, F4 performance, = and - team size, F3 readouts (off)"
