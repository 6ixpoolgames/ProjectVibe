## Written by Claude (claude-opus-5-5), 2026-11-03: configures NavServer and drives its tick (spec 6, 16A).
## Lives in the nav test scene for now. Becomes an autoload once the nav system is used by real scenes;
## kept out of project.godot until then so a missing/unbuilt DLL can't break the main scene.
extends Node

@export var config := {} ## overrides for NavServer.configure, keys as in nav_types.h NavConfig
@export var interest_target: Node3D ## nav is built around this node (if it has get_focus(), that point)
@export var load_radius := 70.0
@export var unload_radius := 90.0
@export var stats_label: Label

var _interest := -1
var _stats_timer := 0.0


func _ready() -> void:
	NavServer.configure(config)
	_interest = NavServer.add_interest(_target_position(), load_radius, unload_radius, 1)


func _exit_tree() -> void:
	if _interest >= 0:
		NavServer.remove_interest(_interest)


func _physics_process(delta: float) -> void:
	NavServer.move_interest(_interest, _target_position())
	NavServer.tick(delta)


func _process(delta: float) -> void:
	_stats_timer += delta
	if stats_label and _stats_timer > 0.25:
		_stats_timer = 0.0
		var s: Dictionary = NavServer.get_stats()
		stats_label.text = "tiles %d   ready %d  building %d  queued %d  dirty %d  provisional %d\n" % [
			s.tiles, s.ready, s.building, s.queued, s.dirty, s.provisional] \
			+ "builds %d (stale %d)  avg %.2f ms  max %.2f ms   commit max %.2f ms   tick %.2f ms (max %.2f)" % [
			s.builds_committed, s.builds_stale, s.avg_build_ms, s.max_build_ms, s.max_commit_ms, s.last_tick_ms, s.max_tick_ms]


func _target_position() -> Vector3:
	if interest_target == null:
		return Vector3.ZERO
	if interest_target.has_method("get_focus"):
		return interest_target.get_focus()
	return interest_target.global_position
