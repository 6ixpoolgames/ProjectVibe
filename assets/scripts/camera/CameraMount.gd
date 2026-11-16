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


# --- Finding a pawn's camera pieces ---
# Claude 2026-11-16 (wider audit): moved here from Pawn (get_camera_mount, get_camera_preset, get_camera_arm, get_default_view), which
# only the PlayerController used. GDScript note: static functions belong to the class, so they're called as CameraMount.arm_of(pawn),
# with no CameraMount node needed.


## Where a player's arm attaches on this pawn: the CameraMount under its Visual if the scene has one, else its Visual itself.
static func mount_of(pawn: Pawn) -> Node3D:
	for child in pawn.get_visual().get_children():
		if child is CameraMount:
			return child
	return pawn.get_visual()


## The arm's settings for this pawn: its CameraMount's preset, or null for the defaults.
static func preset_of(pawn: Pawn) -> CameraPreset:
	var mount := mount_of(pawn) as CameraMount
	return mount.preset if mount else null


## This pawn's arm, or null: one placed in its scene, or the player's while they have it. Looked for on its Visual and its mount.
static func arm_of(pawn: Pawn) -> CameraArm:
	for parent: Node in [pawn.get_visual(), mount_of(pawn)]:
		for child in parent.get_children():
			if child is CameraArm:
				return child
	return null


## The view a camera should attach to when this pawn is possessed: its arm's, or else the first VirtualCamera in its scene, or null.
static func view_of(pawn: Pawn) -> VirtualCamera:
	var arm := arm_of(pawn)
	if arm:
		return arm.get_view()
	return _first_view_under(pawn)


static func _first_view_under(node: Node) -> VirtualCamera:
	for child in node.get_children():
		if child is VirtualCamera:
			return child
		var found := _first_view_under(child)
		if found:
			return found
	return null
