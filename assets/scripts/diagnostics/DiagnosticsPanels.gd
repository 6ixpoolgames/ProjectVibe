# Written by Claude (claude-opus-5-5), 2026-11-16. History: diagnostics/CHANGELOG.md.
## The on-screen panels, one key each, for reading [DiagnosticsManager]'s numbers.
##
## A small fixed-width font in two columns so they never overlap: F1, F2 and F4 down the top right, F6, F7 and F8 up from the bottom
## left. F1 help, F2 frame graph, F4 timings (up to [constant SCOPES_LISTED] scopes), F6 spikes, F7 pawn inspector (Ctrl + left click
## a pawn), F8 log, F5 projectile trace ([ProjectileTraceView]) and F9 nav view ([NavDebugView]), both debug builds only, F12 capture ([method DiagnosticsManager.capture]). The
## diagnostics README lists what each shows.
## Design: diagnostics spec.
class_name DiagnosticsPanels
extends CanvasLayer

## Seconds between panel refreshes; the graph redraws every frame.
const REFRESH_SECONDS := 0.25
const FONT_SIZE := 12
const WIDTH := 470.0
## The most scopes the timings panel lists.
const SCOPES_LISTED := 14

var manager: DiagnosticsManager

var _right: VBoxContainer # F1, F2, F4, from the top right
var _left: VBoxContainer # F6, F7, F8, up from the bottom left
var _panels := {} # key -> [PanelContainer, Label or FrameGraph]
var _inspected: Pawn = null
var _refresh_left := 0.0
var _font: Font
var _note := "" # a line shown in the help panel, such as where the last capture went
var _nav_view: NavDebugView = null # F9, made the first time it's shown
var _trace_view: ProjectileTraceView = null # F5, made the first time it's shown


# The frame graph: one thin bar per frame, newest on the right.
class FrameGraph extends Control:
	var manager: DiagnosticsManager
	const SCALE_MS := 50.0

	func _init() -> void:
		custom_minimum_size = Vector2(DiagnosticsPanels.WIDTH - 16.0, 90.0)

	func _process(_delta: float) -> void:
		if is_visible_in_tree():
			queue_redraw()

	func _draw() -> void:
		var frames: Array = manager.get_frames()
		var height := size.y
		var bar := 2.0
		var count := mini(frames.size(), int(size.x / bar))
		var x := size.x - count * bar
		for i in range(frames.size() - count, frames.size()):
			var record: Dictionary = frames[i]
			var y := height
			for part: Array in [["physics_ms", Color(0.35, 0.6, 1.0)], ["scripts_ms", Color(1.0, 0.6, 0.25)], ["rest_ms", Color(0.5, 0.5, 0.5)]]:
				var length := minf(float(record.get(part[0], 0.0)) / SCALE_MS, 1.0) * height
				draw_rect(Rect2(x, y - length, bar, length), part[1])
				y -= length
			x += bar
		for line: Array in [[1000.0 / 60.0, Color(0.4, 1.0, 0.4, 0.8)], [1000.0 / 30.0, Color(1.0, 0.35, 0.35, 0.8)]]:
			var at: float = height - line[0] / SCALE_MS * height
			draw_line(Vector2(0, at), Vector2(size.x, at), line[1], 1.0)


func _ready() -> void:
	layer = 100 # above the game's own UI
	_font = SystemFont.new()
	(_font as SystemFont).font_names = PackedStringArray(["Consolas", "Courier New", "Liberation Mono", "monospace"])
	_right = VBoxContainer.new()
	_right.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	_right.offset_left = -WIDTH - 8.0
	_right.offset_right = -8.0
	_right.offset_top = 8.0
	_right.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	_right.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_right)
	_left = VBoxContainer.new()
	_left.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_LEFT)
	_left.offset_left = 8.0
	_left.offset_right = WIDTH + 8.0
	_left.offset_bottom = -8.0
	_left.grow_vertical = Control.GROW_DIRECTION_BEGIN # grows upwards as panels are shown
	_left.alignment = BoxContainer.ALIGNMENT_END
	_left.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_left)
	for key: Key in [KEY_F1, KEY_F2, KEY_F4]:
		_add_panel(key, _right)
	for key: Key in [KEY_F6, KEY_F7, KEY_F8]:
		_add_panel(key, _left)


func _add_panel(key: Key, column: VBoxContainer) -> void:
	var panel := PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.05, 0.06, 0.08, 0.78)
	style.set_content_margin_all(6.0)
	panel.add_theme_stylebox_override(&"panel", style)
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.visible = false
	var content: Control
	if key == KEY_F2:
		var box := VBoxContainer.new()
		box.add_child(_make_label())
		var graph := FrameGraph.new()
		graph.manager = manager
		box.add_child(graph)
		content = box
	else:
		content = _make_label()
	panel.add_child(content)
	column.add_child(panel)
	_panels[key] = [panel, content]


func _make_label() -> Label:
	var label := Label.new()
	label.add_theme_font_override(&"font", _font)
	label.add_theme_font_size_override(&"font_size", FONT_SIZE)
	label.add_theme_color_override(&"font_color", Color(0.92, 0.92, 0.88))
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.custom_minimum_size.x = WIDTH - 16.0
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return label


## True while a panel is shown.
func is_shown(key: Key) -> bool:
	if key == KEY_F9:
		return _nav_view != null and _nav_view.shown # the nav view isn't a panel
	if key == KEY_F5:
		return _trace_view != null and _trace_view.shown # nor is the projectile trace
	return _panels.has(key) and _panels[key][0].visible


## Shows or hides a panel, as its key does.
func toggle(key: Key) -> void:
	if key == KEY_F12:
		_note = "Captured to %s" % manager.capture()
		_panels[KEY_F1][0].visible = true
		_refresh_left = 0.0
		return
	# F9 is the nav view, drawn in the world rather than a panel. It's made the first time, under the manager (a
	# Node3D under this CanvasLayer would draw the same, but the manager is the module's root).
	if key == KEY_F9:
		if _nav_view == null:
			_nav_view = NavDebugView.new()
			_nav_view.name = "NavDebugView"
			manager.add_child(_nav_view)
		_nav_view.set_shown(not _nav_view.shown)
		return
	if key == KEY_F5:
		if _trace_view == null:
			_trace_view = ProjectileTraceView.new()
			_trace_view.name = "ProjectileTraceView"
			manager.add_child(_trace_view)
		_trace_view.set_shown(not _trace_view.shown)
		return
	if _panels.has(key):
		_panels[key][0].visible = not _panels[key][0].visible
		_refresh_left = 0.0
		if key == KEY_F4:
			PerfScopes.detailed = _panels[key][0].visible # the fine-grained scopes only while the timings are on screen


## The pawn the inspector shows.
func inspect(pawn: Pawn) -> void:
	_inspected = pawn
	_refresh_left = 0.0


## The text a panel shows now, for tests.
func get_text(key: Key) -> String:
	var content: Control = _panels[key][1]
	var label: Label = content if content is Label else content.get_child(0)
	return label.text


func _unhandled_input(event: InputEvent) -> void:
	var key := event as InputEventKey
	var listed := key and key.pressed and not key.echo and key.physical_keycode in [KEY_F1, KEY_F2, KEY_F4, KEY_F5, KEY_F6, KEY_F7, KEY_F8, KEY_F9, KEY_F12]
	if listed and not (key.physical_keycode == KEY_F5 and key.shift_pressed): # Shift+F5 is the net test bench's
		toggle(key.physical_keycode)
		get_viewport().set_input_as_handled()
		return
	var click := event as InputEventMouseButton
	if click and click.pressed and click.button_index == MOUSE_BUTTON_LEFT and click.ctrl_pressed and is_shown(KEY_F7):
		var pawn := _pawn_under(click.position)
		if pawn:
			inspect(pawn)
			get_viewport().set_input_as_handled()


func _pawn_under(at: Vector2) -> Pawn:
	var camera := get_viewport().get_camera_3d()
	if camera == null:
		return null
	var from := camera.project_ray_origin(at)
	var query := PhysicsRayQueryParameters3D.create(from, from + camera.project_ray_normal(at) * 1000.0)
	var hit := camera.get_world_3d().direct_space_state.intersect_ray(query)
	var node: Node = hit.get("collider")
	while node and not node is Pawn:
		node = node.get_parent()
	return node as Pawn


func _process(delta: float) -> void:
	_refresh_left -= delta
	if _refresh_left > 0.0:
		return
	_refresh_left = REFRESH_SECONDS
	if is_shown(KEY_F1):
		_set_text(KEY_F1, _help_text())
	if is_shown(KEY_F2) or is_shown(KEY_F4):
		var summary := manager.get_summary(1.0)
		if is_shown(KEY_F2):
			_set_text(KEY_F2, "F2 frame graph, %d fps: physics (blue) %.1f, scripts (orange) %.1f, rest (grey) %.1f ms. Lines: 1/60 s (green), 1/30 s (red)" % [
				summary.fps, summary.physics_ms, summary.scripts_ms, summary.rest_ms])
		if is_shown(KEY_F4):
			_set_text(KEY_F4, _timings_text(summary))
	if is_shown(KEY_F6):
		_set_text(KEY_F6, _spikes_text())
	if is_shown(KEY_F7):
		_set_text(KEY_F7, _inspector_text())
	if is_shown(KEY_F8):
		_set_text(KEY_F8, _log_text())


func _set_text(key: Key, text: String) -> void:
	var content: Control = _panels[key][1]
	var label: Label = content if content is Label else content.get_child(0)
	label.text = text


func _help_text() -> String:
	var lines := PackedStringArray(["F1 diagnostics keys",
		"  F2 frame graph   F4 timings   F6 spikes",
		"  F7 pawn inspector (Ctrl + click a pawn)   F8 log",
		"  F12 capture (screenshot, history, spikes, log, replay tick)",
		"  F5 projectile trace: paths, intersects, ends (debug builds)",
		"  F9 nav view: nav mesh, links, markers (debug builds)",
		"  F10 AI decisions: all in GDScript, and back to C++ (debug builds)",
		"log: %s" % manager.get_log_path().get_file()])
	if _note != "":
		lines.append(_note)
	return "\n".join(lines)


func _timings_text(n: Dictionary) -> String:
	var lines := PackedStringArray()
	lines.append("F4 timings, last %.0f s (%d frames)   %s %s, vsync %s" % [n.seconds, n.frames, n.role, n.window, n.vsync])
	lines.append("frame %6.1f ms %4.0f fps  worst %4.0f  late %3.0f%%  very late %3.0f%%" % [n.frame_ms, n.fps, n.frame_worst_ms, n.over_60_percent, n.over_30_percent])
	lines.append("  (late: over 20 ms, a missed 1/60 s; very late: over 34 ms)")
	lines.append("  physics %6.1f ms (%.2f steps)   scripts %5.1f   rest %5.1f" % [n.physics_ms, n.steps_per_frame, n.scripts_ms, n.rest_ms])
	# The animation category: the part of the scripts spent animating (every animation.* scope).
	lines.append("    of which animation %5.2f ms" % n.get("animation_ms", 0.0))
	lines.append("  tick    %6.2f ms   %3.0f ticks/s   dropped %.1f/s" % [n.tick_ms, n.ticks_per_second, n.dropped_per_second])
	# The load ladder (pawn spec 8.21), and how many AI pawns run every tick, every 2nd and every 4th.
	lines.append("  load step %d   AI every tick/2nd/4th %s" % [n.get("load_step", 1), DiagnosticsManager.steps_text(n.get("step_counts", {}))])
	lines.append("  " + DiagnosticsManager.server_text(n.get("server", {}))) # the server's tick rate (a client's from snapshots)
	lines.append("  drawing CPU %.1f  GPU %.1f ms   %d draw calls" % [n.render_cpu_ms, n.render_gpu_ms, n.draw_calls])
	lines.append("  memory %.0f MB   objects %d   nodes %d   orphan nodes %d" % [n.memory_mb, n.objects, n.nodes, n.orphans])
	lines.append("  pawns %d   dead %d   frozen %d" % [n.pawns, n.dead, n.frozen])
	lines.append("%-32s %9s %8s" % ["scope", "ms/frame", "calls"])
	var shown := 0
	for scope: StringName in n.scopes:
		lines.append("  %-30s %9.2f %8.1f" % [String(scope).left(30), n.scopes[scope][0], n.scopes[scope][1]])
		shown += 1
		if shown >= SCOPES_LISTED:
			lines.append("  ... %d more (the session log and captures have them all)" % (n.scopes.size() - shown))
			break
	return "\n".join(lines)


func _spikes_text() -> String:
	var spikes: Array = manager.get_spikes()
	var lines := PackedStringArray(["F6 spikes: frames over budget, newest first (%d kept)" % spikes.size()])
	for i in range(spikes.size() - 1, maxi(spikes.size() - 6, -1), -1):
		var record: Dictionary = spikes[i]
		var names: Array = record.scopes.keys()
		names.sort_custom(func(a: StringName, b: StringName) -> bool: return record.scopes[a][0] > record.scopes[b][0])
		lines.append("%7.1fs  %5.1f ms = physics %.1f (%d) + scripts %.1f + rest %.1f" % [record.time, record.frame_ms, record.physics_ms,
			record.steps, record.scripts_ms, record.rest_ms])
		var top := PackedStringArray()
		for scope: StringName in names.slice(0, 3):
			top.append("%s %.1f" % [scope, record.scopes[scope][0] / 1000.0])
		lines.append("          " + ", ".join(top))
	return "\n".join(lines)


func _inspector_text() -> String:
	if not is_instance_valid(_inspected):
		return "F7 pawn inspector: Ctrl + left click a pawn"
	var pawn := _inspected
	var lines := PackedStringArray()
	lines.append("F7 %s, team %d, %s" % [pawn.name, pawn.team, pawn.scene_file_path.get_file()])
	var at := pawn.global_position
	lines.append("  at (%.1f, %.1f, %.1f)   moving %.1f m/s   facing %.0f°" % [at.x, at.y, at.z, pawn.velocity.length(), rad_to_deg(pawn.yaw)])
	lines.append("  flags: %s%s%s%s%s%s   Health %.0f" % ["grounded " if pawn.grounded else "", "DEAD " if pawn.is_dead() else "",
		"FROZEN " if pawn.is_frozen() else "", "sleeping " if pawn.is_sleeping else "", "source " if pawn.is_keeping_world_loaded() else "",
		"player" if pawn.controller_manager and pawn.controller_manager.has_player() else "", pawn.stat_manager.get_health() if pawn.stat_manager else 0.0])
	var controllers := pawn.controller_manager # the pawn's input is its ControllerManager's
	if controllers:
		lines.append("  input: move (%.2f, %.2f), look %.0f°, held %d" % [controllers.move_input.x, controllers.move_input.z, rad_to_deg(controllers.look_yaw), controllers.held_actions])
	if pawn.ability_manager:
		var running := PackedStringArray()
		var cooling := PackedStringArray()
		var to_check := PackedStringArray()
		for ability in pawn.ability_manager.get_abilities():
			var note := ability.definition_note()
			if note != "":
				to_check.append("%s (%s)" % [ability.name, note])
			if ability.is_running_timed():
				# A stepped ability shows its running steps (pawn spec 8.20).
				var steps_now := ability.get_running_step_names()
				# A stepped ability's ticks_left is only its safety limit, so its steps' ticks show instead.
				if ability.is_stepped():
					var parts := PackedStringArray()
					for step in ability.steps:
						if step.running:
							parts.append("%s %d" % [step.name, step.step_ticks])
					running.append("%s: %s" % [ability.name, ", ".join(parts)])
				else:
					running.append("%s%s (%d)" % [ability.name, ": " + " + ".join(steps_now) if not steps_now.is_empty() else "", ability.ticks_left()])
			elif ability.cooldown_ticks_left() > 0:
				cooling.append("%s (%d)" % [ability.name, ability.cooldown_ticks_left()])
		lines.append("  running: %s" % (", ".join(running) if not running.is_empty() else "-"))
		lines.append("  cooling down: %s" % (", ".join(cooling) if not cooling.is_empty() else "-"))
		if not to_check.is_empty(): # settings not from a definition file: a prototype tweak, or a definition of the wrong kind
			lines.append("  definitions to check: %s" % ", ".join(to_check))
	if pawn.effect_manager:
		var effects := PackedStringArray()
		for entry: Dictionary in pawn.effect_manager.get_active_effects():
			var effect: Effect = entry.effect
			effects.append("%s x%d (%d)" % [String(effect.effect_name) if effect else "?", entry.stacks, entry.ticks_left])
		lines.append("  effects: %s" % (", ".join(effects) if not effects.is_empty() else "-"))
	if pawn.ai_context:
		var behaviour: AIBehaviourBase = pawn.ai_context.behaviour_manager.get_running_behaviour() if pawn.ai_context.behaviour_manager else null
		var target: Node3D = pawn.ai_context.target_selector.get_current_target() if pawn.ai_context.target_selector else null
		lines.append("  AI: state %s, behaviour %s, target %s" % [pawn.ai_context.current_state_name(), String(behaviour.name) if behaviour else "-",
			String(target.name) if is_instance_valid(target) else "-"])
	return "\n".join(lines)


func _log_text() -> String:
	var all: Array = manager.get_log_lines()
	var lines := PackedStringArray(["F8 log: %d kinds of warning or error (the newest kinds last)" % all.size()])
	for line: Array in all.slice(maxi(all.size() - 10, 0)):
		lines.append("[%s] x%d %s" % [line[0], line[3], String(line[1]).left(120)])
	return "\n".join(lines)
