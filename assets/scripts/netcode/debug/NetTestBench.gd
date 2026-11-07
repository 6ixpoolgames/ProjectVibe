## Written by Claude (claude-opus-5-5), 2026-11-04: on-screen controls for testing multiplayer at its worst (netcode spec section 16).
## Add this to a scene to change the fake network and switch features on and off while playing. Debug builds only: in a
## release build it removes itself, because a real game must not let a client change these.
##
## Keys:
##   [ ]      ping down / up by 10 ms          - =      jitter down / up by 5 ms
##   , .      loss down / up by 1%             ; '      how much jitter wanders, down / up
##   B        a 1 s burst of lost packets      N        a 1 s lag spike of 300 ms
##   F1-F5    presets: off, good, wifi, mobile, worst
##   1-9, 0   switch a feature on or off, listed on screen
##   H        hide or show this panel
##
## Ping is split evenly between sending and receiving, so one window sets its whole connection. Switches for things the server
## decides, like lag compensation, are sent to the server, which only obeys if allow_debug_commands is on there. On a client,
## those lines show what the server says, so if it refuses, the panel stays as it was.
extends CanvasLayer
class_name NetTestBench

const PRESET_KEYS := {KEY_F1: "off", KEY_F2: "good", KEY_F3: "wifi", KEY_F4: "mobile", KEY_F5: "worst"}
const FEATURE_KEYS := [KEY_1, KEY_2, KEY_3, KEY_4, KEY_5, KEY_6, KEY_7, KEY_8, KEY_9, KEY_0]
const PING_STEP := 10.0
const JITTER_STEP := 5.0
const LOSS_STEP := 0.01
const VARIATION_STEP := 0.1

var session: NetworkSessionSingleton = null
var _debug: NetDebugModule = null # Claude 2026-11-07: the fake network and the switches moved here from the session
var preset_name: String = "off"
var _panel: Label = null
var _ping_ms := 0.0
var _jitter_ms := 0.0


func _ready() -> void:
	if not OS.is_debug_build():
		queue_free()
		return
	session = get_node_or_null("/root/NetworkSession")
	if session:
		_debug = NetDebugModule.on(session)
	_panel = Label.new()
	_panel.position = Vector2(12, 265)
	add_child(_panel)


func _process(_delta: float) -> void:
	if _panel and _panel.visible and session:
		_panel.text = status_text()


func _unhandled_key_input(event: InputEvent) -> void:
	var key := event as InputEventKey
	if key and key.pressed and not key.echo:
		handle_key(key.keycode)


## Does what a key does. True if the key meant something here.
func handle_key(keycode: int) -> bool:
	if session == null:
		return false
	var now := Time.get_ticks_usec()
	match keycode:
		KEY_BRACKETLEFT:
			set_ping(_ping_ms - PING_STEP)
		KEY_BRACKETRIGHT:
			set_ping(_ping_ms + PING_STEP)
		KEY_MINUS:
			set_jitter(_jitter_ms - JITTER_STEP)
		KEY_EQUAL:
			set_jitter(_jitter_ms + JITTER_STEP)
		KEY_COMMA:
			set_loss(_debug.fake.loss * 2.0 - LOSS_STEP)
		KEY_PERIOD:
			set_loss(_debug.fake.loss * 2.0 + LOSS_STEP)
		KEY_SEMICOLON:
			set_variation(_debug.fake.jitter_variation - VARIATION_STEP)
		KEY_APOSTROPHE:
			set_variation(_debug.fake.jitter_variation + VARIATION_STEP)
		KEY_B:
			_debug.fake.start_burst(now, 1.0)
			_debug.fake_in.start_burst(now, 1.0)
		KEY_N:
			_debug.fake.start_spike(now, 1.0, 150.0)
			_debug.fake_in.start_spike(now, 1.0, 150.0)
		KEY_H:
			if _panel:
				_panel.visible = not _panel.visible
		_:
			if PRESET_KEYS.has(keycode):
				apply_preset(PRESET_KEYS[keycode])
			elif FEATURE_KEYS.has(keycode):
				toggle_feature(FEATURE_KEYS.find(keycode))
			else:
				return false
	return true


## The whole round trip in milliseconds, half each way.
func set_ping(milliseconds: float) -> void:
	_ping_ms = maxf(milliseconds, 0.0)
	_debug.fake.timeline = []
	_debug.fake_in.timeline = []
	_debug.fake.latency_ms = _ping_ms * 0.5
	_debug.fake_in.latency_ms = _ping_ms * 0.5


func set_jitter(milliseconds: float) -> void:
	_jitter_ms = maxf(milliseconds, 0.0)
	_debug.fake.jitter_ms = _jitter_ms * 0.5
	_debug.fake_in.jitter_ms = _jitter_ms * 0.5


## Chance of loss across the whole connection, split evenly.
func set_loss(chance: float) -> void:
	var clamped := clampf(chance, 0.0, 1.0)
	_debug.fake.loss = clamped * 0.5
	_debug.fake_in.loss = clamped * 0.5


func set_variation(amount: float) -> void:
	var clamped := clampf(amount, 0.0, 1.0)
	_debug.fake.jitter_variation = clamped
	_debug.fake_in.jitter_variation = clamped


func apply_preset(new_preset: String) -> void:
	preset_name = new_preset
	_debug.fake.apply_preset(new_preset)
	_debug.fake_in.apply_preset(new_preset)
	_ping_ms = _debug.fake.latency_ms * 2.0
	_jitter_ms = _debug.fake.jitter_ms * 2.0


## Switches the feature at this place in NetworkSession.FEATURES.
func toggle_feature(index: int) -> void:
	if index < 0 or index >= NetDebugModule.FEATURES.size():
		return
	var feature: String = NetDebugModule.FEATURES[index]
	_debug.set_feature(feature, not _debug.is_feature_on(feature))


func status_text() -> String:
	var lines := PackedStringArray()
	var now := Time.get_ticks_usec()
	var events := PackedStringArray()
	if _debug.fake.is_in_burst(now):
		events.append("BURST")
	if _debug.fake.is_in_spike(now):
		events.append("SPIKE")
	lines.append("fake network: %s, ping %.0f ms, jitter %.0f ms (now %.0f), loss %.0f%%, jitter wander %.0f%% %s" % [preset_name, _ping_ms, _jitter_ms, _debug.fake.get_current_jitter_ms() * 2.0, _debug.fake.loss * 200.0, _debug.fake.jitter_variation * 100.0, " ".join(events)])
	lines.append("[ ] ping   - = jitter   , . loss   ; ' wander   B burst   N spike   F1-F5 presets   H hide")
	var stats := session.stats
	lines.append("client: speed %.3f, input margin %d ticks, drawn %.1f ticks behind, late drawing %d, missed inputs %d, resyncs %d" % [session.get_tick_factor(), session.get_input_margin(), session.get_view_ticks_behind(), stats["interpolation_underruns"], session.get_missed_inputs(), stats["resyncs"]])
	for i in NetDebugModule.FEATURES.size():
		var feature: String = NetDebugModule.FEATURES[i]
		lines.append("%d  %s  %s" % [(i + 1) % 10, "ON " if _debug.is_feature_on(feature) else "off", feature])
	return "\n".join(lines)
