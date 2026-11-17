# Written by Claude (claude-opus-5-5), 2026-11-10. History: spawning/CHANGELOG.md.
## A place where pawns can appear, like Unreal's PlayerStart.
##
## Put one in a level, move and turn it in the editor, and SpawnManager (a GameMode module) uses it; it never spawns anything itself.
## A pawn appearing here faces the way the point faces (-Z, the blue arrow's opposite) and, on terrain, is put on the ground; without
## terrain it appears at the point's height, so place the point on the floor. Every SpawnPoint is in the Godot group [constant GROUP]
## while in the tree, so one added or removed while the game runs counts at once.
## Design: pawn spec 8.9.
class_name SpawnPoint
extends Node3D

## The Godot group every SpawnPoint is in while it's in the tree.
const GROUP := &"spawn_points"

## Who may appear here: a team number, or -1 for anyone.
@export var team := -1
## Which set of points this belongs to. Empty: none.
@export var group: StringName = &""
## How far from the point a pawn may appear, in metres.
@export_range(0.0, 50.0, 0.1, "or_greater") var scatter_radius := 1.0
## Off: skipped.
@export var enabled := true


func _enter_tree() -> void:
	add_to_group(GROUP)


func _exit_tree() -> void:
	remove_from_group(GROUP)


## True if a pawn of this team, asked for with this group (or with &"" for any group), may appear here.
func accepts(pawn_team: int, wanted_group: StringName) -> bool:
	return enabled and (team < 0 or team == pawn_team) and (wanted_group == &"" or group == wanted_group)


## Which way a pawn appearing here faces, as a pawn's yaw: the point's own turn about the up axis.
func get_yaw() -> float:
	return global_basis.get_euler().y
