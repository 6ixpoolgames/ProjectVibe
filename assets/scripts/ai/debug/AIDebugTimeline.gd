## Written by Claude (claude-opus-5-5), 2026-11-09: a view-only rewind for watching the AI, the owner's request: "I mainly want to
## scrub through what states and abilities are being called by the AI to see if there is unintended behaviour." Debug code for
## samples, like AbilityDebugDraw; nothing in the base uses it.
##
## While the game runs, it records every tick, for each pawn it watches: where it stood, which way it faced, and a line of text (the
## sample's readout: state, behaviour, target, last ability, Health). It also writes down events as they happen, from the base's own
## signals: state changes, behaviour changes, target changes, abilities started and cancelled, hits taken and deaths, each with its
## tick. It keeps the last seconds_kept seconds.
##
## Paused, step_view() moves what's shown back and forward through that recording: a ghost and a label for each pawn where it was on
## that tick, and a list of the events up to it. Nothing is simulated again and nothing in the game changes: when the game runs on,
## it carries on from the real present. That's the standard debug timeline (Unreal's Rewind Debugger works the same way); a real
## rewind would need the AI's whole state saved every tick, which rollback doesn't keep (scaling discussion, 2026-11-09).
##
## How to use it (ArenaSample does):
##   var timeline := AIDebugTimeline.new()
##   timeline.describe = func(pawn: Pawn) -> String: return "..."   # the text recorded for each pawn each tick
##   add_child(timeline)
##   timeline.watch(pawn)                  # for each pawn to record
##   timeline.step_view(-1)                # while paused: one tick back; +1 forward. Returns ticks it couldn't move (past the present)
##   timeline.view_present()               # back to now
class_name AIDebugTimeline
extends Node3D

## How much is kept, in seconds.
@export_range(1.0, 120.0, 0.5, "or_greater") var seconds_kept := 10.0
## How many ticks of events, before the tick being viewed, the list shows.
@export_range(1, 600, 1, "or_greater") var events_shown_ticks := 45

## Called for each watched pawn every tick: the text recorded for it. Empty: its name.
var describe: Callable

# GDScript note: untyped, because a freed pawn can't be held in (or taken out of) a typed array; freed ones are dropped below.
var _watched: Array = []
var _frames := {} # tick -> Array of [instance id, position, yaw, text]
var _events: Array = [] # [tick, text], oldest first
var _newest_tick := -1
var _viewed_tick := -1 # -1: the present
var _ghosts := {} # instance id -> [MeshInstance3D, Label3D]
var _panel: Label = null
var _connected := false


func _ready() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	_panel = Label.new()
	# GDScript note: anchored to the bottom left corner, and growing upwards as lines are added.
	_panel.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_LEFT)
	_panel.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_panel.offset_left = 14.0
	_panel.offset_bottom = -14.0
	_panel.add_theme_font_size_override(&"font_size", 15)
	_panel.add_theme_constant_override(&"outline_size", 5)
	_panel.add_theme_color_override(&"font_outline_color", Color.BLACK)
	_panel.hide()
	layer.add_child(_panel)


## Records this pawn from now on, and its events.
func watch(pawn: Pawn) -> void:
	if pawn == null or _watched.has(pawn):
		return
	_watched.append(pawn)
	if not _connected:
		_connected = true
		TickDriver.after_tick.connect(_record)
	var who := String(pawn.name)
	if pawn.ai_state_manager:
		pawn.ai_state_manager.state_changed.connect(func(old: AIStateBase, new: AIStateBase, reason: String) -> void:
			_event("%s: state %s → %s (%s)" % [who, _name_of(old), _name_of(new), reason]))
	if pawn.ai_behaviour_manager:
		pawn.ai_behaviour_manager.behaviour_changed.connect(func(old: AIBehaviourBase, new: AIBehaviourBase, reason: String) -> void:
			_event("%s: behaviour %s → %s (%s)" % [who, _name_of(old), _name_of(new), reason]))
	if pawn.ai_target_selector:
		pawn.ai_target_selector.target_changed.connect(func(old: Node3D, new: Node3D, reason: String) -> void:
			_event("%s: target %s → %s (%s)" % [who, _name_of(old), _name_of(new), reason]))
	if pawn.ability_manager:
		pawn.ability_manager.ability_started.connect(func(ability: AbilityBase) -> void:
			_event("%s: ability %s started" % [who, ability.name]))
		pawn.ability_manager.ability_cancelled.connect(func(ability: AbilityBase, by: AbilityBase) -> void:
			_event("%s: ability %s cancelled by %s" % [who, ability.name, _name_of(by)]))
	pawn.hit_received.connect(func(hit: HitInfo) -> void:
		_event("%s: hit by %s (%d)" % [who, _name_of(hit.attacker), int(hit.damage_dealt)])) # Claude 2026-11-10: damage_dealt, after the hit's effects
	pawn.died.connect(func(_pawn: Pawn, _hit: HitInfo) -> void: _event("%s: died" % who))


## True while showing a tick before the present.
func is_viewing_past() -> bool:
	return _viewed_tick >= 0


## The tick being shown: the past one, or the newest recorded.
func get_viewed_tick() -> int:
	return _viewed_tick if _viewed_tick >= 0 else _newest_tick


## Moves what's shown by this many ticks (negative: back), within what's recorded. Returns the ticks it couldn't move forward because
## it reached the present, so a caller can simulate those for real.
func step_view(ticks: int) -> int:
	if _newest_tick < 0:
		return ticks if ticks > 0 else 0
	var oldest := _oldest_tick()
	var from := get_viewed_tick()
	var to := clampi(from + ticks, oldest, _newest_tick)
	var left := maxi(0, from + ticks - _newest_tick)
	_viewed_tick = -1 if to == _newest_tick else to
	_show()
	return left


## Back to the present: the ghosts go, and the live readouts are the ones to read.
func view_present() -> void:
	_viewed_tick = -1
	_show()


## Shows or hides the event list. The sample shows it while paused.
func show_panel(on: bool) -> void:
	_panel.visible = on
	if on:
		_show()


# --- Recording ---


func _record(_dt: float, tick: int) -> void:
	var frame := []
	var alive := []
	for pawn in _watched:
		if not is_instance_valid(pawn):
			continue
		alive.append(pawn)
		var text: String = describe.call(pawn) if describe.is_valid() else String(pawn.name)
		frame.append([pawn.get_instance_id(), pawn.global_position, pawn.yaw, "%s\n%s" % [pawn.name, text]])
	_watched = alive
	_frames[tick] = frame
	_newest_tick = tick
	# Forget what's older than seconds_kept.
	var oldest := tick - int(seconds_kept * TickDriver.get_tick_rate())
	for kept_tick in _frames.keys():
		if kept_tick < oldest:
			_frames.erase(kept_tick)
	while not _events.is_empty() and _events[0][0] < oldest:
		_events.pop_front()


func _event(text: String) -> void:
	_events.append([TickDriver.tick, text])


func _oldest_tick() -> int:
	var oldest := _newest_tick
	for kept_tick in _frames:
		oldest = mini(oldest, kept_tick)
	return oldest


static func _name_of(thing: Object) -> String:
	return String(thing.name) if is_instance_valid(thing) and thing is Node else "—"


# --- Showing ---


func _show() -> void:
	var tick := get_viewed_tick()
	var frame: Array = _frames.get(tick, []) if is_viewing_past() else []
	var seen := {}
	for entry: Array in frame:
		var id: int = entry[0]
		seen[id] = true
		var ghost: Array = _ghosts.get(id, [])
		if ghost.is_empty():
			ghost = _make_ghost()
			_ghosts[id] = ghost
		var body: MeshInstance3D = ghost[0]
		var label: Label3D = ghost[1]
		body.global_position = entry[1] + Vector3(0, 0.9, 0)
		body.rotation.y = entry[2]
		label.global_position = entry[1] + Vector3(0, 2.6, 0)
		label.text = entry[3]
		body.show()
		label.show()
	for id in _ghosts:
		if not seen.has(id):
			_ghosts[id][0].hide()
			_ghosts[id][1].hide()
	if _panel.visible:
		_panel.text = _panel_text(tick)


func _make_ghost() -> Array:
	var body := MeshInstance3D.new()
	var capsule := CapsuleMesh.new()
	capsule.radius = 0.4
	capsule.height = 1.8
	body.mesh = capsule
	var material := StandardMaterial3D.new()
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.albedo_color = Color(0.6, 0.85, 1.0, 0.35)
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	body.material_override = material
	add_child(body)
	# Claude 2026-11-10: the same facing marker as the pawn's (pawn.tscn), so the ghost shows which way the pawn faced then. It's a
	# child of the capsule, so it turns with it; the capsule's middle is 0.9 m up, so the marker's 1.45 m is 0.55 above that.
	var facing := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(0.5, 0.12, 0.3)
	facing.mesh = box
	var facing_material := material.duplicate() as StandardMaterial3D
	facing_material.albedo_color = Color(1.0, 0.9, 0.4, 0.6)
	facing.material_override = facing_material
	facing.position = Vector3(0.0, 0.55, -0.32)
	body.add_child(facing)
	var label := Label3D.new()
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.no_depth_test = true
	label.font_size = 48
	label.outline_size = 12
	label.pixel_size = 0.005
	label.modulate = Color(0.7, 0.9, 1.0)
	add_child(label)
	return [body, label]


func _panel_text(tick: int) -> String:
	var rate := TickDriver.get_tick_rate()
	var lines := PackedStringArray()
	var behind := _newest_tick - tick
	lines.append("PAUSED   tick %d%s   ←/→ one tick, Shift ten, P to play on" % [tick, "   (%d ticks, %.2f s ago)" % [behind, float(behind) / rate] if behind > 0 else "   (now)"])
	lines.append("kept: the last %.0f s" % seconds_kept)
	var shown := 0
	for event: Array in _events:
		if event[0] > tick or event[0] < tick - events_shown_ticks:
			continue
		lines.append("%s %d  %s" % ["▶" if event[0] == tick else " ", event[0], event[1]])
		shown += 1
	if shown == 0:
		lines.append("(no events in the %d ticks up to this one)" % events_shown_ticks)
	# Keep the list to its last 16 lines.
	while lines.size() > 18:
		lines.remove_at(2)
	return "\n".join(lines)
