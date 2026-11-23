## Written by Claude (claude-opus-5-5), 2026-11-22: one run of the determinism check (the owner's request), a test bed. It plays the
## mass battle offline for a number of ticks and, after every tick's commit, writes a fingerprint of the state store: the frame's
## checksum and one hash per entity's row. Two runs from the same start should write the same file; tools/determinism/
## run_determinism_check.py runs it twice, compares, and on a difference runs it twice more with a dump of the rows around the first
## differing tick, to name the entity and the column that went apart. Claude 2026-11-23: its --compare compares files from two
## machines, and the options in the second group below find where they part (state store spec 13.11).
##
## Run from the project folder (the driver does this for you):
##   godot --headless --fixed-fps 60 --path . "res://assets/scripts/samples/tests/determinism_check.tscn" -- --out=run1.bin
## Arguments:
##   --out=PATH               the fingerprints (required); every other file below is written beside it
##   --size=N                 each faction's soldiers (default 20)
##   --ticks=N                how many ticks to play (default 1200)
##   --terrain-seed=N         another floor: the terrain's noise_seed, so the check isn't tied to one map
##   --ladder                 leave the load ladder working (off by default: it follows how loaded the machine is)
##   --workers=N              the job scheduler's worker threads; 0 runs every job on the main thread
##   --dump=PATH --dump-from=T --dump-to=T   every row of those ticks, as text
## For finding where two machines part:
##   --trace=NAME --trace-from=T --trace-to=T   one pawn, unrounded, at each stage of those ticks (PATH.trace): position, velocity,
##                            its move input and path state, and every AI decision it makes
##   --nav-dump=T             at the end of tick T, every nav mesh triangle (PATH.nav), link and tile state (PATH.links), bit for bit
##   --paths-to=T             up to tick T, every pawn's path state with goals and corners as exact bits (PATH.paths), and the nav
##                            server's log of every queued path search (PATH.pathlog, NavServer.debug_log_path_steps)
## Playing from orders (Claude 2026-11-23, the owner's request: can clients run the crowds from orders alone? netcode spec 19.3):
##   --record-orders=FILE     every order the AI gives a pawn's controller (AIController.order_listener): its tick, the pawn, the order
##                            and its exact arguments, and whether it came during that pawn's own AI step
##   --replay-orders=FILE     the AI doesn't think: each pawn's AI step plays its recorded orders for that tick instead
##                            (AIContextComponent.order_source). Compare the two runs' fingerprints with run_determinism_check.py
##                            --compare: the same means orders alone rebuild the game
##
## The fingerprint file, per tick: tick (int64), frame checksum (int64), entity count (int32), then per entity, in handle order:
## handle (int64) and row hash (int64); then column count (int32) and one hash per column (int64): first the tick's landings
## (LandingLog: chunks and nav tiles), then each layout column across every entity, layout by layout. Beside it, PATH.names: each
## layout's column names, and each entity's node path the first time it's seen, so the driver can name what differs without running
## again.
extends Node

const WORLD := AABB(Vector3(-100000, -10000, -100000), Vector3(200000, 20000, 200000)) # the whole level, for the nav dump

var _size := 20
var _ticks := 1200
var _out_path := ""
var _terrain_seed := -1
var _ladder := false
var _workers := -2 # -2: leave the machine's setting
var _dump_path := ""
var _dump_from := -1
var _dump_to := -1
var _trace_name := ""
var _trace_from := -1
var _trace_to := -1
var _nav_dump_tick := -1
var _paths_to := -1
var _record_orders_path := ""
var _replay_orders_path := ""
var _orders_out: FileAccess = null
var _orders: Dictionary = {} # replaying: tick -> {pawn name -> [[order, args], ...]}
var _thinking: Node = null # recording: the pawn whose AI step is running, so an order from elsewhere is noticed
var _orders_recorded := 0
var _orders_outside := 0 # recorded orders given outside their pawn's own AI step
var _orders_played := 0
var _orders_skipped := 0 # replaying: orders given outside their pawn's AI step, which aren't played
var _pawn_names := {} # replaying: pawn name -> pawn, refreshed each tick, for orders that name a pawn (look_at_node)
var _pawn_names_tick := -1
var _out: FileAccess = null
var _names: FileAccess = null
var _dump: FileAccess = null
var _trace: FileAccess = null
var _paths: FileAccess = null
var _path_log: FileAccess = null
var _labelled := {} # handles already named in the .names file
var _layouts_named := 0
var _first_tick := -1
var _written := 0


func _ready() -> void:
	for argument in OS.get_cmdline_user_args():
		var parts := argument.trim_prefix("--").split("=", true, 1)
		var value: String = parts[1] if parts.size() > 1 else ""
		match parts[0]:
			"size":
				_size = int(value)
			"ticks":
				_ticks = int(value)
			"out":
				_out_path = value
			"terrain-seed":
				_terrain_seed = int(value)
			"ladder":
				_ladder = true
			"workers":
				_workers = int(value)
			"dump":
				_dump_path = value
			"dump-from":
				_dump_from = int(value)
			"dump-to":
				_dump_to = int(value)
			"trace":
				_trace_name = value
			"trace-from":
				_trace_from = int(value)
			"trace-to":
				_trace_to = int(value)
			"nav-dump":
				_nav_dump_tick = int(value)
			"paths-to":
				_paths_to = int(value)
			"record-orders":
				_record_orders_path = value
			"replay-orders":
				_replay_orders_path = value
	if _out_path == "":
		push_error("determinism_check: give --out=PATH")
		get_tree().quit(2)
		return
	_out = FileAccess.open(_out_path, FileAccess.WRITE)
	_names = FileAccess.open(_out_path + ".names", FileAccess.WRITE)
	if _dump_path != "":
		_dump = FileAccess.open(_dump_path, FileAccess.WRITE)
	if _paths_to >= 0:
		_paths = FileAccess.open(_out_path + ".paths", FileAccess.WRITE)
		if Engine.has_singleton(&"NavServer"):
			Engine.get_singleton(&"NavServer").debug_log_path_steps(true)
			_path_log = FileAccess.open(_out_path + ".pathlog", FileAccess.WRITE)
	if _record_orders_path != "":
		_start_recording_orders()
	elif _replay_orders_path != "":
		_start_replaying_orders()
	LandingLog.clear()
	if _workers > -2:
		TickJobs.set_worker_count(_workers)
	if not _ladder:
		TickDriver.load_step_override = 1 # every AI pawn every tick: the ladder follows the machine's load
	if GameMode.replay_recorder:
		GameMode.replay_recorder.enabled = false # nothing to save; it doesn't change play either way
	var arena: Node = load("res://assets/scenes/samples/mass_battle_sample.tscn").instantiate()
	arena.team_size = _size
	var terrain: Node = arena.get_node_or_null(^"World/Terrain")
	if terrain and _terrain_seed >= 0:
		terrain.noise_seed = _terrain_seed # read when the terrain is ready, so before the level enters the tree
	add_child(arena)
	await get_tree().physics_frame
	TickDriver.after_tick.connect(_on_after_tick)
	if _trace_name != "":
		_start_trace()
	arena._start_offline()
	print("--- Determinism check: team size %d, %d ticks, load ladder %s, terrain seed %s ---" % [_size, _ticks,
		"on" if _ladder else "off", terrain.noise_seed if terrain else "none"])


# These are static, so left on they'd outlive this scene: a listener that outlives it crashes Godot as it quits.
func _exit_tree() -> void:
	AIBehaviourManager.decision_listener = Callable()
	AIController.order_listener = Callable()
	AIContextComponent.order_source = Callable()
	if _path_log:
		Engine.get_singleton(&"NavServer").debug_log_path_steps(false)


# Recording: the AI thinks as usual, through an order source that notes whose step it is, and every order goes to the file. A pawn
# named in an order (look_at_node) is written as {"pawn": its name}, which is the same in every run.
func _start_recording_orders() -> void:
	_orders_out = FileAccess.open(_record_orders_path, FileAccess.WRITE)
	AIContextComponent.order_source = func(context: AIContextComponent, tick: int) -> void:
		_thinking = context.pawn
		context.think(tick)
		_thinking = null
	AIController.order_listener = func(controller: AIController, order: StringName, args: Array) -> void:
		var inside := controller.pawn == _thinking
		if not inside:
			_orders_outside += 1
		var plain: Array = args.map(func(arg: Variant) -> Variant: return {"pawn": String(arg.name)} if arg is Node else arg)
		_orders_out.store_var([TickDriver.tick, String(controller.pawn.name) if controller.pawn else "", order, plain, inside])
		_orders_recorded += 1


# Replaying: every recorded order, by tick and pawn, played in each pawn's AI step instead of its AI.
func _start_replaying_orders() -> void:
	var file := FileAccess.open(_replay_orders_path, FileAccess.READ)
	while file.get_position() < file.get_length():
		var entry: Array = file.get_var()
		var by_pawn: Dictionary = _orders.get_or_add(int(entry[0]), {})
		(by_pawn.get_or_add(String(entry[1]), []) as Array).append([entry[2], entry[3], entry[4]])
	AIContextComponent.order_source = func(context: AIContextComponent, tick: int) -> void:
		for order: Array in _orders.get(tick, {}).get(String(context.pawn.name), []):
			# Claude 2026-11-23: none are expected since a dead pawn's controller takes no orders (it was the AI tidying up mid-tick when
			# its pawn died). One given outside its pawn's AI step belongs to another moment of the tick, so it's left out and counted,
			# and the summary line says so.
			if not order[2]:
				_orders_skipped += 1
				continue
			var args: Array = (order[1] as Array).map(func(arg: Variant) -> Variant: return _pawn_named(arg["pawn"], tick) if arg is Dictionary else arg)
			context.controller.callv(order[0], args)
			_orders_played += 1


func _pawn_named(pawn_name: String, tick: int) -> Node:
	if _pawn_names_tick != tick:
		_pawn_names_tick = tick
		_pawn_names.clear()
		for pawn in get_tree().get_nodes_in_group(Pawn.GROUP):
			_pawn_names[String(pawn.name)] = pawn
	return _pawn_names.get(pawn_name)


func _start_trace() -> void:
	_trace = FileAccess.open(_out_path + ".trace", FileAccess.WRITE)
	TickDriver.before_tick.connect(func(_dt: float, tick: int) -> void: _trace_pawn(tick, "before_tick"))
	TickDriver.after_simulate.connect(func(_dt: float, tick: int) -> void: _trace_pawn(tick, "after_simulate"))
	TickDriver.after_tick.connect(func(_dt: float, tick: int) -> void: _trace_pawn(tick, "after_tick"))
	# Every AI decision the traced pawn makes, with what it was made from (the inputs it read), to tell a different decision from a
	# different move.
	AIBehaviourManager.decision_listener = func(record: AIDecisionRecord, _manager: AIBehaviourManager) -> void:
		if record.pawn_name == StringName(_trace_name) and record.tick >= _trace_from and record.tick <= _trace_to:
			_trace.store_line("%d\tdecision\t%s" % [record.tick, JSON.stringify(record.to_dict())])


# One line about the traced pawn, its values unrounded. After simulating, also the input it acted on and where its path stands.
func _trace_pawn(tick: int, stage: String) -> void:
	if tick < _trace_from or tick > _trace_to:
		return
	var pawn := find_child(_trace_name, true, false) as Node3D
	if pawn == null:
		return
	var p := pawn.global_position
	var v: Vector3 = pawn.get(&"velocity") if &"velocity" in pawn else Vector3.ZERO
	var line := "%d\t%s\tpos %.9f %.9f %.9f\tvel %.9f %.9f %.9f" % [tick, stage, p.x, p.y, p.z, v.x, v.y, v.z]
	var controllers: ControllerManager = pawn.get(&"controller_manager")
	if stage == "after_simulate" and controllers:
		var m := controllers.move_input
		line += "\tmove %.9f %.9f %.9f actions %d" % [m.x, m.y, m.z, controllers.held_actions]
	var navigation: NavigationManager = pawn.get(&"navigation_manager")
	if stage == "after_simulate" and navigation:
		line += "\tpath state %d request %d pending %d corners %d" % [navigation._state, navigation._path_request,
			navigation._pending_ticks, navigation._corners.size()]
		if navigation._corners.size() > 1:
			line += " first corner %s" % [navigation._corners[1]]
	_trace.store_line(line)
	_trace.flush()


# Every nav mesh triangle, link and tile state as the nav server has them now, as raw bytes, so two machines' nav meshes can be
# compared bit for bit.
func _dump_nav() -> void:
	if not Engine.has_singleton(&"NavServer"):
		return
	var nav: Object = Engine.get_singleton(&"NavServer")
	var triangles: PackedVector3Array = nav.get_debug_triangles(WORLD).vertices
	FileAccess.open(_out_path + ".nav", FileAccess.WRITE).store_buffer(triangles.to_byte_array())
	var links: Dictionary = nav.get_debug_links(WORLD)
	var link_file := FileAccess.open(_out_path + ".links", FileAccess.WRITE)
	link_file.store_buffer(var_to_bytes(links))
	link_file.store_buffer(var_to_bytes(nav.get_tile_states()))
	print("--- Nav dump: %d triangles, %d links ---" % [triangles.size() / 3, (links.get("link_ids", []) as Variant).size()])


# One line per pawn under way: its path state, queued search, ticks waited, and its goal and corners as exact bits (hex), so two
# machines can be compared to find the first search that answered differently. And the nav server's search log for the tick.
func _write_paths(tick: int) -> void:
	if _path_log:
		var nav: Object = Engine.get_singleton(&"NavServer")
		_path_log.store_buffer((nav.take_debug_path_log() as PackedInt64Array).to_byte_array())
		if tick == _paths_to:
			nav.debug_log_path_steps(false)
	for pawn in get_tree().get_nodes_in_group(Pawn.GROUP):
		var navigation: NavigationManager = pawn.navigation_manager
		if navigation == null or navigation._state == NavigationManager.PathState.NONE:
			continue
		_paths.store_line("%d\t%s\tstate %d request %d pending %d\tgoal %s\tcorners %s" % [tick, pawn.name, navigation._state,
			navigation._path_request, navigation._pending_ticks, var_to_bytes(navigation._goal).hex_encode(),
			var_to_bytes(navigation._corners).hex_encode()])


# After the commit: the frame's checksum and a hash of every entity's row, gathered a column at a time.
func _on_after_tick(_dt: float, tick: int) -> void:
	if _first_tick < 0:
		_first_tick = tick
	if tick == _nav_dump_tick:
		_dump_nav()
	if tick <= _paths_to:
		_write_paths(tick)
	var store: Object = TickDriver.store
	var rows := {} # handle -> its row's values
	var names := {} # layout -> its column names, for the dump
	var column_hashes := PackedInt64Array([LandingLog.hash_at(tick)])
	for layout in store.get_layout_count():
		var columns: PackedStringArray = store.get_layout_columns(layout)
		names[layout] = columns
		if layout >= _layouts_named:
			_names.store_line("layout\t%d\t%s" % [layout, "\t".join(columns)])
			_layouts_named = layout + 1
		for column in columns.size():
			var read: Dictionary = store.get_column(layout, column, tick)
			column_hashes.append(hash(read["values"]) ^ hash(read["handles"]))
			var handles: PackedInt64Array = read["handles"]
			for i in handles.size():
				if not rows.has(handles[i]):
					rows[handles[i]] = [layout]
				rows[handles[i]].append(read["values"][i])
	var handles: Array = rows.keys()
	handles.sort()
	_out.store_64(tick)
	_out.store_64(store.frame_checksum(tick))
	_out.store_32(handles.size())
	for handle: int in handles:
		_out.store_64(handle)
		_out.store_64(hash(rows[handle]))
		if not _labelled.has(handle):
			_labelled[handle] = true
			var named: Object = store.get_owner(handle)
			_names.store_line("entity\t%d\t%s" % [handle, str((named as Node).get_path()) if named is Node else str(named)])
	_out.store_32(column_hashes.size())
	for column_hash in column_hashes:
		_out.store_64(column_hash)
	if _dump and tick >= _dump_from and tick <= _dump_to:
		for handle: int in handles:
			var row: Array = rows[handle]
			var columns: PackedStringArray = names[row[0]]
			var owner: Object = store.get_owner(handle)
			var label := str((owner as Node).get_path()) if owner is Node else str(owner)
			for column in columns.size():
				var value = row[column + 1]
				_dump.store_line("%d\t%d\t%s\t%s\t%d\t%s" % [tick, handle, label, columns[column], hash(value), var_to_str(value).replace("\n", " ")])
	_written += 1
	if _written >= _ticks:
		_out.close()
		_names.close()
		if _dump:
			_dump.close()
		if _orders_out:
			_orders_out.close()
			print("--- Orders recorded: %d, of which %d outside their pawn's own AI step ---" % [_orders_recorded, _orders_outside])
		if _replay_orders_path != "":
			print("--- Orders played: %d; skipped, given outside their pawn's AI step: %d ---" % [_orders_played, _orders_skipped])
		print("--- Wrote %d ticks (%d to %d) ---" % [_written, _first_tick, tick])
		get_tree().quit(0)
