## Written by Claude (claude-opus-5-5), 2026-11-04: on-screen readout and debug keys for the tick driver sample scene.
## Keys: P pause/resume ticking, T cycle tick rate (physics rate / 20 / 10), V toggle visual smoothing.
extends Label

const RATES := [0, 20, 10] # 0 = the project's physics rate

var _rate_index := 0
var _smooth := true


func _process(_delta: float) -> void:
	var nt = get_node_or_null("/root/TickDriver")
	if nt == null:
		text = "No TickDriver autoload: pawns tick from _physics_process"
		return
	var player := _find_player()
	var speed := ""
	if player:
		speed = "%.2f m/s" % Vector2(player.velocity.x, player.velocity.z).length()
	text = "Tick %d   rate %d/s   %s   participants %d   dropped %d\nPlayer speed %s   smoothing %s\n\nWASD move, Shift sprint, Space jump\nP pause   T tick rate   V smoothing" % [
		nt.tick, nt.get_tick_rate(), "running" if nt.active else "PAUSED",
		nt.get_participant_count(), nt.dropped_ticks, speed, "on" if _smooth else "off"]


func _unhandled_input(event: InputEvent) -> void:
	var nt = get_node_or_null("/root/TickDriver")
	if nt == null or not (event is InputEventKey) or not event.pressed or event.echo:
		return
	match event.keycode:
		KEY_P:
			nt.active = not nt.active
		KEY_T:
			_rate_index = (_rate_index + 1) % RATES.size()
			nt.tick_rate = RATES[_rate_index]
		KEY_V:
			_smooth = not _smooth
			for p in get_tree().get_nodes_in_group(&"tick_sample_pawns"):
				p.smooth_visuals = _smooth


func _find_player() -> TickSamplePawn:
	for p in get_tree().get_nodes_in_group(&"tick_sample_pawns"):
		if p is TickSamplePawn and p.brain == TickSamplePawn.Brain.PLAYER:
			return p
	return null
