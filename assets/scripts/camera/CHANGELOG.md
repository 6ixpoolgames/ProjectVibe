<!-- Written by Claude (claude-opus-5-5), 2026-11-17: the camera system's running changelog. History leaves the code comments and lives
here, next to the code. Newest first. -->

# Camera changelog

The camera system is this folder: `PlayerCamera`, `VirtualCamera`, `CameraArm`, `CameraPreset`, `CameraMount` and `FreeFlyCamera`. The `PlayerController` (`player/`) owns and drives them. Design: [docs/pawn/PLAYER_AND_CAMERA.md](../../../docs/pawn/PLAYER_AND_CAMERA.md) and [docs/pawn/PAWN_SPEC.md](../../../docs/pawn/PAWN_SPEC.md) section 8.18. Overview: [README.md](README.md).

## Refactor candidates

None found in the documentation pass.

## 2026-11-17

- **Comments cleaned up** for the documentation pass: dated notes moved here, doc comments in Godot's markup.

## 2026-11-16

- **One camera per player** (pawn M5, the owner's call, pawn spec 8.18): `CameraMount`, a marker under a pawn's Visual with its `CameraPreset`, where the player's one arm attaches. `CameraArm.apply_preset()` (was the body of `_ready`) and `clear_ignored()` let one arm move between pawns; `spawned_by_possession` is gone.
- **Finding camera pieces** (the wider audit): `CameraMount.arm_of`, `mount_of`, `preset_of` and `view_of` moved here from Pawn, which only the PlayerController used.
- **`FreeFlyCamera`, the spectator** (the owner's request): local and per frame, not a Pawn, with its own StreamingSource (`keeps_world_loaded`, which can change while flying). The owner's numbers: 10 m/s, 25 with sprint, the wheel with sprint ramps up to 75. Space and Ctrl fly up and down (the owner's call; it was Q and E). The wheel alone zooms by narrowing the field of view (`zoom_per_notch`, `max_zoom`), reset by the middle mouse button and on each start; `teleport()` for overview points.

## 2026-11-08

- The old `PlayerCamera3D` and `FreeFloatingCameraController` moved to `assets/legacy/camera/`.

## 2026-11-07

- **The camera pieces** (PLAYER_AND_CAMERA.md): `PlayerCamera`, the one real camera, following a `VirtualCamera`; `CameraArm`, a spring arm idle unless a player looks through it; `CameraPreset`, its settings as a shareable resource.
