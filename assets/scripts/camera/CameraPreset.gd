## Written by Claude (claude-opus-5-5), 2026-11-07: the settings for a CameraArm, as a resource a designer can make and share.
## A pawn type with its own feel gets its own preset. With none, a pawn uses these defaults, a third-person orbit.
## An arm length of 0 is first person.
class_name CameraPreset
extends Resource

## How long the arm starts, in metres.
@export var arm_length := 6.0
@export var min_length := 1.5
@export var max_length := 16.0
## How much one step of the mouse wheel changes the length.
@export var zoom_step := 0.75
## Where the arm starts, above the pawn's feet.
@export var mount_height := 1.5
## Sideways, for an over-the-shoulder view. Positive is to the right.
@export var shoulder_offset := 0.0
## How the view starts, in degrees. Negative is looking down.
@export_range(-89.0, 89.0, 0.5) var start_pitch := -20.0
@export_range(-89.0, 89.0, 0.5) var min_pitch := -70.0
@export_range(-89.0, 89.0, 0.5) var max_pitch := 50.0
## The field of view, in degrees.
@export_range(1.0, 179.0, 0.1) var fov := 75.0
## How thick the camera counts as when it's pulled in by walls, in metres.
@export var collision_radius := 0.2
## What the camera can't pass through. By default only the ground's layer, so that pawns don't shove the camera around.
@export_flags_3d_physics var collision_mask := 1
## How fast the camera moves back out after a wall or hill has pulled it in, in metres per second. It pulls in at once, so it
## never goes through anything, and comes back gently, so it doesn't snap around.
@export var return_speed := 8.0
