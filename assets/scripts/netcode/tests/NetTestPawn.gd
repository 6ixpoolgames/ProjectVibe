## Written by Claude (claude-opus-5-5), 2026-11-04: a pawn driven by a script instead of keys, for testing multiplayer.
## Everything else about it is NetSamplePawn. The script's choices depend only on the tick, so runs are repeatable.
## Modes (set on the static default_mode before connecting):
##   seek     walks toward the arena's middle with a random new direction every 10 ticks, so pawns keep bumping
##   strafe   walks back and forth along Z in a straight line, a steady target
##   shoot    stands still and fires at the first other pawn where it's drawn, every 30 ticks
##   lead     the same, but aims ahead of where it's drawn, by a fixed distance. Used to check attacks behave past the rewind cap
##   idle     does nothing
extends NetSamplePawn
class_name NetTestPawn

static var default_mode: String = "seek"
static var lead_seconds: float = 0.0

var mode: String = "idle"
var _local := false
var _key := 0


func _on_network_role(entity: NetworkEntity) -> void:
	_local = entity.is_local
	mode = default_mode if _local else "idle"
	_key = entity.entity_id
	brain = Brain.NETWORK # the keyboard and the wander brain stay out of it


func _tick_input(dt: float, tick: int) -> void:
	super(dt, tick)
	if not _local:
		return
	wants_sprint = false
	wants_jump = false
	wants_attack = false
	match mode:
		"seek":
			_seek(tick)
		"strafe":
			var going_up := (tick / 120) % 2 == 0
			move_dir = Vector3(0, 0, 1.0 if going_up else -1.0)
		"shoot", "lead":
			move_dir = Vector3.ZERO
			_shoot(tick)
		_:
			move_dir = Vector3.ZERO


func _seek(tick: int) -> void:
	var change := RandomNumberGenerator.new()
	change.seed = hash(Vector2i(tick / 10, _key))
	var angle := change.randf() * TAU
	var to_middle := -position
	to_middle.y = 0.0
	var toward: Vector3 = to_middle.normalized() if to_middle.length_squared() > 0.01 else Vector3.ZERO
	move_dir = (toward * 0.7 + Vector3(cos(angle), 0.0, sin(angle))).normalized()
	wants_sprint = change.randf() > 0.7
	wants_jump = tick % 91 == _key % 91


func _shoot(tick: int) -> void:
	if _entity == null or _entity.session == null:
		return
	for other: NetworkEntity in _entity.session.get_entities():
		if other == _entity:
			continue
		var target: Node3D = other.get_parent()
		var aim_at := target.global_position + Vector3(0, 0.9, 0)
		if mode == "lead" and "velocity" in target:
			aim_at += target.velocity * lead_seconds
		aim_dir = (aim_at - (global_position + Vector3(0, 1.4, 0))).normalized()
		view_ticks_behind = _session_view_ticks_behind()
		wants_attack = tick % 30 == 0 and _entity.session.render_tick >= 0.0
		return
