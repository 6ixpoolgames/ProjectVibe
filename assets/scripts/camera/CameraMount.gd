## Written by Claude (claude-opus-5-5), 2026-11-16 (pawn M5, the owner's call: one camera per player, owned by the PlayerController): where
## a player's camera arm attaches to a pawn, and with what settings. A plain marker a pawn's scene places under its Visual node. It does
## nothing itself: the PlayerController moves its one arm here when it takes the pawn, and applies this preset.
##
## A pawn without one gets the arm on its Visual node, with the default settings (CameraPreset's). A pawn whose scene places its own
## CameraArm, or a VirtualCamera of its own (at the eyes, say), uses that instead, and no mount is needed.
##
## How to use it: add a CameraMount under the pawn scene's Visual node, and give it a CameraPreset (arm length, height, field of view).
## Its position is ignored: the preset's mount_height and shoulder_offset place the arm.
class_name CameraMount
extends Node3D

## The arm's settings for this pawn. Empty means the defaults.
@export var preset: CameraPreset
