## Written by Claude (claude-opus-5-5), 2026-11-22: one run of the determinism check (the owner's request), a test bed. It plays the
## mass battle offline for a number of ticks and, after every tick's commit, writes a fingerprint of the state store: the frame's
## checksum and one hash per entity's row. Two runs from the same start should write the same file; tools/determinism/
## run_determinism_check.py runs it twice, compares, and on a difference runs it twice more with a dump of the rows around the first
## differing tick, to name the entity and the column that went apart.
##
## Run from the project folder (the driver does this for you):
##   godot --headless --fixed-fps 60 --path . "res://assets/scripts/samples/tests/determinism_check.tscn" -- --out=run1.bin
## Arguments: --size=N (each faction's soldiers, default 20), --ticks=N (default 1200), --out=PATH (the fingerprints),
## --dump=PATH with --dump-from=T and --dump-to=T (every row of those ticks, as text), --ladder (leave the load ladder working: it
## follows how loaded the machine is, so it's off by default and every AI pawn runs every tick), --workers=N (the job scheduler's
## worker threads; 0 runs every job on the main thread, to tell a threading difference from another).
##
## The fingerprint file, per tick: tick (int64), frame checksum (int64), entity count (int32), then per entity, in handle order:
## handle (int64) and row hash (int64); then column count (int32) and one hash per column (int64): first the tick's landings
## (LandingLog: chunks and nav tiles), then each layout column across every entity, layout by layout. Beside it, PATH.names: each layout's column names, and each entity's node path the first time it's seen, so the
## driver can name what differs without running again.
extends Node

var _size := 20
var _ticks := 1200
var _out_path := ""
var _dump_path := ""
var _dump_from := -1
var _dump_to := -1
var _ladder := false
var _workers := -2 # -2: leave the machine's setting
var _out: FileAccess = null
var _names: FileAccess = null
var _labelled := {} # handles already named in the .names file
var _layouts_named := 0
var _dump: FileAccess = null
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
			"dump":
				_dump_path = value
			"dump-from":
				_dump_from = int(value)
			"dump-to":
				_dump_to = int(value)
			"ladder":
				_ladder = true
			"workers":
				_workers = int(value)
	if _out_path == "":
		push_error("determinism_check: give --out=PATH")
		get_tree().quit(2)
		return
	_out = FileAccess.open(_out_path, FileAccess.WRITE)
	_names = FileAccess.open(_out_path + ".names", FileAccess.WRITE)
	if _dump_path != "":
		_dump = FileAccess.open(_dump_path, FileAccess.WRITE)
	LandingLog.clear()
	if _workers > -2:
		TickJobs.set_worker_count(_workers)
	if not _ladder:
		TickDriver.load_step_override = 1 # every AI pawn every tick: the ladder follows the machine's load
	if GameMode.replay_recorder:
		GameMode.replay_recorder.enabled = false # nothing to save; it doesn't change play either way
	var arena: Node = load("res://assets/scenes/samples/mass_battle_sample.tscn").instantiate()
	arena.team_size = _size
	add_child(arena)
	await get_tree().physics_frame
	TickDriver.after_tick.connect(_on_after_tick)
	arena._start_offline()
	print("--- Determinism check: team size %d, %d ticks, load ladder %s ---" % [_size, _ticks, "on" if _ladder else "off"])


# After the commit: the frame's checksum and a hash of every entity's row, gathered a column at a time.
func _on_after_tick(_dt: float, tick: int) -> void:
	if _first_tick < 0:
		_first_tick = tick
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
		print("--- Wrote %d ticks (%d to %d) ---" % [_written, _first_tick, tick])
		get_tree().quit(0)
