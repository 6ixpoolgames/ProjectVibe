# Written by Claude (claude-opus-5-5), 2026-11-15. History: replay/CHANGELOG.md.
## Plays and scrubs a recording: ghost capsules for the pawns, outlines for the built chunks and the chunk sources' load distances.
##
## Runs [code]replay_viewer.tscn[/code]. Nothing is simulated; it only shows what was recorded. The file is [member file_path], else
## [code]-- --file=<path>[/code], else the newest recording in the host folder ([code]-- --client[/code]: the client folder). A
## recording with the diagnostics channel also shows a strip of its slowest frames above the slider, filled in the background; click
## it to jump. Keys, ghost colours and the strip are in the replay README.
## Design: replay spec, diagnostics spec.
class_name ReplayViewer
extends Node3D

## The recording to open. Empty: the command line's --file=, else the newest recording.
@export_file("*.pbreplay") var file_path := ""
## The folder the newest recording is looked for in.
@export var replays_folder := "user://replays"

const TEAM_COLOURS: Array[Color] = [Color(0.35, 0.65, 1.0), Color(1.0, 0.35, 0.3), Color(0.4, 0.5, 1.0), Color(0.5, 0.9, 0.4),
	Color(1.0, 0.8, 0.3)]
const SPEEDS: Array[float] = [0.1, 0.25, 0.5, 1.0, 2.0, 4.0]

var _reader: ReplayReader = null
var _tick := 0.0 # the tick shown; a float so playback can move by fractions of a tick
var _shown_tick := -1
var _playing := false
var _speed_index := 3
var _ghosts := {} # replay id -> [body MeshInstance3D, Label3D]
var _selected := 0 # a replay id, or 0
var _following := false
var _labels_on := true
var _camera: Camera3D = null
var _focus := Vector3.ZERO
var _yaw := 0.6
var _pitch := -0.7
var _distance := 40.0
var _lines: MeshInstance3D = null
var _status: Label = null
var _panel: Label = null
var _slider: HSlider = null
var _setting_slider := false
var _strip: Control = null # the diagnostics strip
var _strip_values := PackedFloat32Array() # the slowest frame in each column of the strip, in ms; -1 where there's nothing yet
var _strip_next_block := 0 # the next block to read for the strip


func _ready() -> void:
	_build_scene()
	var path := _choose_file()
	if path == "":
		_status.text = "No recording found in %s. Play a sample (Offline or Host) to make one, or pass -- --file=<path>." % replays_folder
		return
	_reader = ReplayReader.new()
	var error := _reader.open(path)
	if error != OK or _reader.get_block_count() == 0:
		_status.text = "Couldn't read %s (error %d)." % [path, error]
		_reader = null
		return
	file_path = path
	_tick = _reader.get_first_tick()
	_slider.min_value = _reader.get_first_tick()
	_slider.max_value = _reader.get_last_tick()
	_strip_values.resize(512) # columns of the diagnostics strip
	_strip_values.fill(-1.0)
	_strip_next_block = 0
	var first := _reader.get_frame(_reader.get_first_tick())
	_labels_on = first.pawns.size() <= 40
	_focus = _middle_of(first)
	_show(true)


## Shows the nearest recorded tick at or before this one.
func show_tick(tick: int) -> void:
	_tick = tick
	_show(true)


## The tick shown now.
func get_shown_tick() -> int:
	return _shown_tick


## How many ghosts are visible now, for tests.
# REFACTOR: this and get_reader are read only by replay_selftest (replay/CHANGELOG.md).
func get_visible_ghost_count() -> int:
	var count := 0
	for id: int in _ghosts:
		if _ghosts[id][0].visible:
			count += 1
	return count


## The reader behind the viewer, for tests.
func get_reader() -> ReplayReader:
	return _reader


func _process(delta: float) -> void:
	if _reader == null:
		return
	_fill_strip()
	if _playing:
		_tick = minf(_tick + delta * float(_reader.get_header().get("tick_rate", 60)) * SPEEDS[_speed_index], _reader.get_last_tick())
		if _tick >= _reader.get_last_tick():
			_playing = false
	if not _following:
		var move := Vector3.ZERO
		if Input.is_physical_key_pressed(KEY_W):
			move.z -= 1.0
		if Input.is_physical_key_pressed(KEY_S):
			move.z += 1.0
		if Input.is_physical_key_pressed(KEY_A):
			move.x -= 1.0
		if Input.is_physical_key_pressed(KEY_D):
			move.x += 1.0
		_focus += move.rotated(Vector3.UP, _yaw) * delta * _distance
	_show(false)


func _unhandled_input(event: InputEvent) -> void:
	var motion := event as InputEventMouseMotion
	if motion and (motion.button_mask & MOUSE_BUTTON_MASK_RIGHT) != 0:
		_yaw -= motion.relative.x * 0.005
		_pitch = clampf(_pitch - motion.relative.y * 0.005, -1.5, -0.05)
	var button := event as InputEventMouseButton
	if button and button.pressed:
		if button.button_index == MOUSE_BUTTON_WHEEL_UP:
			_distance = maxf(_distance * 0.85, 2.0)
		elif button.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_distance = minf(_distance / 0.85, 2000.0)
	var key := event as InputEventKey
	if key == null or not key.pressed or _reader == null:
		return
	var step := 10 if key.shift_pressed else 1
	match key.physical_keycode:
		KEY_SPACE:
			_playing = not _playing
			if _playing and _tick >= _reader.get_last_tick():
				_tick = _reader.get_first_tick()
		KEY_RIGHT:
			_playing = false
			_tick = minf(roundf(_tick) + step, _reader.get_last_tick())
		KEY_LEFT:
			_playing = false
			_tick = maxf(roundf(_tick) - step, _reader.get_first_tick())
		KEY_HOME:
			_tick = _reader.get_first_tick()
		KEY_END:
			_tick = _reader.get_last_tick()
		KEY_EQUAL, KEY_KP_ADD:
			_speed_index = mini(_speed_index + 1, SPEEDS.size() - 1)
		KEY_MINUS, KEY_KP_SUBTRACT:
			_speed_index = maxi(_speed_index - 1, 0)
		KEY_BRACKETLEFT:
			_select(-1)
		KEY_BRACKETRIGHT:
			_select(1)
		KEY_F:
			_following = not _following and _selected != 0
		KEY_L:
			_labels_on = not _labels_on
			_shown_tick = -1 # redraw


# --- Showing a tick ---


func _show(force: bool) -> void:
	var frame := _reader.get_frame(floori(_tick))
	if frame.tick == _shown_tick and not force:
		_update_camera(frame)
		return
	_shown_tick = frame.tick
	_setting_slider = true
	_slider.value = frame.tick
	_setting_slider = false
	var seen := {}
	for id: int in frame.pawns:
		var info: Dictionary = frame.pawns[id]
		var motion: Variant = info.get("motion")
		if motion == null:
			continue
		seen[id] = true
		var ghost: Array = _ghosts.get(id, [])
		if ghost.is_empty():
			ghost = _make_ghost()
			_ghosts[id] = ghost
		_place_ghost(ghost, id, info, motion)
	for id: int in _ghosts:
		if not seen.has(id):
			_ghosts[id][0].hide()
			_ghosts[id][1].hide()
	_draw_world(frame)
	_update_camera(frame)
	_status.text = _status_text(frame)
	_panel.text = _panel_text(frame)


func _place_ghost(ghost: Array, id: int, info: Dictionary, motion: Dictionary) -> void:
	var body: MeshInstance3D = ghost[0]
	var label: Label3D = ghost[1]
	var flags: int = motion.flags
	var dead := (flags & ReplayMotionChannel.FLAG_DEAD) != 0
	var frozen := (flags & ReplayMotionChannel.FLAG_FROZEN) != 0
	var sleeping := (flags & ReplayMotionChannel.FLAG_SLEEPING) != 0
	var colour: Color = TEAM_COLOURS[posmod(int(info.get("team", 0)), TEAM_COLOURS.size())]
	if dead:
		colour = Color(0.45, 0.45, 0.45)
	elif frozen:
		colour = Color(0.75, 0.9, 1.0)
	elif sleeping:
		colour = colour.darkened(0.4)
	if id == _selected:
		colour = colour.lightened(0.35)
	var material: StandardMaterial3D = body.material_override
	material.albedo_color = Color(colour, 0.35 if frozen else 0.75)
	body.position = motion.position + Vector3(0, 0.9, 0)
	body.rotation = Vector3(0, motion.yaw, PI / 2.0 if dead else 0.0)
	body.show()
	label.visible = _labels_on or id == _selected
	if label.visible:
		label.position = motion.position + Vector3(0, 2.4, 0)
		label.text = "%s #%d %s\ny %.2f  %.1f m/s" % [info.get("name", "?"), id, _flag_letters(flags), motion.position.y, motion.velocity.length()]


static func _flag_letters(flags: int) -> String:
	var letters := ""
	for pair: Array in [[ReplayMotionChannel.FLAG_GROUNDED, "G"], [ReplayMotionChannel.FLAG_DEAD, "D"],
			[ReplayMotionChannel.FLAG_FROZEN, "F"], [ReplayMotionChannel.FLAG_SLEEPING, "S"], [ReplayMotionChannel.FLAG_HAS_SOURCE, "C"],
			[ReplayMotionChannel.FLAG_HAS_PLAYER, "P"]]:
		if (flags & pair[0]) != 0:
			letters += pair[1]
	return letters


# Chunk outlines on the ground (at each terrain's height), and each source's load distance as a circle. Redrawn per tick shown.
func _draw_world(frame: Dictionary) -> void:
	var mesh: ImmediateMesh = _lines.mesh
	mesh.clear_surfaces()
	var any := false
	for id: int in frame.terrains:
		var terrain: Dictionary = frame.terrains[id]
		var size: float = terrain.get("chunk_size", 64.0)
		var origin: Vector3 = terrain.get("origin", Vector3.ZERO)
		var chunks: Dictionary = terrain.get("chunks", {})
		if chunks.is_empty():
			continue
		if not any:
			mesh.surface_begin(Mesh.PRIMITIVE_LINES)
			any = true
		mesh.surface_set_color(Color(0.4, 0.9, 0.5))
		for key: Vector2i in chunks:
			var corner := origin + Vector3(key.x * size, 0.05, key.y * size)
			var corners := [corner, corner + Vector3(size, 0, 0), corner + Vector3(size, 0, size), corner + Vector3(0, 0, size)]
			for i in 4:
				mesh.surface_add_vertex(corners[i])
				mesh.surface_add_vertex(corners[(i + 1) % 4])
	for id: int in frame.sources:
		var source: Dictionary = frame.sources[id]
		if not any:
			mesh.surface_begin(Mesh.PRIMITIVE_LINES)
			any = true
		mesh.surface_set_color(Color(1.0, 0.85, 0.3) if source.get("active", false) else Color(0.5, 0.5, 0.5))
		var centre: Vector3 = source.get("position", Vector3.ZERO)
		var radius: float = source.get("load", 0.0)
		for i in 48:
			var a := TAU * i / 48.0
			var b := TAU * (i + 1) / 48.0
			mesh.surface_add_vertex(centre + Vector3(cos(a), 0.1, sin(a)) * Vector3(radius, 1, radius))
			mesh.surface_add_vertex(centre + Vector3(cos(b), 0.1, sin(b)) * Vector3(radius, 1, radius))
	if any:
		mesh.surface_end()


func _update_camera(frame: Dictionary) -> void:
	if _following and frame.pawns.has(_selected) and frame.pawns[_selected].get("motion") != null:
		_focus = frame.pawns[_selected].motion.position
	var offset := Vector3(0, 0, _distance).rotated(Vector3.RIGHT, _pitch).rotated(Vector3.UP, _yaw)
	_camera.position = _focus + offset
	_camera.look_at(_focus, Vector3.UP)


func _select(direction: int) -> void:
	var frame := _reader.get_frame(floori(_tick))
	var ids: Array = frame.pawns.keys()
	if ids.is_empty():
		return
	ids.sort()
	var at := ids.find(_selected)
	_selected = ids[posmod(at + direction, ids.size())] if at >= 0 else ids[0 if direction > 0 else -1]
	_shown_tick = -1


func _middle_of(frame: Dictionary) -> Vector3:
	var total := Vector3.ZERO
	var count := 0
	for id: int in frame.pawns:
		var motion: Variant = frame.pawns[id].get("motion")
		if motion != null:
			total += motion.position
			count += 1
	return total / count if count > 0 else Vector3.ZERO


func _status_text(frame: Dictionary) -> String:
	var header := _reader.get_header()
	var rate: float = header.get("tick_rate", 60)
	var seconds: float = (frame.tick - _reader.get_first_tick()) / rate
	return "%s   %s, started %s%s\ntick %d (%.2f s of %.1f)   %s x%s   %d pawns   %s\nSpace play, ←/→ step (Shift 10), Home/End, +/- speed, [ ] select, F follow, L labels, right drag turn, wheel zoom, WASD move" % [
		file_path.get_file(), header.get("role", "?"), header.get("started", "?"), "   (cut short: the game stopped mid-block)" if _reader.is_cut_short() else "",
		frame.tick, seconds, (_reader.get_last_tick() - _reader.get_first_tick()) / rate, "playing" if _playing else "paused",
		str(SPEEDS[_speed_index]), frame.pawns.size(), "following" if _following else ""]


# The selected pawn's record, then the last two seconds of events up to this tick (the selected pawn's marked).
func _panel_text(frame: Dictionary) -> String:
	var lines := PackedStringArray()
	if frame.pawns.has(_selected):
		var info: Dictionary = frame.pawns[_selected]
		lines.append("Selected: %s #%d (%s, team %d)" % [info.get("name", "?"), _selected, str(info.get("scene", "")).get_file(), info.get("team", 0)])
		var motion: Variant = info.get("motion")
		if motion != null:
			lines.append("  at %s, yaw %.0f°, moving %s, flags %s" % [_vector(motion.position), rad_to_deg(motion.yaw), _vector(motion.velocity), _flag_letters(motion.flags)])
		var input: Variant = info.get("input")
		if input != null:
			lines.append("  input: move %s, look %.0f°, held %d" % [_vector(input.move_input), rad_to_deg(input.look_yaw), input.held_actions])
	# The slowest frame at this tick, from the diagnostics channel, if the recording has it.
	if not frame.diagnostics.is_empty():
		var record: Dictionary = frame.diagnostics.reduce(func(a: Dictionary, b: Dictionary) -> Dictionary: return a if a.frame_ms >= b.frame_ms else b)
		var scope_names: Array = record.scopes.keys()
		scope_names.sort_custom(func(a: Variant, b: Variant) -> bool: return record.scopes[a][0] > record.scopes[b][0])
		var top := PackedStringArray()
		for scope: Variant in scope_names.slice(0, 5):
			top.append("%s %.2f" % [scope, record.scopes[scope][0] / 1000.0])
		lines.append("Frame %d: %.1f ms = physics %.1f (%d steps) + scripts %.1f + rest %.1f   objects %d, orphans %d" % [record.frame,
			record.frame_ms, record.physics_ms, record.steps, record.scripts_ms, record.rest_ms, record.objects, record.orphans])
		lines.append("  top ms: " + ", ".join(top))
	var rate: int = _reader.get_header().get("tick_rate", 60)
	var events := _reader.get_events(frame.tick - rate * 2, frame.tick)
	var names := {}
	for id: int in frame.pawns:
		names[id] = frame.pawns[id].get("name", "?")
	var shown := 0
	for i in range(events.size() - 1, -1, -1):
		var event: Dictionary = events[i]
		if event.kind in ["chunk_built", "chunk_collision"]:
			continue # dozens a second while the level loads; the outlines show them
		var who := str(names.get(event.id, "#%d" % event.id)) if event.id != 0 else ""
		lines.append("%s %d  %s %s %s" % ["▶" if event.tick == frame.tick else " ", event.tick, who, event.kind, _short(event.data)])
		shown += 1
		if shown >= 18:
			break
	return "\n".join(lines)


static func _vector(value: Vector3) -> String:
	return "(%.1f, %.1f, %.1f)" % [value.x, value.y, value.z]


static func _short(data: Dictionary) -> String:
	var parts := PackedStringArray()
	for key: String in data:
		var value: Variant = data[key]
		var text := _vector(value) if value is Vector3 else str(value)
		parts.append("%s=%s" % [key, text.left(80)])
	return " ".join(parts)


func _choose_file() -> String:
	if file_path != "":
		return file_path
	var role := "host"
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--file="):
			return argument.trim_prefix("--file=")
		if argument == "--client":
			role = "client"
	var folder := replays_folder.path_join(role)
	if not DirAccess.dir_exists_absolute(folder):
		return ""
	var newest := ""
	for file_name in DirAccess.get_files_at(folder):
		if file_name.get_extension() == ReplayRecorder.FILE_EXTENSION and file_name > newest:
			newest = file_name
	return folder.path_join(newest) if newest != "" else ""


# --- The scene, built in code ---


func _build_scene() -> void:
	_camera = Camera3D.new()
	_camera.far = 4000.0
	add_child(_camera)
	_camera.make_current()
	var light := DirectionalLight3D.new()
	light.rotation = Vector3(-1.0, 0.6, 0.0)
	add_child(light)
	var environment := WorldEnvironment.new()
	environment.environment = Environment.new()
	environment.environment.background_mode = Environment.BG_COLOR
	environment.environment.background_color = Color(0.1, 0.11, 0.13)
	environment.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.environment.ambient_light_color = Color(0.6, 0.6, 0.65)
	add_child(environment)
	_lines = MeshInstance3D.new()
	_lines.mesh = ImmediateMesh.new()
	var line_material := StandardMaterial3D.new()
	line_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	line_material.vertex_color_use_as_albedo = true
	_lines.material_override = line_material
	add_child(_lines)
	var layer := CanvasLayer.new()
	add_child(layer)
	_status = _make_label(Control.PRESET_TOP_LEFT)
	layer.add_child(_status)
	_panel = _make_label(Control.PRESET_BOTTOM_LEFT)
	_panel.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_panel.offset_bottom = -72.0 # above the diagnostics strip
	layer.add_child(_panel)
	_slider = HSlider.new()
	_slider.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	_slider.offset_left = 14.0
	_slider.offset_right = -14.0
	_slider.offset_top = -30.0
	_slider.offset_bottom = -10.0
	_slider.step = 1.0
	_slider.value_changed.connect(func(value: float) -> void:
		if not _setting_slider and _reader:
			_playing = false
			_tick = value)
	layer.add_child(_slider)
	# The diagnostics strip, just above the slider
	_strip = Control.new()
	_strip.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	_strip.offset_left = 14.0
	_strip.offset_right = -14.0
	_strip.offset_top = -66.0
	_strip.offset_bottom = -34.0
	_strip.draw.connect(_draw_strip)
	_strip.gui_input.connect(func(event: InputEvent) -> void:
		var click := event as InputEventMouseButton
		if click and click.pressed and click.button_index == MOUSE_BUTTON_LEFT and _reader and _strip.size.x > 0.0:
			_playing = false
			_tick = lerpf(_reader.get_first_tick(), _reader.get_last_tick(), clampf(click.position.x / _strip.size.x, 0.0, 1.0)))
	layer.add_child(_strip)


# Reads a few blocks' diagnostics a frame into the strip's columns, until the whole recording is in.
# REFACTOR: reads the reader's private _blocks for each block's first and last tick. A public ReplayReader.get_block_ticks(index)
# would keep the reader's insides its own. Extensible. See CHANGELOG.md.
func _fill_strip() -> void:
	if _strip == null:
		return
	var first := _reader.get_first_tick()
	var span := maxi(_reader.get_last_tick() - first, 1)
	var blocks := _reader.get_block_count()
	var read := 0
	while _strip_next_block < blocks and read < 8:
		var from: int = _reader._blocks[_strip_next_block][0]
		var to: int = _reader._blocks[_strip_next_block][1]
		for entry: Array in _reader.get_diagnostics(from, to):
			var column := clampi(int(float(entry[0] - first) / span * (_strip_values.size() - 1)), 0, _strip_values.size() - 1)
			_strip_values[column] = maxf(_strip_values[column], float(entry[1].frame_ms))
		_strip_next_block += 1
		read += 1
	_strip.queue_redraw()


func _draw_strip() -> void:
	var size := _strip.size
	_strip.draw_rect(Rect2(Vector2.ZERO, size), Color(0.0, 0.0, 0.0, 0.5))
	var scale_ms := 50.0
	var width := size.x / _strip_values.size()
	var any := false
	for i in _strip_values.size():
		var value := _strip_values[i]
		if value < 0.0:
			continue
		any = true
		var colour := Color(0.35, 0.6, 1.0) if value <= 17.5 else (Color(1.0, 0.65, 0.25) if value <= 34.0 else Color(1.0, 0.3, 0.3))
		var height := minf(value / scale_ms, 1.0) * size.y
		_strip.draw_rect(Rect2(i * width, size.y - height, maxf(width, 1.0), height), colour)
	for line: float in [1000.0 / 60.0, 1000.0 / 30.0]:
		var at := size.y - line / scale_ms * size.y
		_strip.draw_line(Vector2(0, at), Vector2(size.x, at), Color(1, 1, 1, 0.35))
	if _reader and any:
		var x := (float(_shown_tick - _reader.get_first_tick()) / maxi(_reader.get_last_tick() - _reader.get_first_tick(), 1)) * size.x
		_strip.draw_line(Vector2(x, 0), Vector2(x, size.y), Color(1, 1, 1, 0.9), 2.0)


func _make_label(preset: Control.LayoutPreset) -> Label:
	var label := Label.new()
	label.set_anchors_and_offsets_preset(preset)
	label.offset_left = 14.0
	label.offset_top = 10.0 if preset == Control.PRESET_TOP_LEFT else label.offset_top
	label.add_theme_font_size_override(&"font_size", 15)
	label.add_theme_constant_override(&"outline_size", 5)
	label.add_theme_color_override(&"font_outline_color", Color.BLACK)
	return label


func _make_ghost() -> Array:
	var body := MeshInstance3D.new()
	var capsule := CapsuleMesh.new()
	capsule.radius = 0.4
	capsule.height = 1.8
	body.mesh = capsule
	var material := StandardMaterial3D.new()
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	body.material_override = material
	add_child(body)
	# A marker on the front, so the ghost shows which way the pawn faced (as AIDebugTimeline's ghosts do).
	var facing := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(0.5, 0.12, 0.3)
	facing.mesh = box
	var facing_material := StandardMaterial3D.new()
	facing_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	facing_material.albedo_color = Color(1.0, 0.9, 0.4)
	facing.material_override = facing_material
	facing.position = Vector3(0.0, 0.55, -0.32)
	body.add_child(facing)
	var label := Label3D.new()
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.no_depth_test = true
	label.font_size = 40
	label.outline_size = 10
	label.pixel_size = 0.005
	add_child(label)
	return [body, label]
