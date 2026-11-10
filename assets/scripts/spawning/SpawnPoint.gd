## Written by Claude (claude-opus-5-5), 2026-11-10: a place where pawns can appear. Put one in a level, move and turn it in the editor,
## and SpawnManager (a GameMode module) uses it. It never spawns anything itself: it's only a spot, like Unreal's PlayerStart.
##
## Settings:
##   team             who may appear here: a pawn team number, or -1 for anyone
##   group            a name for a set of points, such as &"red_base", so a PawnSpawner or a game can ask for "a point in group X".
##                    A request that names no group may use any point its team may use, in a group or not
##   scatter_radius   how far from the point, in metres, a pawn may appear, so several don't stack on one spot
##   enabled          off: it's skipped, as if it weren't there
##
## A pawn appearing here faces the way the point faces (its blue Z arrow points backwards, as everything in Godot does: a pawn looks
## along -Z). On terrain, the pawn goes on the ground under the spot it's given; without terrain, it appears at the point's height,
## so place the point on the floor.
##
## How SpawnManager finds points: every SpawnPoint in the tree is in the Godot group GROUP, joined when it enters the tree and left
## when it exits, so a point added or removed while the game runs counts at once.
class_name SpawnPoint
extends Node3D

## GDScript note: a Godot group is a name that nodes join. get_tree().get_nodes_in_group(GROUP) lists every node in it.
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
