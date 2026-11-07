## Written by Claude (claude-opus-5-5), 2026-11-07: a place for the real camera to be. Put one where the view should be, such as on a
## CameraArm or at a pawn's eyes, and PlayerCamera follows it. It does nothing itself, so having one costs nothing.
class_name VirtualCamera
extends Node3D

## The field of view while the camera is here, in degrees.
@export_range(1.0, 179.0, 0.1) var fov := 75.0
