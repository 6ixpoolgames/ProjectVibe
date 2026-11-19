# Written by Claude (claude-opus-5-5), 2026-11-19. History: streaming/CHANGELOG.md.
## A pawn's streaming source: keeps the world loaded around its pawn while a player has it, or always with
## [member keeps_world_loaded] on (a hero).
##
## Every pawn gets one from the game's default parts (the PawnInitializer). It's in [constant StreamingSource.GROUP] only while it
## might count, so the chunk streamer, the nav feeder and replay look through the few pawns that matter, not the whole army. Its
## distances are the game's ([member PawnDefaultsRes.world_load_distance] and [member PawnDefaultsRes.world_nav_distance]), the same
## for every pawn: 320 and 128 m without them, and its own settings are hidden. The AI switch-off leaves a pawn on while this counts
## ([method Pawn.is_keeping_world_loaded]).
class_name PawnStreamingSource
extends StreamingSource

## On: it keeps the world loaded around its pawn even without a player (a hero, say). Off (the default), only while a player has
## the pawn; a horde pawn freezes where nothing else keeps the ground loaded.
@export var keeps_world_loaded := false:
	set(value):
		keeps_world_loaded = value
		_update_group()

## The pawn this is a part of, or null outside a pawn (then it never counts).
var pawn: Pawn = null


func _enter_tree() -> void:
	pawn = get_parent() as Pawn
	if pawn and not is_instance_valid(pawn.streaming_source):
		pawn.streaming_source = self # the first one a pawn has is the one it uses
	elif pawn == null:
		push_warning("PawnStreamingSource: its parent isn't a Pawn, so it never keeps anything loaded.")


func _ready() -> void:
	# A player taking or leaving the pawn changes whether it might count. unbind(2) drops the signal's two arguments.
	if pawn and pawn.controller_manager:
		pawn.controller_manager.possession_changed.connect(_update_group.unbind(2))
	_update_group()


## Whether it keeps the world loaded on this machine now: a player has the pawn or [member keeps_world_loaded] is on, and the pawn is
## simulated here (another player's pawn on a client doesn't count there).
func counts_on_this_machine() -> bool:
	return _might_count() and super()


# Also asked from the base class's _init, before this has a pawn: false then, and _ready works it out again.
func _might_count() -> bool:
	return active and pawn != null and (keeps_world_loaded or (pawn.controller_manager != null and pawn.controller_manager.has_player()))


func _distance_in_use(_own: float, for_nav: bool) -> float:
	var game_mode := get_node_or_null(^"/root/GameMode") as GameModeSingleton if is_inside_tree() else null
	var initializer: PawnInitializer = game_mode.pawn_initializer if game_mode else null
	var defaults: PawnDefaultsRes = initializer.defaults if initializer else null
	if defaults == null:
		return 128.0 if for_nav else 320.0
	return defaults.world_nav_distance if for_nav else defaults.world_load_distance


# The game's distances are used, so its own are left out of the inspector.
func _validate_property(property: Dictionary) -> void:
	if property.name == "load_distance" or property.name == "nav_distance":
		property.usage = PROPERTY_USAGE_NO_EDITOR
