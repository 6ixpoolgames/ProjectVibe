## Written by Claude (claude-opus-5-5), 2026-11-09: runs arena_sample.tscn, the t0 test level: you against goblins, to feel and tune
## the pawn, abilities, AI and fights by hand (pawn spec build order step 12, pulled forward at the owner's request).
## Press Offline to play alone. To play together, open it twice, press Host in one and Join in the other.
##
## Keys: WASD to move, Shift to sprint, Space to jump, Left Alt to dash, the left mouse button to swing, the mouse to look, the wheel
## to zoom. Esc frees the mouse, and a click takes it back. R fills the spawners up at once (Claude 2026-11-10: it sent a new wave of
## six on top of the others). Tab possesses a goblin (then it fights for
## you, on its team; Tab again goes back). F3 shows or hides the readout over each goblin, and the debug shapes.
## Claude 2026-11-16 (the owner's request): U lets go of the pawn you have, which its AI controller takes over, and you fly around as a
## spectator (FreeFlyCamera: WASD, Space up, Ctrl down (Claude 2026-11-16: was Q and E), the wheel zooms and the middle button resets it, Shift faster, Shift and the wheel for faster still); U again takes back the pawn you
## left. Tab while flying possesses a goblin.
## A player's own pawn has no AI behaviours here, so it stands where it was left. Let go of, it keeps the world loaded around it (on the
## server or offline), so the fight there carries on wherever you fly.
## Claude 2026-11-09: debug shapes (AbilityDebugDraw): each swing leaves its hit sphere for 2 s, and each dash a trail of
## capsules for 1 s, fading. The readout also shows each goblin's last ability. Goblins sprint and dash while chasing. Cooldowns
## are longer here than in the base (DEBUG_COOLDOWNS), so the switching is easy to see.
##
## What's in it:
##   - The same world as the pawn sample: terrain, streaming and nav.
##   - Goblins (arena_goblin.tscn): red pawns on team 1 with all six t0 behaviours (Wander, Look Toward, Investigate, Search, Chase,
##     Attack). They wander until they notice you, then chase and swing. Hit them back.
##   - A readout over each goblin, on the server or offline, where the AI runs: its state, its running behaviour, its Health, and
##     how aware of your pawn it is. This is sample code: the base has no debug readout yet (pawn spec open question 10).
##   - Death: a dead goblin is removed after 3 s. A dead player is revived where they fell after 3 s. Both are this sample's rules,
##     not the base's (pawn spec 8.7).
##     Claude 2026-11-10: now the base's spawning does both, from nodes in the scene's Spawning folder: three PawnSpawners keep two
##     goblins each alive, 22 m out and facing the middle, removing a body after 3 s and sending its replacement 5 s after the death;
##     and the PlayerStart SpawnPoint is where players appear, and come back 3 s after dying (GameMode.spawn_manager). The spawners
##     start switched off in the scene, and this script switches them on once a game starts, so nothing spawns behind the menu.
##
## Claude 2026-11-09, debug keys for watching the AI (offline only, since pausing a host would stall its clients): P pauses and
## plays on. Paused, → runs one tick and ← steps back through the last 10 s, view only (AIDebugTimeline): a ghost and a label for each
## goblin where it was, and a list of what happened (states, behaviours, targets, abilities, hits). Shift moves ten ticks at a time.
## Playing on carries on from the real present.
##
## A scripted start also works, after "--" on the command line: --offline, --host, --join=127.0.0.1, --ping=100, and (Claude
## 2026-11-09) --port=24900 for another port than PORT.
extends Node3D

const PORT := 24896
const PAWN_SCENE := preload("res://assets/scenes/pawn/pawn.tscn")
const GOBLIN_SCENE := preload("res://assets/scenes/samples/arena_goblin.tscn")
## Claude 2026-11-16 (the owner's call): this game mode's default AI brain: the goblins' behaviours, for any pawn without its own (the
## players' pawns, whose AI takes over when they let go with U).
const ARENA_BRAIN := preload("res://assets/scenes/samples/arena_brain.tscn")
# Claude 2026-11-10: GOBLINS_PER_WAVE, BODY_REMOVAL_SECONDS and PLAYER_REVIVE_SECONDS are gone: the spawners and SpawnManager
# have those settings now.
## Claude 2026-11-09: longer cooldowns in this level only, in seconds by ability name, so switching between abilities is easy to see
## (the owner's request). The base's are MeleeAttack 0, Jump 0, Dash 1 and Sprint 4. Knockback and Death are left alone: a cooldown
## on Death would make a revived pawn unkillable for a while, and one on Knockback would let a second hit go unstaggered.
## Claude 2026-11-10: MeleeAttack 1.5 → 0.8, the owner's call that it was a little long. Claude 2026-11-10: the faction arena leaves
## MeleeAttack's out, so its combo is decided by boosts alone (FactionArenaSample._debug_cooldowns).
## Claude 2026-11-10: Dash 3 → 6, doubled with the base's (1 → 2), the owner's call that it's too good.
const DEBUG_COOLDOWNS := {"MeleeAttack": 0.8, "Jump": 1.0, "Dash": 6.0, "Sprint": 8.0}
## Claude 2026-11-09: the players' team. Every other team is AI (faction_arena_sample has two).
const PLAYER_TEAM := 0

@onready var _status: Label = $Display/Status
@onready var _menu: Control = $Display/Menu
@onready var _address: LineEdit = $Display/Menu/Box/Address

var _show_readouts := true
var _kills := 0
var _deaths := 0
var _readouts := {} # Pawn -> Label3D
## Claude 2026-11-12: the key action for kill_self, the owner's request: a way out when stuck in the ground. The project has none, so
## this sample adds one, on K.
const KILL_SELF_KEY_ACTION := &"pawn_kill_self"

var _kill_self_key_bound := false # Claude 2026-11-12
var _player_readouts := {} # Claude 2026-11-10: Pawn -> Label3D over each player's pawn: last ability, effects, Health (pawn spec 8.11)
var _player_pawn: Pawn = null # the pawn this machine's player started with, to go back to after Tab
var _last_ability := {} # Claude 2026-11-09: Pawn -> the AbilityBase it last started, for the readout
var _debug_draw: AbilityDebugDraw = null # Claude 2026-11-09: swing spheres and dash trails
var _port := PORT # Claude 2026-11-09: --port= changes it, so a scripted check doesn't land in a game already hosting on PORT
var _timeline: AIDebugTimeline = null # Claude 2026-11-09: the view-only rewind, for P and the arrow keys
var _paused_note := "" # Claude 2026-11-09: why P did nothing, shown in the status lines
var _left_pawn: Pawn = null # Claude 2026-11-16: the pawn U let go of, which U takes back
var _released_connected := false # Claude 2026-11-16
var _options: MatchOptionsPanel = null # Claude 2026-11-16: the start menu's match options
var _defaults_before: PawnDefaultsRes = null # Claude 2026-11-16: the game's pawn defaults before this level put its own copy in
var _dedicated := false # Claude 2026-11-17: hosting as a dedicated server (the menu's Dedicated server, or --dedicated)
var _connected_players := 0 # Claude 2026-11-17: clients connected, for a dedicated server's status line


func _ready() -> void:
	_use_level_defaults() # Claude 2026-11-16: first, before any pawn is made
	_debug_draw = AbilityDebugDraw.new() # Claude 2026-11-09
	_debug_draw.name = "AbilityDebugDraw"
	add_child(_debug_draw)
	_timeline = AIDebugTimeline.new() # Claude 2026-11-09
	_timeline.name = "AIDebugTimeline"
	_timeline.describe = _readout_text
	add_child(_timeline)
	NetworkSession.world_root = $Entities
	NetworkSession.register_type("pawn", PAWN_SCENE)
	NetworkSession.register_type("goblin", GOBLIN_SCENE)
	NetworkSession.player_connected.connect(_on_player_connected)
	NetworkSession.player_connected.connect(func(peer: int) -> void: _connected_players += 1 if peer != NetworkSession.get_local_peer() else 0) # Claude 2026-11-17
	NetworkSession.player_left.connect(func(_peer: int) -> void: _connected_players = maxi(_connected_players - 1, 0))
	NetworkSession.entity_spawned.connect(_on_entity_spawned)
	NetworkSession.refused.connect(func(reason: String) -> void: _status.text = "Refused: %s" % reason)
	NetworkSession.disconnected.connect(func() -> void: _menu.show())
	# Claude 2026-11-15: replay recordings (docs/replay/REPLAY_SPEC.md), the owner's call: recording starts when the game does (Offline
	# or Host below; on a client once Join has connected) and stops when the session ends. Files go in user://replays/host and
	# user://replays/client; open them with assets/scenes/replay/replay_viewer.tscn.
	NetworkSession.joined.connect(func() -> void: _start_recording("client"))
	NetworkSession.disconnected.connect(_stop_recording)
	# Claude 2026-11-12: K kills your own pawn (the KillSelf ability), so a player stuck in the ground can respawn.
	if not InputMap.has_action(KILL_SELF_KEY_ACTION):
		InputMap.add_action(KILL_SELF_KEY_ACTION)
		var key := InputEventKey.new()
		key.physical_keycode = KEY_K
		InputMap.action_add_event(KILL_SELF_KEY_ACTION, key)
	$Display/Menu/Box/Offline.pressed.connect(_start_offline)
	$Display/Menu/Box/Host.pressed.connect(_host)
	_add_dedicated_button() # Claude 2026-11-17
	$Display/Menu/Box/Join.pressed.connect(func() -> void: _join(_address.text))
	_build_match_options() # Claude 2026-11-16
	NetworkSession.disconnected.connect(func() -> void: _options.refresh())
	# Claude 2026-11-13: deferred, so a scripted --host or --offline starts once the whole scene is ready, including the _ready of a
	# script that extends this one. FactionArenaSample registers its own pawn scenes after calling super(), so a --host read right
	# here spawned the host's player from the plain pawn.tscn: a capsule, without the faction arena's attacks (the owner spotted it).
	# GDScript note: call_deferred runs the function at the end of this frame, after every _ready has finished.
	_read_command_line.call_deferred()


func _process(_delta: float) -> void:
	_status.text = _status_text()
	_update_readouts()
	# Claude 2026-11-12: the player controller is made when it's first needed, so K is bound to kill_self once it exists.
	if not _kill_self_key_bound and GameMode.possession_coordinator and GameMode.possession_coordinator.controller:
		GameMode.possession_coordinator.controller.action_keys[&"kill_self"] = KILL_SELF_KEY_ACTION
		_kill_self_key_bound = true
	# Claude 2026-11-16: hears about pawns let go of, for U.
	if not _released_connected and GameMode.possession_coordinator:
		GameMode.possession_coordinator.released.connect(_on_pawn_released)
		_released_connected = true


func _unhandled_key_input(event: InputEvent) -> void:
	if not event.is_pressed() or event.is_echo():
		return
	var key := event as InputEventKey
	match key.physical_keycode:
		# Claude 2026-11-09: pause, step and the view-only rewind
		KEY_P:
			_toggle_pause()
		KEY_RIGHT:
			_step(10 if key.shift_pressed else 1)
		KEY_LEFT:
			_step(-10 if key.shift_pressed else -1)
		KEY_R:
			_spawn_wave()
		KEY_TAB:
			_swap_pawn()
		KEY_U:
			_toggle_spectating() # Claude 2026-11-16
		KEY_F3:
			_show_readouts = not _show_readouts
			_debug_draw.visible = _show_readouts # Claude 2026-11-09


# --- Starting ---


func _start_offline() -> void:
	_menu.hide()
	_start_recording("host") # Claude 2026-11-15: offline recordings go with the host's, since this machine decides the game
	# Claude 2026-11-10: at the PlayerStart, possessed, and brought back after dying, by SpawnManager.
	_player_pawn = GameMode.spawn_manager.spawn_player(0)
	_start_spawners()


## Claude 2026-11-17: dedicated: a server with no player of its own, as a game's dedicated server is; only clients' players get pawns
## (--dedicated on the command line).
func _host(dedicated: bool = false) -> void:
	var error := NetworkSession.host(_port) # Claude 2026-11-09: was PORT; --port= can change it
	if error != OK:
		_status.text = "Couldn't host: error %d" % error
		return
	_dedicated = dedicated
	if dedicated:
		_show_server_screen() # Claude 2026-11-17: the menu stays, as a server's screen
	else:
		_menu.hide()
	_start_recording("host") # Claude 2026-11-15
	if not dedicated:
		_on_player_connected(NetworkSession.get_local_peer())
	_start_spawners() # Claude 2026-11-10: was _spawn_wave()


## Claude 2026-11-17: the menu's "Dedicated server" button, under Host. Made here rather than in the scenes, so every arena sample
## gets it without editing each scene.
func _add_dedicated_button() -> void:
	var host_button: Button = $Display/Menu/Box/Host
	var button := Button.new()
	button.name = "Dedicated"
	button.text = "Dedicated server"
	button.tooltip_text = "Host with no player of your own, as a game's server would run. The world isn't drawn; status and keys still work."
	host_button.add_sibling(button) # GDScript note: add_sibling puts it right after Host in the menu
	button.pressed.connect(func() -> void: _host(true))


## Claude 2026-11-17: what a dedicated server shows in a window. The menu stays up with its buttons swapped for a short note, and the
## 3D world isn't drawn at all (Viewport.disable_3d): a server doesn't need to see it, and drawing would take time from the ticks.
## The status lines, the diagnostics keys (F1 and the rest) and this sample's keys (and the mass battle's C and H) work as usual.
func _show_server_screen() -> void:
	get_viewport().disable_3d = true
	var box: Container = $Display/Menu/Box
	for child in box.get_children():
		child.hide()
	var note := Label.new()
	note.name = "ServerNote"
	note.text = "Dedicated server, port %d
The world isn't drawn. The status is top left.
F1: diagnostics keys. The sample's keys still work." % _port
	note.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(note)
	_menu.show()


func _join(address: String) -> void:
	_menu.hide()
	NetworkSession.join(address if address != "" else "127.0.0.1", _port) # Claude 2026-11-09: was PORT


## Claude 2026-11-15: starts a replay recording, if this game has a recorder (GameMode.replay_recorder). role: "host" or "client".
func _start_recording(role: String) -> void:
	# Claude 2026-11-16: unless one is already running: diagnostics starts one too, on hosting and joining (always-on replays).
	if GameMode.replay_recorder and not GameMode.replay_recorder.is_recording():
		GameMode.replay_recorder.start_recording(role)


func _stop_recording() -> void:
	if GameMode.replay_recorder:
		GameMode.replay_recorder.stop_recording()


## Server: a player has arrived, so they get a pawn near the middle.
## Claude 2026-11-10: at the PlayerStart, through SpawnManager, which also possesses it for them and brings it back after dying.
func _on_player_connected(peer: int) -> void:
	var pawn := GameMode.spawn_manager.spawn_player(peer)
	if peer == NetworkSession.get_local_peer() or not NetworkSession.is_server():
		_player_pawn = pawn


## Claude 2026-11-10: every PawnSpawner in the Spawning folder. They're off in the scene, so nothing spawns behind the menu.
func get_spawners() -> Array[PawnSpawner]:
	var out: Array[PawnSpawner] = []
	for child in $Spawning.get_children():
		if child is PawnSpawner:
			out.append(child)
	return out


## Claude 2026-11-10: server or offline: switches the spawners on, which fills them up.
func _start_spawners() -> void:
	if NetworkSession.is_client():
		return
	for spawner in get_spawners():
		spawner.active = true


## R. Claude 2026-11-10: fills every spawner up at once, skipping the wait for replacements. It used to send a ring of six more.
func _spawn_wave() -> void:
	if NetworkSession.is_client():
		return
	for spawner in get_spawners():
		spawner.refill_now()


## Every machine: give each pawn its readout; the server also listens for deaths.
func _on_entity_spawned(entity: NetworkEntity) -> void:
	var pawn := entity.get_parent() as Pawn
	if pawn == null:
		return
	_debug_draw.watch(pawn) # Claude 2026-11-09
	_lengthen_cooldowns(pawn) # Claude 2026-11-09
	_scale_health(pawn) # Claude 2026-11-12
	# Claude 2026-11-09: remember what each pawn last started, for its readout. Walk never "starts": it's what runs when nothing else
	# does. Claude 2026-11-10: players' pawns too, for their own readout.
	if pawn.ability_manager:
		pawn.ability_manager.ability_started.connect(func(ability: AbilityBase) -> void: _last_ability[pawn] = ability)
	# Claude 2026-11-13: _is_npc, not team != PLAYER_TEAM, so the faction arena's NPCs on the players' team get an NPC's readout too.
	if _is_npc(pawn): # Claude 2026-11-09: was team 1; any AI team now
		if _records_timeline(): # Claude 2026-11-15
			_timeline.watch(pawn) # Claude 2026-11-09
		_readouts[pawn] = _make_readout(pawn)
		# Claude 2026-11-10: its readout goes the moment it leaves, since a spawner removes bodies now, not this script. A freed pawn
		# left in _readouts broke the loops over it, whose loop variable is typed Pawn.
		pawn.tree_exiting.connect(func() -> void:
			_readouts.erase(pawn)
			_last_ability.erase(pawn))
	else:
		# Claude 2026-11-10: a smaller readout over a player's pawn, so a player sees their own combo boosts (pawn spec 8.11). Kept
		# apart from _readouts, which Tab and the goblin counts read.
		var label := _make_readout(pawn)
		label.pixel_size = 0.004
		_player_readouts[pawn] = label
		pawn.tree_exiting.connect(func() -> void:
			_player_readouts.erase(pawn)
			_last_ability.erase(pawn))
	if not NetworkSession.is_client():
		if pawn.ability_manager: # Claude 2026-11-16 (pawn M3): died moved to the AbilityManager
			pawn.ability_manager.died.connect(_on_pawn_died)


# Claude 2026-11-10: a readout label over a pawn. Moved here from _on_entity_spawned, unchanged, so players' pawns get one too.
func _make_readout(pawn: Pawn) -> Label3D:
	var label := Label3D.new()
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.no_depth_test = true
	label.font_size = 48
	label.outline_size = 12
	label.pixel_size = 0.005 # Claude 2026-11-09: was 0.004; a little bigger, the owner's request
	label.position = Vector3(0.0, 2.4, 0.0)
	pawn.get_visual().add_child(label)
	return label


## Claude 2026-11-15: true if the AI debug timeline records this level's NPCs (← steps back through it). It writes each NPC's readout
## text every tick, which a level with hundreds of NPCs, such as the mass battle, can't afford, so that one says no.
func _records_timeline() -> bool:
	return true


## Claude 2026-11-13: true for a pawn the AI plays (it gets an NPC's readout, and Tab can possess it), false for a player's own pawn.
## Here every pawn not on the players' team; the faction arena also has NPCs on the players' team, and says so by scene.
func _is_npc(pawn: Pawn) -> bool:
	return pawn.team != PLAYER_TEAM


## Claude 2026-11-12: how many times its usual Health each pawn in this level has. 1 here; the faction arena uses more, so fights last
## long enough to watch how the AI groups up (the owner's request).
func _health_multiplier() -> float:
	return 1.0


## Claude 2026-11-12: every machine, for every pawn, before its first tick: multiplies its Health's base value by _health_multiplier()
## and fills it. Health's most is the same on every machine this way; how much it has now rolls back and comes in snapshots anyway.
func _scale_health(pawn: Pawn) -> void:
	var multiplier := _health_multiplier()
	var health := pawn.stat_manager.get_stat(StatManager.HEALTH) if pawn.stat_manager else null
	if health == null or is_equal_approx(multiplier, 1.0):
		return
	health.base_value *= multiplier # GDScript note: base_value's setter sets value too
	health.current = health.value


## Claude 2026-11-10: this level's cooldowns, DEBUG_COOLDOWNS. A sample that extends this one can return its own.
func _debug_cooldowns() -> Dictionary:
	return DEBUG_COOLDOWNS


## Claude 2026-11-09: every machine, for every pawn: sets DEBUG_COOLDOWNS. An ability that had no cooldown didn't list its cooldown
## timer for rollback, so it's added here. That's allowed until the pawn's first tick is recorded, which hasn't happened yet when a
## pawn is spawned, and every machine adds the same entries in the same order, so a client's prediction keeps matching the server.
func _lengthen_cooldowns(pawn: Pawn) -> void:
	if pawn.ability_manager == null:
		return
	var tick_state: TickStateComponent = null
	for child in pawn.get_children():
		if child is TickStateComponent:
			tick_state = child
	var new_entries: Array[String] = []
	for ability in pawn.ability_manager.get_abilities():
		var cooldowns := _debug_cooldowns() # Claude 2026-11-10: a function, so the faction arena can change the list
		if not cooldowns.has(String(ability.name)):
			continue
		if ability.cooldown <= 0.0:
			new_entries.append("%s:ready_at" % pawn.get_path_to(ability))
		ability.cooldown = cooldowns[String(ability.name)]
	if tick_state and not new_entries.is_empty():
		tick_state.add_state_properties(new_entries)


# --- Deaths (this sample's rules) ---


# Claude 2026-11-10: only counts now. Removing bodies and bringing players back moved to the spawners and SpawnManager, which count
# their delays in ticks, so pausing (P) pauses them too; the scene timers used here kept running while paused.
func _on_pawn_died(pawn: Pawn, _hit: HitInfo) -> void:
	if pawn.team != PLAYER_TEAM: # Claude 2026-11-09: was team 1
		_kills += 1
	else:
		_deaths += 1


# --- Keys ---


## Tab: possess a living goblin, or go back to your own pawn.
func _swap_pawn() -> void:
	var coordinator := GameMode.possession_coordinator
	var current := coordinator.get_pawn_of()
	# Claude 2026-11-13: _is_npc, so possessing an NPC on the players' team counts as possessing an NPC.
	if current != null and _is_npc(current) and is_instance_valid(_player_pawn): # Claude 2026-11-09: was team 1
		coordinator.possess(_player_pawn)
		return
	for pawn: Pawn in _readouts:
		if is_instance_valid(pawn) and not pawn.is_dead() and coordinator.get_peer_of(pawn) == 0:
			coordinator.possess(pawn)
			return


## Claude 2026-11-16: U: let go of the pawn you have (its AI controller takes over) and fly as a spectator, or, while flying, take back
## the pawn you left. On a client both are requests to the server; the view switches when it answers, or at once for letting go.
func _toggle_spectating() -> void:
	var coordinator := GameMode.possession_coordinator
	if coordinator == null or coordinator.controller == null:
		return
	if not coordinator.is_spectating():
		_start_spectating()
		return
	var back := _left_pawn if is_instance_valid(_left_pawn) else _player_pawn
	if is_instance_valid(back):
		coordinator.possess(back) # taking it stops the spectating; if it's refused (someone else has it), you keep flying


## Claude 2026-11-16: lets go of the pawn this machine's player has (remembered for U to take back) and flies the spectator. Returns
## the free-fly camera, or null with no player controller. The mass battle's V uses it too.
func _start_spectating() -> FreeFlyCamera:
	var coordinator := GameMode.possession_coordinator
	if coordinator == null or coordinator.controller == null:
		return null
	var current := coordinator.get_pawn_of()
	if current != null:
		_left_pawn = current
	coordinator.spectate() # lets go of the pawn and flies
	return coordinator.controller.get_spectator()


## Claude 2026-11-16: server or offline: a player's own pawn they let go of keeps the world loaded around it, so it isn't frozen once
## the spectator flies away (the arenas have no other streaming source). A goblin let go of goes back to how it was.
func _on_pawn_released(_peer: int, pawn: Pawn) -> void:
	if NetworkSession.is_client() or not is_instance_valid(pawn) or _is_npc(pawn):
		return
	pawn.streaming_source.keeps_world_loaded = true


# --- Display ---


func _update_readouts() -> void:
	for pawn: Pawn in _readouts.keys():
		var label: Label3D = _readouts[pawn]
		if not is_instance_valid(pawn) or not is_instance_valid(label):
			_readouts.erase(pawn)
			_last_ability.erase(pawn) # Claude 2026-11-09
			continue
		# Claude 2026-11-09: hidden while the timeline shows the past, whose ghosts carry the readouts of then.
		label.visible = _show_readouts and not _timeline.is_viewing_past()
		if not label.visible:
			continue
		label.text = _readout_text(pawn)
		label.modulate = Color(1.0, 0.45, 0.4) if pawn.ai_context and pawn.ai_context.current_state_name() == &"Combat" else Color(1.0, 0.95, 0.8)
	# Claude 2026-11-10: players' pawns: their last ability, their effects and their Health.
	for pawn: Pawn in _player_readouts.keys():
		var label: Label3D = _player_readouts[pawn]
		if not is_instance_valid(pawn) or not is_instance_valid(label):
			_player_readouts.erase(pawn)
			continue
		label.visible = _show_readouts and not _timeline.is_viewing_past()
		if label.visible:
			label.text = _player_readout_text(pawn)
			label.modulate = Color(0.75, 0.9, 1.0)


## Claude 2026-11-09: one goblin's readout, which the timeline also records each tick: its state and behaviour, its target and how
## aware of it it is, the last ability it started, and its Health. Claude 2026-11-10: and the effects on it.
func _readout_text(pawn: Pawn) -> String:
	var lines := PackedStringArray()
	if pawn.is_dead():
		lines.append("dead")
	elif pawn.runs_ai_here() and pawn.ai_context:
		var running := pawn.ai_context.behaviour_manager.get_running_behaviour() if pawn.ai_context.behaviour_manager else null
		lines.append("%s · %s" % [pawn.ai_context.current_state_name(), String(running.name) if running else "—"]) # Claude 2026-11-12: String(), so both sides are text
		# Claude 2026-11-12: has_target() first: casting a target that was freed (a body removed) is a script error.
		var target := pawn.ai_context.current_target as Pawn if pawn.ai_context.has_target() else null
		if not is_instance_valid(target):
			target = _player_pawn if is_instance_valid(_player_pawn) else null
		if target and pawn.ai_context.memory:
			var index := pawn.ai_context.memory.find(target)
			if index >= 0:
				var awareness := pawn.ai_context.memory.awareness_at(index, pawn.ai_context.current_tick)
				lines.append("%s: aware %d%%%s" % [target.name, int(awareness * 100.0), " (certain)" if pawn.ai_context.memory.is_certain_at(index) else ""])
		# Claude 2026-11-09: the last ability it started, marked while it's still running (Sprint lasts up to 3 s).
		var last: AbilityBase = _last_ability.get(pawn)
		if is_instance_valid(last):
			# Claude 2026-11-16 (pawn spec 8.20): with the steps running, for a stepped ability.
			var steps_now := last.get_running_step_names() if last.is_running_timed() else PackedStringArray()
			lines.append("last: %s%s%s" % [last.name, ": " + " + ".join(steps_now) if not steps_now.is_empty() else "", " (running)" if last.is_running_timed() else ""])
		else:
			lines.append("last: —")
	lines.append_array(_effect_lines(pawn)) # Claude 2026-11-10
	lines.append("HP %d" % int(pawn.stat_manager.get_health()))
	return "\n".join(lines)


## Claude 2026-11-10: a player's pawn's readout: the last ability it started, what's on it, and its Health.
func _player_readout_text(pawn: Pawn) -> String:
	var lines := PackedStringArray()
	var last: AbilityBase = _last_ability.get(pawn)
	lines.append("last: %s%s" % [last.name, " (running)" if last.is_running_timed() else ""] if is_instance_valid(last) else "last: —")
	lines.append_array(_effect_lines(pawn))
	lines.append("HP %d" % int(pawn.stat_manager.get_health()))
	return "\n".join(lines)


## Claude 2026-11-10 (pawn spec 8.11): a line per effect on the pawn: its name, the seconds it has left, and its stacks if more than
## one, such as "combo second boost 0.4 s". On a client these come from snapshots, or from its own prediction for its own pawn.
func _effect_lines(pawn: Pawn) -> PackedStringArray:
	var lines := PackedStringArray()
	if pawn.effect_manager == null:
		return lines
	var rate := float(TickDriver.get_tick_rate())
	for entry in pawn.effect_manager.get_active_effects():
		var effect: Effect = entry["effect"]
		var stacks: int = entry["stacks"]
		lines.append("+ %s %.1f s%s" % [effect.describe() if effect else "?", entry["ticks_left"] / rate, " x%d" % stacks if stacks > 1 else ""])
	return lines


# --- Pause, step and the view-only rewind (Claude 2026-11-09) ---


func _toggle_pause() -> void:
	if NetworkSession.is_server() or NetworkSession.is_client():
		_paused_note = "P pauses offline only: pausing a host would stall everyone joined to it"
		return
	TickDriver.active = not TickDriver.active
	_timeline.view_present()
	_timeline.show_panel(not TickDriver.active)
	_update_readouts() # at once, not on the next frame, so the live readouts and the ghosts change together


# Paused: back through the recording, or forward to the present and then on by real ticks.
func _step(ticks: int) -> void:
	if TickDriver.active:
		return
	var to_run := _timeline.step_view(ticks)
	for i in to_run:
		TickDriver.step()
	if to_run > 0:
		_timeline.view_present()
	_update_readouts() # at once, as above


func _status_text() -> String:
	var mode := "offline"
	if NetworkSession.is_server():
		# Claude 2026-11-17: and how many players are connected, which is what a dedicated server's screen is for
		mode = "dedicated server, %d player%s" % [_connected_players, "" if _connected_players == 1 else "s"] if _dedicated else "hosting"
	elif NetworkSession.is_client():
		mode = "client, ping %d ms" % int(NetworkSession.get_rtt_ms())
	var alive := 0
	for pawn: Pawn in _readouts:
		if is_instance_valid(pawn) and not pawn.is_dead():
			alive += 1
	var pawn := GameMode.possession_coordinator.get_pawn_of() if GameMode.possession_coordinator else null
	var lines := PackedStringArray()
	lines.append("%s    %d fps    %s" % [mode, Engine.get_frames_per_second(), _server_tick_text()]) # Claude 2026-11-16: and the server's tick rate
	# Claude 2026-11-15: the replay recording, if one is running
	var recorder: ReplayRecorder = GameMode.replay_recorder
	if recorder and recorder.is_recording():
		lines.append("recording %s (%.1f MB)" % [recorder.get_recording_path().get_file(), recorder.get_bytes_written() / 1048576.0])
	if pawn:
		lines.append("HP %d%s    speed %.1f m/s" % [int(pawn.stat_manager.get_health()), "  (dead: reviving)" if pawn.is_dead() else "", Vector2(pawn.velocity.x, pawn.velocity.z).length()])
	lines.append("goblins %d    kills %d    deaths %d" % [alive, _kills, _deaths])
	lines.append(_keys_text()) # Claude 2026-11-09: a function, so faction_arena_sample can add its special attack
	if not TickDriver.active:
		lines.append("PAUSED (P)")
	if _paused_note != "":
		lines.append(_paused_note)
	return "\n".join(lines)


## Claude 2026-11-16 (the owner's call: the default AI brain is the game mode's): while this level runs, the game's pawn defaults are a copy
## of its own, with this level's brain (_ai_brain()), and the old ones go back when it closes. A level that extends this one changes
## its copy too (the mass battle's load distance). GDScript note: duplicate() makes a new resource with the same settings, so changing
## it leaves the game's file as it was.
func _use_level_defaults() -> void:
	var initializer: PawnInitializer = GameMode.pawn_initializer
	if initializer == null or initializer.defaults == null:
		return
	_defaults_before = initializer.defaults
	initializer.defaults = _defaults_before.duplicate()
	initializer.defaults.ai_brain = _ai_brain()


## Claude 2026-11-16 (audit): this level's copy of the game's pawn defaults, or null if it couldn't make one (no PawnInitializer). An
## arena sample that extends this one changes its own settings on it (the mass battle's load distance).
func _level_defaults() -> PawnDefaultsRes:
	if _defaults_before == null or GameMode.pawn_initializer == null:
		return null
	return GameMode.pawn_initializer.defaults


## Claude 2026-11-16: this game mode's default AI brain, for pawns without their own. The faction arena and mass battle change it.
func _ai_brain() -> PackedScene:
	return ARENA_BRAIN


func _exit_tree() -> void:
	# Claude 2026-11-16: the game's own pawn defaults back (see _use_level_defaults).
	if _defaults_before and GameMode.pawn_initializer:
		GameMode.pawn_initializer.defaults = _defaults_before


## Claude 2026-11-16 (the owner's request): the start menu's match options. A "Match options" button under Join shows or hides a panel
## (MatchOptionsPanel) of settings, each set on its object as it's changed, so they take effect when Offline or Host starts the
## game. Three kinds of section:
##   - this level's own, from _level_match_options() (each arena sample adds its own: team size, spawn distance and so on)
##   - every GameMode module that names some (GameModeModule.get_match_options): nothing here names a module, so a game with
##     different modules gets different options
##   - every autoload that names some (the tick driver's load ladder, the network session's snapshots): Claude 2026-11-16, they name
##     their own now (MatchOptionsPanel.add_from_autoloads), so this sample lists nobody's settings but its own
## They're the host's settings: a client joining a game plays by the server's.
func _build_match_options() -> void:
	var box: VBoxContainer = $Display/Menu/Box
	var toggle := Button.new()
	toggle.text = "Match options"
	toggle.toggle_mode = true
	box.add_child(toggle)
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(420, 320)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.visible = false
	box.add_child(scroll)
	_options = MatchOptionsPanel.new()
	_options.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_options)
	_options.add_section("This level (host and offline)", self, _level_match_options())
	_options.add_from_game_mode()
	_options.add_from_autoloads()
	toggle.toggled.connect(func(on: bool) -> void:
		scroll.visible = on
		if on:
			_options.refresh())


## Claude 2026-11-16: this level's settings for the start menu. None here; the arena samples that extend this add theirs.
func _level_match_options() -> PackedStringArray:
	return PackedStringArray()


## Claude 2026-11-16 (the owner's request: the server tick rate in the HUD; then: hooked up to diagnostics): "server 60 ticks/s, running
## 59.8, load 63%, step 1", from DiagnosticsManager.get_server_ticks(), which measures it for the session log and F4 too: offline and
## hosting it's this machine's own tick, on a client the server's, from its snapshots. A sample may name DiagnosticsManager (samples,
## like debug tools, aren't shipped); without that module, just the rate it's set to.
func _server_tick_text() -> String:
	var diagnostics := GameMode.get_module(DiagnosticsManager) as DiagnosticsManager
	if diagnostics == null:
		return "server %d ticks/s" % TickDriver.get_tick_rate()
	return DiagnosticsManager.server_text(diagnostics.get_server_ticks(1.0))


## Claude 2026-11-09: the key reminder in the status lines. Claude 2026-11-16: flying up and down is Space and Ctrl now.
func _keys_text() -> String:
	return "WASD, Shift sprint, Space jump, Alt dash, left mouse swing    R: refill the spawners    Tab: possess a goblin    U: let go and fly (Space/Ctrl up/down, wheel zoom, middle button unzoom, Shift+wheel speed)    F3: readouts and debug shapes    P: pause, then ←/→ step    K: respawn (if stuck)    Esc: free the mouse"


func _read_command_line() -> void:
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--port="): # Claude 2026-11-09: read before --host and --join, in this first loop
			_port = int(argument.trim_prefix("--port="))
		if argument.begins_with("--ping="):
			var bench := NetTestBench.new()
			add_child(bench)
			bench.set_ping(float(argument.trim_prefix("--ping=")))
	for argument in OS.get_cmdline_user_args():
		if argument == "--offline":
			_start_offline()
		elif argument == "--host":
			_host()
		elif argument == "--dedicated": # Claude 2026-11-17: a server with no player of its own
			_host(true)
		elif argument.begins_with("--join="):
			_join(argument.trim_prefix("--join="))
