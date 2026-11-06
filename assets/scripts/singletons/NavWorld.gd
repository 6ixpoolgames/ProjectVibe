## Written by Claude (claude-opus-5-5), 2026-11-06: the nav singleton's GDScript layer (nav spec section 21.5).
## Autoload "NavWorld". It stores every nav marker, gives each a stable id, and answers searches like
## "the nearest point.cover within 20 m". It needs no C++ library, so it works even where nav itself doesn't.
##
## It also keeps the list of modules, tells them when markers change, and reports types nothing handles.
## It doesn't find paths (NavServer does) or decide what a pawn does (AI does).
##
## Written so its insides can move to C++ later without changing anything that calls it:
##   - Callers use only the public functions below, which take and return plain values.
##   - Searches return ids, not objects. get_marker(id) fetches the full data only when it's needed.
##   - What searches read sits in flat arrays ("rows"), not in one object per marker.
##   - A chunk registers its whole list in one call.
##   - Searches call no script code in their loops.
##   - Requests apply on the next tick, so nothing can rely on them being instant.
##   - Ids come from a hash written out here, because Godot's hash() could differ from a C++ version.
##
## How it stores things: every marker is one row, meaning the same index in each array below.
## So _positions[7], _masks[7] and _ids[7] all describe one marker. A removed marker's row is reused later.
##
## How search stays fast: the world is split into square cells, and a search only looks at nearby cells.
## Each cell keeps a linked list running through the rows. _cell_heads gives a cell's first row, and
## _next_in_cell gives the row after each one. That makes adding and removing a marker instant, and
## it keeps everything in flat arrays.
##
## What happens in odd cases (all checked in tests/nav_world_selftest.gd):
##   - A duplicate id, an undeclared tag or a null marker: refused, with one warning for the whole list.
##   - An unknown id: harmless. get_marker gives null, and set_enabled warns and does nothing.
##   - Releasing a chunk that isn't registered: nothing happens.
##   - A search in an empty world, or with an infinite distance: finds what's there and always finishes.
##   - A search with an undeclared or empty tag: finds nothing, and doesn't add the tag.
##
## Module rules are at the top of NavMarkerModule.gd, and checked in tests/nav_markers_selftest.gd.
##
## The debug report: if markers exist of a type no module announced, it warns once per type, after registrations
## have gone quiet for a couple of seconds. It warns again only if a new unclaimed type appears, or a type loses
## its last module. Debug builds only. A level with no AI will report NavPoint, which is fine: it's one true line.
## Turn it off with the project setting below, for a game that leaves a type unhandled on purpose.
extends Node

const REPORT_SETTING := "project_base/nav/report_unhandled_markers"

## How wide each search cell is, in metres. Too small makes wide searches visit many cells, and too large
## makes each cell hold many markers.
const CELL_SIZE := 32.0
## Means "no row", at the end of a linked list.
const NO_ROW := -1

# The FNV-1a hash's two standard numbers. The first is written as negative because it's too big for a signed
# 64-bit int, and this is the same pattern of bits. Tests check the result against the published values.
const FNV_OFFSET := -3750763034362895579
const FNV_PRIME := 1099511628211

# GDScript note: an enum gives names to numbers, so the queue below says Op.ADD instead of a bare 0.
enum Op { ADD, REMOVE, SET_ENABLED, ADD_MODULE }

## Whether the automatic report runs. Starts from the project setting.
var report_unhandled: bool = ProjectSettings.get_setting(REPORT_SETTING, true)
## How long registrations must stay quiet before the report runs, since a module may just not have arrived yet.
var report_quiet_seconds := 2.0

# --- The rows. One index = one marker. ---
var _ids := PackedInt64Array()             # the marker's id; 0 means this row is free
var _positions := PackedVector3Array()
var _masks := PackedInt64Array()           # NavTags.mask_of(tag), so a search is one AND
var _enabled := PackedByteArray()          # 1 = on, 0 = off
var _from_chunk := PackedByteArray()       # 1 = a chunk announced it, so its changes outlive the chunk
var _linked := PackedByteArray()           # 1 = applied and searchable; modules have been told about it
var _types := PackedInt32Array()           # index into _type_scripts
var _next_in_cell := PackedInt32Array()    # linked list: the next row in the same cell
var _previous_in_cell := PackedInt32Array() # linked list: the row before this one
# GDScript note: Array[NavMarker] is a typed array, so only NavMarkers (or null) can go in it.
var _markers: Array[NavMarker] = []        # the full data, for what searches don't read

var _free_rows := PackedInt32Array()       # rows ready to be reused
var _row_of_id := {}                       # marker id -> row
var _cell_heads := {}                      # cell (Vector2i) -> the first row in that cell
var _chunk_ids := {}                       # _chunk_key(terrain, chunk) -> PackedInt64Array of its ids
var _terrains := {}                        # terrain id -> NavTerrainSettings
var _kept_changes := {}                    # marker id -> enabled value, for chunk markers changed from how they started
var _queue: Array = []                     # requests waiting for the next tick, in the order they were made

# --- Types and modules ---
var _type_scripts: Array[Script] = []      # type index -> the marker's script, such as NavLink
var _type_of_script := {}                  # script -> type index
var _type_counts := PackedInt32Array()     # type index -> how many rows hold that type
var _modules: Array[NavMarkerModule] = []  # joined modules, in the order they joined
var _modules_waiting: Array[NavMarkerModule] = [] # entered the tree, joining on the next tick
var _announced_types := {}                 # module -> the Array[Script] it announced
var _modules_of_type: Array[Array] = []    # type index -> the modules that handle it

# --- The debug report ---
var _report_waiting := false               # something changed, so a report may be due
var _quiet_seconds := 0.0                  # how long since the last change
var _reported_types := {}                  # script -> true, for types already warned about
var _automatic_report_count := 0


func _ready() -> void:
	# GDScript note: signal.connect(function) means "call this function whenever the signal fires".
	NetworkTime.before_tick.connect(_on_before_tick)


# GDScript note: the leading underscore marks an argument this function has to accept but doesn't use.
func _on_before_tick(dt: float, _tick: int) -> void:
	flush()
	_update_report(dt)


# --- Terrains ----------------------------------------------------------------------------------

## A generator registers a copy of its settings, and gets the terrain id it uses for its chunks' markers.
## The id comes from the generator's scene path, so it matches on every machine, and across reloads, with nobody
## having to choose a number. Moving or renaming the node changes it. Registering again replaces the settings.
func register_terrain(scene_path: String, settings: NavTerrainSettings) -> int:
	var id := scene_marker_id(scene_path)
	_terrains[id] = settings
	return id


## Forgets a terrain's settings. Its chunks' markers leave through release_markers, not this.
func unregister_terrain(terrain: int) -> void:
	_terrains.erase(terrain)


## A registered terrain's settings, or null if there's no such terrain.
func get_terrain_settings(terrain: int) -> NavTerrainSettings:
	return _terrains.get(terrain)


## Which chunk a position in the world is in, whether or not that chunk is loaded. Vector2i.ZERO for an unknown terrain.
func chunk_of(terrain: int, position: Vector3) -> Vector2i:
	var settings: NavTerrainSettings = _terrains.get(terrain)
	if settings == null:
		return Vector2i.ZERO
	var local := position - settings.origin
	return Vector2i(floori(local.x / settings.tile_size), floori(local.z / settings.tile_size))


# --- Requests. These are checked straight away and take effect on the next tick. ---------------

## A chunk announces its markers. Returns how many were accepted; refused ones get one warning between them.
## A marker's id comes from its place in this list, so a generator must build the list the same way every time.
func request_markers(terrain: int, chunk: Vector2i, markers: Array[NavMarker]) -> int:
	var new_rows := PackedInt32Array()
	var new_ids := PackedInt64Array()
	var refused := 0
	var first_reason := ""
	for index in markers.size():
		var id := chunk_marker_id(terrain, chunk, index)
		var reason := _why_refused(markers[index], id)
		if reason != "":
			refused += 1
			if first_reason == "":
				first_reason = reason
			continue
		new_rows.append(_write_row(markers[index], id, true))
		new_ids.append(id)
	if refused > 0:
		push_warning("[NavWorld] chunk %s refused %d of %d markers. First reason: %s" % [chunk, refused, markers.size(), first_reason])
	if new_rows.is_empty():
		return 0
	var key := _chunk_key(terrain, chunk)
	if _chunk_ids.has(key):
		var existing_ids: PackedInt64Array = _chunk_ids[key]
		existing_ids.append_array(new_ids)
		new_ids = existing_ids
	_chunk_ids[key] = new_ids # stored back on purpose: a packed array in a Dictionary may not update through a copy
	_queue.append([Op.ADD, new_rows])
	_note_change()
	return new_rows.size()


## A hand-placed marker asks to be registered. Returns its id, or 0 if it was refused.
## NavMarkerNode will call this with its scene path, so moving or renaming that node changes the id.
func request_scene_marker(scene_path: String, marker: NavMarker) -> int:
	var id := scene_marker_id(scene_path)
	var reason := _why_refused(marker, id)
	if reason != "":
		push_warning("[NavWorld] scene marker %s refused: %s" % [scene_path, reason])
		return 0
	var rows := PackedInt32Array()
	rows.append(_write_row(marker, id, false))
	_queue.append([Op.ADD, rows])
	_note_change()
	return id


## A chunk is unloading, so all its markers leave. Changes made to them are kept for when it comes back.
func release_markers(terrain: int, chunk: Vector2i) -> void:
	var key := _chunk_key(terrain, chunk)
	if not _chunk_ids.has(key):
		return
	var ids: PackedInt64Array = _chunk_ids[key]
	var rows := PackedInt32Array()
	for id in ids:
		rows.append(_row_of_id[id])
		_row_of_id.erase(id)
	_chunk_ids.erase(key)
	_queue.append([Op.REMOVE, rows])


## Removes one hand-placed marker. A chunk's markers leave through release_markers instead.
func remove_scene_marker(id: int) -> void:
	var row: int = _row_of_id.get(id, NO_ROW)
	if row == NO_ROW:
		return
	if _from_chunk[row] == 1:
		push_warning("[NavWorld] marker %d belongs to a chunk; use release_markers" % id)
		return
	_row_of_id.erase(id)
	var rows := PackedInt32Array()
	rows.append(row)
	_queue.append([Op.REMOVE, rows])


## Switches a marker on or off. For a chunk's marker, the change is remembered through unloads, and only
## while it differs from how the marker started, so memory doesn't grow with the size of the world.
func set_enabled(id: int, enabled: bool) -> void:
	var row: int = _row_of_id.get(id, NO_ROW)
	if row == NO_ROW:
		push_warning("[NavWorld] set_enabled: no marker with id %d" % id)
		return
	if _from_chunk[row] == 1:
		if enabled == _markers[row].starts_enabled:
			_kept_changes.erase(id)
		else:
			_kept_changes[id] = enabled
	_queue.append([Op.SET_ENABLED, row, enabled])


## Applies every waiting request now, and tells modules. The tick does this by itself; tests and tools can
## call it directly.
func flush() -> void:
	if _queue.is_empty():
		return
	# Swapped out first, because a module may make new requests during its calls. Those wait for the next tick.
	var requests := _queue
	_queue = []
	var changed_rows := PackedInt32Array() # switches in a row become one call to modules
	for request: Array in requests:
		if request[0] != Op.SET_ENABLED and not changed_rows.is_empty():
			_tell_modules(changed_rows, Op.SET_ENABLED)
			changed_rows = PackedInt32Array()
		match request[0]: # GDScript note: match is GDScript's version of "switch": it runs the branch that fits
			Op.ADD:
				for row in request[1]:
					_link_row(row)
				_tell_modules(request[1], Op.ADD)
			Op.REMOVE:
				for row in request[1]:
					_unlink_row(row)
				_tell_modules(request[1], Op.REMOVE) # before freeing, because that clears the rows' ids
				for row in request[1]:
					_free_row(row)
			Op.SET_ENABLED:
				var new_value := 1 if request[2] else 0
				if _enabled[request[1]] != new_value:
					_enabled[request[1]] = new_value
					if _linked[request[1]] == 1:
						changed_rows.append(request[1])
			Op.ADD_MODULE:
				# It may have left, and even been freed, before this tick came. This is checked here because
				# a freed object can't be passed to a function that expects a NavMarkerModule.
				if is_instance_valid(request[1]) and _modules_waiting.has(request[1]):
					_join_waiting_module(request[1])
	if not changed_rows.is_empty():
		_tell_modules(changed_rows, Op.SET_ENABLED)


## A module entered the tree. It joins on the next tick, so its own _ready has run by the time it gets any calls.
func add_module(module: NavMarkerModule) -> void:
	if _modules.has(module) or _modules_waiting.has(module):
		return
	_modules_waiting.append(module)
	_queue.append([Op.ADD_MODULE, module])
	_note_change()


## A module is leaving the tree. This happens straight away, not on the next tick, because the module may not
## exist by then. It gets a final _markers_removed so it can undo its work. The markers stay registered.
func remove_module(module: NavMarkerModule) -> void:
	_modules_waiting.erase(module)
	if not _modules.has(module):
		return
	var ids := _ids_handled_by(module)
	_modules.erase(module)
	_announced_types.erase(module)
	_rebuild_modules_of_type()
	_note_change()
	if not ids.is_empty():
		module._markers_removed(ids)


## Forgets every marker and every kept change. For tests, and for leaving a level. Modules stay, and are told
## their markers have gone. Modules waiting to join still join on the next tick.
func reset() -> void:
	for module in _modules.duplicate():
		var ids := _ids_handled_by(module)
		if not ids.is_empty():
			module._markers_removed(ids)
	_ids.clear()
	_positions.clear()
	_masks.clear()
	_enabled.clear()
	_from_chunk.clear()
	_linked.clear()
	_types.clear()
	_type_scripts.clear()
	_type_of_script.clear()
	_type_counts.clear()
	_modules_of_type.clear()
	_reported_types.clear()
	_report_waiting = false
	_automatic_report_count = 0
	_next_in_cell.clear()
	_previous_in_cell.clear()
	_markers.clear()
	_free_rows.clear()
	_row_of_id.clear()
	_cell_heads.clear()
	_chunk_ids.clear()
	_terrains.clear()
	_kept_changes.clear()
	_queue.clear()
	for module in _modules_waiting:
		_queue.append([Op.ADD_MODULE, module])


# --- The debug report -------------------------------------------------------------------------

## Types with markers that no module announced, as type name -> how many markers.
func get_unhandled_types() -> Dictionary:
	var unhandled := {}
	for type_index in _type_scripts.size():
		if _type_counts[type_index] > 0 and not _type_is_claimed(type_index):
			unhandled[_type_name(type_index)] = _type_counts[type_index]
	return unhandled


## How many automatic reports have been made since the last reset.
func get_automatic_report_count() -> int:
	return _automatic_report_count


## Prints the same list on demand, in any build.
func print_report() -> void:
	var unhandled := get_unhandled_types()
	print("[NavWorld] every marker type has a module" if unhandled.is_empty() else "[NavWorld] no module handles: " + _describe_types(unhandled))


func _note_change() -> void:
	_report_waiting = true
	_quiet_seconds = 0.0


func _update_report(dt: float) -> void:
	if not _report_waiting or not report_unhandled or not OS.is_debug_build():
		return
	_quiet_seconds += dt
	if _quiet_seconds < report_quiet_seconds:
		return
	_report_waiting = false
	var new_types := {}
	for type_index in _type_scripts.size():
		var script := _type_scripts[type_index]
		if _type_is_claimed(type_index):
			_reported_types.erase(script) # it has a module now, so losing that module later reports it again
		elif _type_counts[type_index] > 0 and not _reported_types.has(script):
			_reported_types[script] = true
			new_types[_type_name(type_index)] = _type_counts[type_index]
	if not new_types.is_empty():
		_automatic_report_count += 1
		push_warning("[NavWorld] no module handles: " + _describe_types(new_types))


## True if a module that counts for the report handles this type.
func _type_is_claimed(type_index: int) -> bool:
	for module: NavMarkerModule in _modules_of_type[type_index]:
		if module.counts_for_report():
			return true
	return false


func _describe_types(types: Dictionary) -> String:
	var names: Array = types.keys()
	names.sort() # so the same situation always reads the same way
	var parts := PackedStringArray()
	for type_name: String in names:
		parts.append("%s (%d %s)" % [type_name, types[type_name], "marker" if types[type_name] == 1 else "markers"])
	return ", ".join(parts)


func _type_name(type_index: int) -> String:
	var script := _type_scripts[type_index]
	var global_name := script.get_global_name()
	# A script with no class_name has no name of its own, so its file name is the best description.
	return String(global_name) if global_name != &"" else script.resource_path.get_file()


# --- Questions. These read the state as of the last tick. --------------------------------------

## The id of the nearest enabled marker matching the tag, within max_distance. 0 if there's none.
## Equal distances go to the lower id, so every machine picks the same marker.
func find_nearest(tag: StringName, from: Vector3, max_distance: float) -> int:
	var search_bit := _search_bit(tag)
	if search_bit == 0 or max_distance < 0.0 or _cell_heads.is_empty():
		return 0
	var center := _cell_of(from)
	var best_id := 0
	var best_distance := max_distance * max_distance
	var ring := 0
	while true:
		# Nothing in this ring can be closer than this. The search starts somewhere inside the center cell, so
		# a ring's cells are at least (ring - 1) whole cells away. Height can only add to that.
		var closest_possible := maxf(ring - 1, 0) * CELL_SIZE
		if closest_possible > max_distance:
			break
		if best_id != 0 and closest_possible * closest_possible > best_distance:
			break
		# Once the rings have covered more cells than actually hold markers, it's cheaper to check them all.
		var cells: Array
		var checking_everything := (2 * ring + 1) * (2 * ring + 1) > _cell_heads.size()
		if checking_everything:
			cells = _cell_heads.keys()
		else:
			cells = _cells_in_ring(center, ring)
		for cell: Vector2i in cells:
			var row: int = _cell_heads.get(cell, NO_ROW)
			while row != NO_ROW:
				if _masks[row] & search_bit != 0 and _enabled[row] == 1:
					var distance := from.distance_squared_to(_positions[row])
					if distance < best_distance or (distance == best_distance and (best_id == 0 or _ids[row] < best_id)):
						best_distance = distance
						best_id = _ids[row]
				row = _next_in_cell[row]
		if checking_everything:
			break
		ring += 1
	return best_id


## The ids of every enabled marker matching the tag, within the radius. Sorted by id, so every machine gets
## the same order.
func find_in_radius(tag: StringName, from: Vector3, radius: float) -> PackedInt64Array:
	var found := PackedInt64Array()
	var search_bit := _search_bit(tag)
	if search_bit == 0 or radius < 0.0 or _cell_heads.is_empty():
		return found
	var radius_squared := radius * radius
	for cell: Vector2i in _cells_within(from, radius):
		var row: int = _cell_heads.get(cell, NO_ROW)
		while row != NO_ROW:
			if _masks[row] & search_bit != 0 and _enabled[row] == 1:
				if from.distance_squared_to(_positions[row]) <= radius_squared:
					found.append(_ids[row])
			row = _next_in_cell[row]
	found.sort()
	return found


## The full data for a marker, or null if there's no such id.
func get_marker(id: int) -> NavMarker:
	var row: int = _row_of_id.get(id, NO_ROW)
	return null if row == NO_ROW else _markers[row]


## Where a marker is. Vector3.ZERO if there's no such id.
func get_marker_position(id: int) -> Vector3:
	var row: int = _row_of_id.get(id, NO_ROW)
	return Vector3.ZERO if row == NO_ROW else _positions[row]


func is_marker_enabled(id: int) -> bool:
	var row: int = _row_of_id.get(id, NO_ROW)
	return row != NO_ROW and _enabled[row] == 1


func get_marker_count() -> int:
	return _row_of_id.size()


## How many requests are waiting for the next tick.
func get_pending_count() -> int:
	return _queue.size()


## How many marker changes are being remembered for chunks, loaded or not.
func get_kept_change_count() -> int:
	return _kept_changes.size()


# --- Ids --------------------------------------------------------------------------------------

## The same chunk and index give the same id on every machine, and after every reload.
func chunk_marker_id(terrain: int, chunk: Vector2i, index: int) -> int:
	var value := FNV_OFFSET
	for number: int in [terrain, chunk.x, chunk.y, index]:
		# GDScript note: >> shifts a number's bits right, and & 0xFF keeps only the lowest eight of them.
		# Together they take the number apart one byte at a time.
		for byte_number in 8:
			value = (value ^ ((number >> (byte_number * 8)) & 0xFF)) * FNV_PRIME
	return _never_zero(value)


func scene_marker_id(scene_path: String) -> int:
	return _never_zero(fnv_hash(scene_path.to_utf8_buffer()))


## The FNV-1a hash of some bytes: for each byte, XOR it in and multiply by the prime.
## GDScript note: ints are 64 bits and wrap around when they overflow, which this relies on.
func fnv_hash(bytes: PackedByteArray) -> int:
	var value := FNV_OFFSET
	for byte in bytes:
		value = (value ^ byte) * FNV_PRIME
	return value


# One number for a terrain and chunk, for looking up the chunk's list. A Vector3i can't hold them, because a terrain
# id takes 64 bits and each part of a Vector3i only has 32. An index of -1 can't clash with a real marker's id.
func _chunk_key(terrain: int, chunk: Vector2i) -> int:
	return chunk_marker_id(terrain, chunk, -1)


# 0 means "no marker" in the rows and in search results, so no marker may have it.
func _never_zero(value: int) -> int:
	return 1 if value == 0 else value


# --- Internals --------------------------------------------------------------------------------

## Why a marker can't be registered, or "" if it can.
func _why_refused(marker: NavMarker, id: int) -> String:
	if marker == null:
		return "the marker is null"
	if _row_of_id.has(id):
		return "id %d is already registered" % id
	if not NavTags.has_tag(marker.tag):
		return "tag '%s' isn't declared in the nav tag declarations" % marker.tag
	return ""


## Fills a row and returns its number. The marker isn't searchable until _link_row runs on the next tick.
func _write_row(marker: NavMarker, id: int, from_chunk: bool) -> int:
	var row := _take_free_row()
	var enabled: bool = _kept_changes.get(id, marker.starts_enabled)
	_ids[row] = id
	_positions[row] = marker.position
	_masks[row] = NavTags.mask_of(marker.tag)
	_enabled[row] = 1 if enabled else 0
	_from_chunk[row] = 1 if from_chunk else 0
	_markers[row] = marker
	_row_of_id[id] = row
	var type_index := _type_index_of(marker.get_script())
	_types[row] = type_index
	_type_counts[type_index] += 1
	return row


## The number for a marker's type, adding the type the first time it's seen.
func _type_index_of(script: Script) -> int:
	if _type_of_script.has(script):
		return _type_of_script[script]
	var type_index := _type_scripts.size()
	_type_of_script[script] = type_index
	_type_scripts.append(script)
	_type_counts.append(0)
	_modules_of_type.append(_find_modules_for(script))
	return type_index


## Every joined module that handles this type or one of its parents.
func _find_modules_for(script: Script) -> Array:
	var found := []
	for module in _modules:
		var announced: Array = _announced_types[module]
		var checking := script
		while checking != null:
			if announced.has(checking):
				found.append(module)
				break
			# GDScript note: a script's base script is the one it extends, so this climbs NavLink -> NavMarker.
			checking = checking.get_base_script()
	return found


func _rebuild_modules_of_type() -> void:
	for type_index in _type_scripts.size():
		_modules_of_type[type_index] = _find_modules_for(_type_scripts[type_index])


func _join_waiting_module(module: NavMarkerModule) -> void:
	_modules_waiting.erase(module)
	_modules.append(module)
	_announced_types[module] = module.handled_types()
	_rebuild_modules_of_type()
	var ids := _ids_handled_by(module)
	if not ids.is_empty():
		module._markers_added(ids)


## The ids of every applied marker this module handles. It checks every row, so it's only for joining and leaving.
func _ids_handled_by(module: NavMarkerModule) -> PackedInt64Array:
	var ids := PackedInt64Array()
	for row in _ids.size():
		if _linked[row] == 1 and _modules_of_type[_types[row]].has(module):
			ids.append(_ids[row])
	return ids


## Gives each module one call, with the ids it handles out of these rows.
func _tell_modules(rows: PackedInt32Array, what: Op) -> void:
	if _modules.is_empty():
		return
	var ids_for_module := {} # module -> Array of ids
	for row in rows:
		for module: NavMarkerModule in _modules_of_type[_types[row]]:
			if not ids_for_module.has(module):
				ids_for_module[module] = []
			ids_for_module[module].append(_ids[row])
	# Going through _modules keeps the order the same every time. Dictionary order would depend on the rows.
	for module in _modules.duplicate():
		# It's checked again because an earlier module's call may have removed this one.
		if not ids_for_module.has(module) or not _modules.has(module):
			continue
		var ids := PackedInt64Array(ids_for_module[module])
		match what:
			Op.ADD:
				module._markers_added(ids)
			Op.REMOVE:
				module._markers_removed(ids)
			Op.SET_ENABLED:
				module._markers_changed(ids)


func _take_free_row() -> int:
	if not _free_rows.is_empty():
		var row := _free_rows[_free_rows.size() - 1]
		_free_rows.resize(_free_rows.size() - 1)
		return row
	var new_row := _ids.size()
	_ids.append(0)
	_positions.append(Vector3.ZERO)
	_masks.append(0)
	_enabled.append(0)
	_from_chunk.append(0)
	_linked.append(0)
	_types.append(0)
	_next_in_cell.append(NO_ROW)
	_previous_in_cell.append(NO_ROW)
	_markers.append(null)
	return new_row


func _free_row(row: int) -> void:
	_type_counts[_types[row]] -= 1
	_ids[row] = 0
	_markers[row] = null
	_free_rows.append(row)


## Puts a row at the front of its cell's linked list, which is what makes it searchable.
func _link_row(row: int) -> void:
	var cell := _cell_of(_positions[row])
	var old_head: int = _cell_heads.get(cell, NO_ROW)
	_next_in_cell[row] = old_head
	_previous_in_cell[row] = NO_ROW
	if old_head != NO_ROW:
		_previous_in_cell[old_head] = row
	_cell_heads[cell] = row
	_linked[row] = 1


## Takes a row out of its cell's linked list by joining its two neighbours to each other.
func _unlink_row(row: int) -> void:
	_linked[row] = 0
	var previous := _previous_in_cell[row]
	var next := _next_in_cell[row]
	if previous != NO_ROW:
		_next_in_cell[previous] = next
	else:
		# It was first in its cell, so the cell now starts at the next row, or holds nothing at all.
		var cell := _cell_of(_positions[row])
		if next != NO_ROW:
			_cell_heads[cell] = next
		else:
			_cell_heads.erase(cell)
	if next != NO_ROW:
		_previous_in_cell[next] = previous


## Which cell a position is in. Height doesn't matter, because the world is a flat plane with layers on it.
## GDScript note: floori rounds down, even for negatives, so -0.5 goes to cell -1 and not cell 0.
func _cell_of(position: Vector3) -> Vector2i:
	return Vector2i(floori(position.x / CELL_SIZE), floori(position.z / CELL_SIZE))


## The tag's bit for searching, or 0 if nothing can match it. Never adds a tag.
func _search_bit(tag: StringName) -> int:
	if not NavTags.has_tag(tag):
		return 0
	return NavTags.own_bit(tag)


## The square ring of cells exactly this many cells away from the center.
func _cells_in_ring(center: Vector2i, ring: int) -> Array:
	if ring == 0:
		return [center]
	var cells := []
	for x in range(center.x - ring, center.x + ring + 1):
		cells.append(Vector2i(x, center.y - ring))
		cells.append(Vector2i(x, center.y + ring))
	for y in range(center.y - ring + 1, center.y + ring):
		cells.append(Vector2i(center.x - ring, y))
		cells.append(Vector2i(center.x + ring, y))
	return cells


## Every cell a search of this radius has to look at, or just the occupied ones if that's fewer.
func _cells_within(from: Vector3, radius: float) -> Array:
	# Worked out as a float first, so that a huge or infinite radius can't overflow.
	var cells_across := radius * 2.0 / CELL_SIZE + 2.0
	if cells_across * cells_across >= _cell_heads.size():
		return _cell_heads.keys()
	var low := _cell_of(from - Vector3(radius, 0.0, radius))
	var high := _cell_of(from + Vector3(radius, 0.0, radius))
	var cells := []
	for x in range(low.x, high.x + 1):
		for y in range(low.y, high.y + 1):
			cells.append(Vector2i(x, y))
	return cells
