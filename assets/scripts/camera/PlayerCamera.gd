## Written by Claude (claude-opus-5-5), 2026-11-07: the one real camera, which follows a VirtualCamera. PlayerController owns it.
## This does what the old PlayerCamera3D's name suggests and nothing else. Possession and the 3D cursor live elsewhere now.
##
## It copies the view's position every rendered frame instead of being reparented onto it. So a pawn being freed can't take the
## camera with it, and if the view disappears, the camera just holds where it was.
##
## It leaves the scene's own camera alone until it's given a view.
class_name PlayerCamera
extends Camera3D

var _view: VirtualCamera = null


func _init() -> void:
	# After pawns have placed their Visual for this frame, and arms have placed their views.
	process_priority = 100
	# Nobody's looking until there's a view.
	current = false


## Starts following a view. Null stops following, and the camera holds where it is.
func set_view(view: VirtualCamera) -> void:
	_view = view
	if view != null:
		if is_inside_tree():
			make_current()
		_follow()


func get_view() -> VirtualCamera:
	return _view


func _process(_delta: float) -> void:
	_follow()


func _follow() -> void:
	# GDScript note: is_instance_valid is false for a freed object, which a plain null check wouldn't catch.
	if not is_instance_valid(_view):
		_view = null
		return
	if _view.is_inside_tree() and is_inside_tree():
		global_transform = _view.global_transform
		fov = _view.fov
