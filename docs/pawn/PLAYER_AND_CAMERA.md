<!-- Written by Claude (claude-opus-5-5), 2026-11-07: the tier -1 pawn, cameras, possession and game mode, as agreed with the owner on 2026-11-06 and 07. -->

# Player, Camera and Tier -1 Pawn

**Status:** tier -1 is built and tested, offline and over real connections on Windows and Linux. To play it, open `assets/scenes/samples/pawn_sample.tscn`. The layout is Unreal's gameplay framework, kept small: a controller that outlives pawns, pawns that can be possessed, and one real camera that attaches to virtual cameras.

**Where this stands against the pawn spec:** `docs/pawn/PAWN_ARCHITECTURE.md` still describes the full pawn. This replaces its controller placement: `PlayerController` is no longer a child of the pawn. "Tier -1" means only the motor and a placeholder controller, with no nexus, managers or abilities, so that cameras can be tested with nav and netcode. The old pawn, old camera and `test scene.tscn` are untouched.

**Rule:** legacy files are never modified. New systems get new names beside them, which is why this has `PlayerCamera` next to the old `PlayerCamera3D`, and `PossessionCoordinator` next to the old `PossessionManager.gd` stub.

## 1. Hierarchy

```
AUTOLOADS
├─ TickDriver, NetworkSession
├─ NavMarkerManager
└─ GameMode                        holds optional modules, does nothing itself
   ├─ PossessionCoordinator             creates the PlayerController, tracks who controls what
   │  └─ PlayerController          survives with no pawn; reads input, holds look direction
   │     ├─ PlayerCamera           the one real camera
   │     └─ WorldCursor            off by default
   └─ AIActivationManager             switches AI off where no source keeps the ground loaded

LEVEL
├─ Terrain                         the main terrain coordinator
│  ├─ ChunkStreamer                optional: without it, a fixed block
│  ├─ TerrainEditLog               optional: without it, edits don't outlast a chunk or reach clients
│  └─ TerrainBodyLifter            optional: moves bodies onto ground an edit raises above them
└─ Pawn                            possessable flag, velocity, the one move_and_slide
   ├─ GroundMovement               a placeholder until abilities exist
   ├─ StreamingSource              only when possessed, or when the AI bool is on
   └─ Visual                       the smoothed position, set each rendered frame
      ├─ Model
      └─ CameraArm + VirtualCamera only where the rules below say
```

## 2. Responsibilities

| Module | Responsible for | Not responsible for | Unreal equivalent |
|---|---|---|---|
| `GameMode` | Holding modules | Rules of its own | `GameMode` |
| `PossessionCoordinator` | Who controls which pawn, approving requests, announcing changes, creating the controller | Input, cameras | Part of `GameMode` |
| `PlayerController` | Reading input, look direction, passing input to its pawn | Moving anything | `PlayerController` |
| `PlayerCamera` | Following the current `VirtualCamera` | Input, cursor, possession | `PlayerCameraManager` |
| `VirtualCamera` | Being a position plus settings | Logic | `CameraComponent` |
| `CameraArm` | Length, zoom, collision, following the look direction | Reading input | `SpringArmComponent` |
| `CameraPreset` | Settings for an arm | Behaviour | None |
| `WorldCursor` | What the mouse or crosshair points at | What a click means | `GetHitResultUnderCursor` |
| `Pawn` | The `possessable` flag, input it's given, physics step, smoothed visual position | Reading devices | `APawn` |
| `GroundMovement` (placeholder) | Accelerating, turning, gravity, jump impulse, until Walk, Jump and the pawn take these over | Choosing where to go | Part of `CharacterMovementComponent` |
| `AIActivationManager` | Turning AI ticks off and on, with signals | Simulating AI out of sight | None |

## 3. Camera rules

- **One real camera.** It copies its `VirtualCamera`'s position every rendered frame. It isn't reparented, so a pawn being freed can't take the camera with it. If its view disappears, it holds where it was.
- **Most pawns have no arm.** In priority order:
  1. An arm placed in the pawn's scene is used.
  2. `always_has_camera_arm` on: the arm spawns with the pawn. This is for hero pawns, to rule out any delay on handoff.
  3. Otherwise possession spawns one from `camera_preset`, or from the defaults, and removes it on unpossess.
- **An arm with no player is idle.** It does no work per frame and reads no input.
- **Follows the smoothed model.** The arm sits under `Visual`, so corrections don't shake the view.
- **Runs per rendered frame.** The server never needs one, and a camera never changes game state.
- **Pulls in at once, comes back gently.** A hill or wall moves the camera in immediately, so it never goes through anything, and it eases back out at `return_speed`. Snapping both ways caused jumps of up to 5 m in a frame on hills.
- **Pawns don't move the camera.** `pawn.tscn` puts bodies on collision layer 2 and the ground is on layer 1, so an arm minds only the ground.

## 4. Movement

- **`Pawn` holds input as plain data:** `move_input`, `wants_jump`, `wants_sprint`, `look_yaw`, `look_pitch`. All of it goes in the input command, which keeps replays possible later.
- **For now, a placeholder module does the moving.** A pawn with no module stands still. The current direction, which is work in progress and open to better ideas, has no motor layer and no movement modules: locomotion abilities such as Walk and Fly write velocity, and the pawn makes the one `move_and_slide` call. See `PAWN_ARCHITECTURE.md` section 9.
- **Speeds are plain settings for now,** because there's no stat manager.
- **The controller is a placeholder.** The steering decision moves to a `Walk` ability when abilities exist.

## 5. Possession

- **Every request goes to `PossessionCoordinator`,** and the pawn's `possessable` flag is the check. This is the simplest version, chosen by the owner. `GameMode.possession_coordinator.possess(pawn)` asks on this machine, and `possess_for(peer, pawn)` is the server's own call. In multiplayer the server decides, and a client's call is only a request.
- A pawn with `possessable` off refuses. A pawn another player holds refuses.
- **`possessable` is on by default,** the owner's choice. Off would leave people with no idea why their pawn doesn't work. Something has to ask for a possession, so a wrong one is a clear bug that gets looked at.
- **`possessable` only stops new possessions.** Turning it off doesn't evict whoever has the pawn. `release_pawn(pawn)` is the separate call for that.
- **Tier 0 is for designers.** Protection against cheating and modified clients comes later, so requests have only the checks above.
- **AI uses the same system.** When there's an `AIController`, it asks `PossessionCoordinator` too. Not built.
- **A controller doesn't come with a pawn.** Creating a `PlayerController` spawns nothing, and neither does a player joining. A game spawns what it wants, when it wants. The samples and tests spawn a pawn per player only for their own convenience.
- A possessed pawn's `owner_peer` is its player. Letting go sets it to 0, so the server runs it.
- **What a pawn does once it's let go is the controller manager's job, which isn't built yet.** Its AI controller takes over at once if it has one, as in an autobattler where a player jumps into a unit and back out. With no AI controller, the pawn stands idle, which is what most games want. Tier -1 only does the idle half: the pawn's input is cleared, and it stands still until something else writes to it.
- Possession turns the pawn's `StreamingSource` on, spawns its arm if needed, and points the camera at its view.
- A possessed pawn being removed leaves the controller with no pawn, and the camera holding still.
- In multiplayer the server decides, and sends who has what to every client, including late joiners. A client's request can be refused.
- **Swapping mid-game** changes the entity's owner on every machine (`NetworkSession.set_entity_owner`). The new pawn was being drawn in the past on that client, so the first correction is up to about the distance it travelled in that time: measured 1.0 m at 50 ms and 1.8 m at 200 ms. It's faded on screen, and then error drops to about 0.
- **A player leaving only lets go.** Their possessed pawn stays in the world with no owner, the same as a release. If its ground unloads, `AIActivationManager` switches it off like any pawn with no player. Respawning or removing it belongs to the game, which can listen to `released`, then to `NetworkSession.player_left`.
- **Anything else a leaving player owns is removed,** as `NetworkSession` always has. That includes a pawn they own but don't possess. A game that wants to keep more can give those entities a new owner from `NetworkSession.player_leaving`, which fires before anything's removed.

## 6. World cursor

`WorldCursor` is a module of `PlayerController`, and costs nothing until asked.

- **One answer:** `query_now()`, such as on a click.
- **Watching:** `acquire(user, times_per_second)`, with the fastest rate winning across users. It stops when the last user calls `release`, or is freed, or leaves the scene.
- **With no camera** it answers with nothing. A captured mouse points at the middle of the screen, and a free one where it is.
- **Click-to-move** is a placeholder on `PlayerController` (`click_to_move`, `move_to`), walking a nav path until a key takes over. It moves to a navigation manager later.

## 7. Keeping replays possible

Replay isn't tier 0, but nothing here should prevent it:
1. Look direction goes in the input command.
2. Anything that changes the world reaches clients as a message with a tick number.
3. Network data refers to entities by id, never by node.
4. Cameras, HUDs and effects only read game state.
5. Packet handling doesn't rely on a live connection on the other end. `_on_packet` uses its peer to check the sender, so playback would pass the server's peer number. Not tried.

## 8. Measured

Windows, Godot 4.7.2, 2026-11-07. `net_stress`: 5 clients at 20 to 200 ms with 4 pawns each and 20 AI pawns, on streamed terrain, 30 seconds a run, one run of each. Each client possesses one pawn.

| | Real motor (`pawn_streamed`) | `NetTestPawn` (`terrain_streamed`) |
|---|---|---|
| Own pawn error, average across clients | 0.3 to 1.2 cm | 0.1 to 2.6 cm |
| Worst single error | 88 to 210 cm | 48 to 432 cm |
| Server frame, average / worst | 4.2 / 7 ms | 4.5 / 9 ms |
| Frames over budget | 0 | 0 |
| Server sends | 176 KB/s | 204 KB/s |
| Camera per frame, average / worst | 0.04 / 0.17 m | Not applicable |

These are the same within the noise between runs, except bandwidth, because the real pawn's state is smaller. The large single errors come from pawn contact (netcode spec, to-do 2).

- **Rollback:** replaying 20 ticks on hills with jumps lands in exactly the same place: 0.0000 m and 0.0000 m/s.
- **One pawn alone:** within 0.1 cm of the server at 50 and 150 ms, walking about 120 m.
- **200 pawns walking,** offline on a flat floor: 8.8 ms a tick.
- **10,000 AI pawns checked** by `AIActivationManager`: 1 ms a frame, spread across 6 frames, with stub pawns, not real ones. That's the checks only. A real pawn that's off also has to stop its `NetworkEntity` and `TickStateComponent`, which `NetworkEntity.set_paused` does.

**Not tested:** playing by hand, a real network, real low-end machines, and the mouse look and edge-of-screen modes, which need a real window and mouse.

## 9. Not in tier -1

Nexus, managers including the controller manager, `AIController`, abilities including Walk and Fly, stat manager, `SpectatorPawn`, `RTSPawn`, camera blending, and replay.
