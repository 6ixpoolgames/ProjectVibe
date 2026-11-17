<!-- Written by Claude (claude-opus-5-5), 2026-11-17: the camera system's overview, beside its code. -->

# Camera

What the player sees through: one real camera that follows a placed view, a spring arm that holds that view behind a pawn, and a free-flying camera for spectating.

**Status:** built, tier 0. Not yet: camera blends, cutscene cameras and more than one camera per player.

| File | What it's for |
|---|---|
| [README.md](README.md) | This overview |
| [REFERENCE.md](REFERENCE.md) | Every class, setting and function, generated from the code's doc comments (`python tools/docs/make_reference.py camera`) |
| [CHANGELOG.md](CHANGELOG.md) | What changed and why, newest first |
| [PLAYER_AND_CAMERA.md](../../../docs/pawn/PLAYER_AND_CAMERA.md) | The design |

## The pieces

```
 PlayerController (player/) ─ PlayerCamera ──follows──► VirtualCamera
                            └ CameraArm (one per player) ─ VirtualCamera      on a pawn's CameraMount, with its CameraPreset
                            └ FreeFlyCamera ─ View (VirtualCamera)            while spectating
```

- **`PlayerCamera`**: the one real camera. It copies a view's place each frame, so a freed pawn can't take it along.
- **`VirtualCamera`**: a place for the camera to be. Costs nothing.
- **`CameraArm`**: holds a view out behind a pawn and pulls it in at walls (a spring arm). The player's one arm moves to each pawn they take.
- **`CameraMount`** and **`CameraPreset`**: where the arm attaches on a pawn, and its settings (length, height, pitch range, field of view).
- **`FreeFlyCamera`**: the spectator, flown with the player's keys; local only, goes through walls.

## How to use it

**Give a pawn type its own camera feel.** Add a `CameraMount` under the pawn scene's `Visual` and give it a `CameraPreset`. An arm length of 0 is first person.

**A fixed view, such as at the eyes.** Put a `VirtualCamera` in the pawn scene; it's used instead of the arm.

## Settings worth knowing

| Setting | Where | Default | What it does |
|---|---|---|---|
| `arm_length`, `min_length`, `max_length` | `CameraPreset` | 6, 1.5, 16 m | How far out the camera sits, and the wheel's range |
| `mount_height`, `shoulder_offset` | `CameraPreset` | 1.5, 0 m | Where the arm starts on the pawn |
| `fov` | `CameraPreset` | 75° | Field of view |
| `collision_mask` | `CameraPreset` | 1 (ground) | What pulls the camera in |
| `speed`, `fast_speed` | `FreeFlyCamera` | 10, 25 m/s | Spectator flying speeds |

## How it works

- **The spectator** (`FreeFlyCamera`) isn't a Pawn: a Pawn is simulated on ticks, rolled back, networked, recorded in replays, counted on a team and seen by the AI, and a spectator needs none of that. Like Unreal's, it's local and moves per rendered frame, and carries a `VirtualCamera` (View) and a `StreamingSource` that keeps the world loaded around it (`keeps_world_loaded`; on a client it loads only that client's world). There's no collision.
- **Spectator controls** (read by the PlayerController): WASD flies where the view looks; Space and Ctrl go straight up and down (`fly_up_key`, `fly_down_key`); the mouse looks. 10 m/s, 25 with sprint held; with sprint held the wheel ramps the fast speed up or down to 75; on its own the wheel zooms by narrowing the field of view (the mouse turns slower to match), and the middle button resets it.
- **The camera arm** does one physics query a frame outside the physics step, which is safe while physics doesn't run on its own thread (Godot's default); a project that turns that on would have to move it.

## Tests

No tests of its own; `pawn/tests/possession_selftest` covers the arm moving between pawns and spectating.
