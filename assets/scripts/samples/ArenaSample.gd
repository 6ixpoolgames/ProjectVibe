## Written by Claude (claude-opus-5-5), 2026-11-09: runs arena_sample.tscn, the t0 test level: you against goblins, to feel and tune
## the pawn, abilities, AI and fights by hand (pawn spec build order step 12, pulled forward at the owner's request).
## Press Offline to play alone. To play together, open it twice, press Host in one and Join in the other.
##
## Keys: WASD to move, Shift to sprint, Space to jump, Left Alt to dash, the left mouse button to swing, the mouse to look, the wheel
## to zoom. Esc frees the mouse, and a click takes it back. R fills the spawners up at once (Claude 2026-11-10: it sent a new wave of
## six on top of the others). Tab possesses a goblin (then it fights for
## you, on its team; Tab again goes back). F3 shows or hides the readout over each goblin, and the debug shapes.
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
var _player_readouts := {} # Claude 2026-11-10: Pawn -> Label3D over each player's pawn: last ability, effects, Health (pawn spec 8.11)
var _player_pawn: Pawn = null # the pawn this machine's player started with, to go back to after Tab
var _last_ability := {} # Claude 2026-11-09: Pawn -> the AbilityBase it last started, for the readout
var _debug_draw: AbilityDebugDraw = null # Claude 2026-11-09: swing spheres and dash trails
var _port := PORT # Claude 2026-11-09: --port= changes it, so a scripted check doesn't land in a game already hosting on PORT
var _timeline: AIDebugTimeline = null # Claude 2026-11-09: the view-only rewind, for P and the arrow keys
var _paused_note := "" # Claude 2026-11-09: why P did nothing, shown in the status lines


func _ready() -> void:
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
	NetworkSession.entity_spawned.connect(_on_entity_spawned)
	NetworkSession.refused.connect(func(reason: String) -> void: _status.text = "Refused: %s" % reason)
	NetworkSession.disconnected.connect(func() -> void: _menu.show())
	$Display/Menu/Box/Offline.pressed.connect(_start_offline)
	$Display/Menu/Box/Host.pressed.connect(_host)
	$Display/Menu/Box/Join.pressed.connect(func() -> void: _join(_address.text))
	_read_command_line()


func _process(_delta: float) -> void:
	_status.text = _status_text()
	_update_readouts()


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
		KEY_F3:
			_show_readouts = not _show_readouts
			_debug_draw.visible = _show_readouts # Claude 2026-11-09


# --- Starting ---


func _start_offline() -> void:
	_menu.hide()
	# Claude 2026-11-10: at the PlayerStart, possessed, and brought back after dying, by SpawnManager.
	_player_pawn = GameMode.spawn_manager.spawn_player(0)
	_start_spawners()


func _host() -> void:
	var error := NetworkSession.host(_port) # Claude 2026-11-09: was PORT; --port= can change it
	if error != OK:
		_status.text = "Couldn't host: error %d" % error
		return
	_menu.hide()
	_on_player_connected(NetworkSession.get_local_peer())
	_start_spawners() # Claude 2026-11-10: was _spawn_wave()


func _join(address: String) -> void:
	_menu.hide()
	NetworkSession.join(address if address != "" else "127.0.0.1", _port) # Claude 2026-11-09: was PORT


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
	# Claude 2026-11-09: remember what each pawn last started, for its readout. Walk never "starts": it's what runs when nothing else
	# does. Claude 2026-11-10: players' pawns too, for their own readout.
	if pawn.ability_manager:
		pawn.ability_manager.ability_started.connect(func(ability: AbilityBase) -> void: _last_ability[pawn] = ability)
	if pawn.team != PLAYER_TEAM: # Claude 2026-11-09: was team 1; any AI team now
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
		pawn.died.connect(_on_pawn_died)


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
			new_entries.append("%s:cooldown_ticks_left" % pawn.get_path_to(ability))
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
	if current != null and current.team != PLAYER_TEAM and is_instance_valid(_player_pawn): # Claude 2026-11-09: was team 1
		coordinator.possess(_player_pawn)
		return
	for pawn: Pawn in _readouts:
		if is_instance_valid(pawn) and not pawn.is_dead() and coordinator.get_peer_of(pawn) == 0:
			coordinator.possess(pawn)
			return


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
		var running := pawn.ai_behaviour_manager.get_running_behaviour() if pawn.ai_behaviour_manager else null
		lines.append("%s · %s" % [pawn.ai_context.current_state_name(), running.name if running else "—"])
		var target := pawn.ai_context.current_target as Pawn
		if not is_instance_valid(target):
			target = _player_pawn if is_instance_valid(_player_pawn) else null
		if target and pawn.ai_memory:
			var index := pawn.ai_memory.find(target)
			if index >= 0:
				var awareness := pawn.ai_memory.awareness_at(index, pawn.ai_context.current_tick)
				lines.append("%s: aware %d%%%s" % [target.name, int(awareness * 100.0), " (certain)" if pawn.ai_memory.is_certain_at(index) else ""])
		# Claude 2026-11-09: the last ability it started, marked while it's still running (Sprint lasts up to 3 s).
		var last: AbilityBase = _last_ability.get(pawn)
		if is_instance_valid(last):
			lines.append("last: %s%s" % [last.name, " (running)" if last.is_running_timed() else ""])
		else:
			lines.append("last: —")
	lines.append_array(_effect_lines(pawn)) # Claude 2026-11-10
	lines.append("HP %d" % int(pawn.get_health()))
	return "\n".join(lines)


## Claude 2026-11-10: a player's pawn's readout: the last ability it started, what's on it, and its Health.
func _player_readout_text(pawn: Pawn) -> String:
	var lines := PackedStringArray()
	var last: AbilityBase = _last_ability.get(pawn)
	lines.append("last: %s%s" % [last.name, " (running)" if last.is_running_timed() else ""] if is_instance_valid(last) else "last: —")
	lines.append_array(_effect_lines(pawn))
	lines.append("HP %d" % int(pawn.get_health()))
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
		mode = "hosting"
	elif NetworkSession.is_client():
		mode = "client, ping %d ms" % int(NetworkSession.get_rtt_ms())
	var alive := 0
	for pawn: Pawn in _readouts:
		if is_instance_valid(pawn) and not pawn.is_dead():
			alive += 1
	var pawn := GameMode.possession_coordinator.get_pawn_of() if GameMode.possession_coordinator else null
	var lines := PackedStringArray()
	lines.append("%s    %d fps" % [mode, Engine.get_frames_per_second()])
	if pawn:
		lines.append("HP %d%s    speed %.1f m/s" % [int(pawn.get_health()), "  (dead: reviving)" if pawn.is_dead() else "", Vector2(pawn.velocity.x, pawn.velocity.z).length()])
	lines.append("goblins %d    kills %d    deaths %d" % [alive, _kills, _deaths])
	lines.append(_keys_text()) # Claude 2026-11-09: a function, so faction_arena_sample can add its special attack
	if not TickDriver.active:
		lines.append("PAUSED (P)")
	if _paused_note != "":
		lines.append(_paused_note)
	return "\n".join(lines)


## Claude 2026-11-09: the key reminder in the status lines.
func _keys_text() -> String:
	return "WASD, Shift sprint, Space jump, Alt dash, left mouse swing    R: refill the spawners    Tab: possess a goblin    F3: readouts and debug shapes    P: pause, then ←/→ step    Esc: free the mouse"


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
		elif argument.begins_with("--join="):
			_join(argument.trim_prefix("--join="))
