## Written by Claude (claude-opus-5-5), 2026-11-07: the list of named actions a game uses, such as jump, sprint and primary. Pawn spec
## section 5. InputActions reads this, and gives each action a bit in the order it's listed, so every machine in a multiplayer game
## agrees on them.
##
## To add an action, add its name to the end of the list. Adding it in the middle works too, but it moves the bits of everything after
## it, which only matters if something saved a bit mask to a file.
extends Resource
class_name InputActionsRes

## One name per action. Players press these through the key map on PlayerController, and AI presses them through AIController.
@export var actions: Array[StringName] = []
