<!-- Written by Claude (claude-opus-5-5), 2026-11-07: the new pawn spec, from the owner's 2026-11-07 decisions on the pawn rebuild. A first shape to work from, not finished. Replaces docs/legacy/PAWN_ARCHITECTURE.md, which stays as a guide. -->

# Pawn Spec v0.9

**Revisions:**
- v0.1 (2026-11-07): first shape, from the owner's decisions that day.
- v0.2 (2026-11-07): Sprint is its own ability, with a cooldown and a maximum duration. Heavy load (4.1). A missing input repeats for a few ticks, then its move fades, while held actions keep repeating (5). `ControllerBase` trimmed to what step 2 builds (6.1).
- v0.3 (2026-11-07): step 2 built. After a review: `take_input_command` instead of `get_input_command`, because it uses up saved presses. The missing-input settings live on `NetworkSession` (5).
- v0.4 (2026-11-07): steps 3 and 4 built: `ControllerManager`, the `AIController` placeholder and `PawnInitializer` (6.3, 6.4, 11). `TickStateComponent` and `NetworkEntity` stay in the pawn's scene, because `NetworkSession` reads them before the pawn joins the tree.
- v0.5 (2026-11-07): steps 5 and 6 built: `StatManager` and `Stat` (9), `AbilityBase`, `AbilityManager`, Walk, Sprint and Jump (8.3 to 8.5). `GroundMovement` and `MovementModule` are gone. Ability state rolls back through `TickStateComponent.add_state_properties()`.
- v0.6 (2026-11-08): step 7, first half: `NavigationManager` built (7), with click-to-move and `AIController.move_to` on it (6.2, 6.3). Nav phase 3 (links) is split off as step 7b, still to agree (12).
- v0.7 (2026-11-08): step 7b built: links, placed and found automatically. `NavigationManager` crosses them and the controller presses the link's action (7).
- v0.8 (2026-11-09): the AI agreed, from the owner's decisions of 2026-11-08 and 2026-11-09 (10, rewritten). Sensing with awareness and fading memory for basic stealth; states Idle, Alert and Combat picked by priority; behaviours scored with ranges, seeded jitter and persistence; `AIContextComponent`; a `while_possessed` setting; GDScript first, with C++ candidates flagged. Step 8 split into 8a and 8b (12). Open questions 5 and 8 settled, new ones added (13).
- v0.9 (2026-11-09): the owner's review of v0.8. Approved, with these changes:
  - Every fade is a tunable `FadeProfile`, with rules for tunable thresholds and lightweight data (10.2).
  - Memory fades without a background loop (10.5).
  - Target selection by priority, with taunts (10.5).
  - Alert and Combat share one tunable `AIAwarenessState` (10.6).
  - Forced states carry a priority (open question 9 settled).
  - Interrupt thresholds and jitter per behaviour (10.7).
  - Why AI pawns are already rolled back for hit checks while their decisions aren't (10.2), and why the behaviour manager isn't planned for C++ (10.1).

**Status:** a first shape to work from, written 2026-11-07. Nothing in it is built yet, except what's marked **(built)**. Code sketches are GDScript outlines, not final signatures. Class names are working names. Each one differs from the legacy class names, because legacy files are never changed and new systems sit beside them.

**Scope:** everything on a pawn. That covers its parts, how a controller drives it, abilities, stats, navigation and the AI.

**Related docs:**
- `docs/legacy/PAWN_ARCHITECTURE.md`: the old spec, now a guide. Sections 7.1 to 7.5 (categories, lockouts, cooldowns, input buffer) are borrowed below.
- `docs/pawn/PLAYER_AND_CAMERA.md`: the player controller, cameras, possession and `GameMode` **(built)**.
- `docs/netcode/NETCODE_SPEC.md`: ticks, rollback and inputs. The pawn follows it.

How to read this:
- Sections 1 to 4 are the big picture: what's decided, the node tree, who may talk to whom, and one tick from start to end.
- Sections 5 to 11 go part by part.
- Sections 12 to 14 cover the build order, open questions and what's deferred.

---

## 1. Decided

| Decision | Date |
|---|---|
| No nexus layer. Parts attach directly to the pawn | 2026-11-07 |
| `PawnInitializer` is a `GameMode` module that fills in missing parts. For t0 it holds only the current defaults | 2026-11-07 |
| One node per part. Abilities, stats, states and behaviours are each a node | 2026-11-07 |
| No intent. Controllers send **inputs**. A missing input is replaced by the last one held, fading over a few ticks (v1). Fancier prediction is chosen per game | 2026-11-07 |
| Controllers share one base class | 2026-11-07 |
| The player controller lives outside the pawn. `GameMode.possession_coordinator` connects them **(built)** | 2026-11-07 |
| No pawn class hierarchy. Godot can't do Node3D → base pawn → CharacterBody3D, so other body types will be separate classes. `Pawn` is a CharacterBody3D because `move_and_slide` is built on it | 2026-11-07 |
| Abilities write velocity. The pawn adds gravity and calls `move_and_slide`. No separate motor layer | 2026-11-07 |
| t0 abilities, part 1: Walk and Jump | 2026-11-07 |
| Sprint is its own ability, with a cooldown and a maximum duration for now and no stamina. So it can win over Walk without winning all the time, which gives something to test | 2026-11-07 |
| The stat manager takes stat nodes | 2026-11-07 |
| Sensing, memory, the state manager and the behaviour manager live on the pawn, not on the AI controller | 2026-11-07 |
| An ability is pressed like a skill in an MMO or MOBA. It can be one action or a sequence | 2026-11-07 |
| Behaviours press the same named actions a player presses | 2026-11-07 |
| Each behaviour node holds its own checks, score and action. The behaviour manager only judges between them. It filters with cheap checks first and stops early using each behaviour's highest possible score | 2026-11-07 |
| Everything that changes game state runs on `TickDriver`. Visuals, camera, UI, audio and debug readouts stay on normal frames | 2026-11-07 |
| Order: finish the AI and add more abilities before fight testing | 2026-11-07 |
| Basic stealth in t0: awareness that fills from sight and drains over time, with a last known position (10.4, 10.5) | 2026-11-08 |
| `AIStateManager` picks the state by priority, from each state's prerequisites; the behaviour manager uses that state to filter behaviours. t0 states: Idle, Alert, Combat. Search is a behaviour, not a state (10.6) | 2026-11-09 |
| Behaviours are scored with seeded jitter per score (default 0), optional random ties, ranges for pruning, and persistence that holds then halves, all in ticks (10.7, 10.8) | 2026-11-09 |
| The AI treats players and NPCs the same. What it does while a player has the pawn is a setting, per game (10.2, 10.3) | 2026-11-09 |
| No hearing and no damage sense in t0. Being hit is a state prerequisite (10.4, 10.6) | 2026-11-09 |
| GDScript first; parts that probably want C++ later are flagged (10.1) | 2026-11-09 |
| Fades, rates and thresholds are tunable without code, and painless to recode: `FadeProfile` resources and settings-driven states (10.2, 10.6) | 2026-11-09 |
| Behaviours can lock out interrupts below a priority threshold, or entirely. Forced states carry a priority (10.6, 10.7) | 2026-11-09 |
| Target selection by priority, where taunts act (10.5). Jitter is set per behaviour and can change at runtime (10.7) | 2026-11-09 |

---

## 2. The node tree

```
Pawn (CharacterBody3D)                    (built, tier -1; gets reworked)
├─ CollisionShape3D
├─ Visual (Node3D)                         follows the body smoothly; models hang from it
├─ TickStateComponent, NetworkEntity       (built) rollback state and networking
├─ ControllerManager                       picks which controller's input counts
│  └─ AIController                         turns behaviour calls into input
├─ NavigationManager                       paths and "which way to walk now"
├─ AbilityManager                          starts, runs and stops abilities
│  ├─ Walk                                 locomotion
│  └─ Jump                                 action
├─ StatManager                             holds stat nodes
│  └─ stat nodes (Health, MoveSpeed, ...)
├─ AISensingManager                        runs its senses; writes what they find to memory
│  └─ SightSense
├─ AIMemory                                one entry per sensed entity; awareness that fades
├─ AITargetSelector                        picks the current target from memory, by priority
├─ AIStateManager                          picks the current state by priority
│  └─ state nodes (Idle, Alert, Combat)
├─ AIBehaviourManager                      picks and runs a behaviour the state allows
│  └─ behaviour nodes (Wander, Look Toward, Investigate, Search, Chase)
└─ AIContextComponent                      shared data and settings for the AI; makes no decisions

PlayerController (outside the pawn)        (built) reads devices; joins a pawn through PossessionCoordinator
```

- The parts are kept flat on the pawn, so a designer sees every part in one place.
- The AI parts exist on every peer, but only tick on the server, because AI only runs there.
- **Today (2026-11-08, after step 7a):** `pawn.tscn` holds `CollisionShape3D`, `Visual`, `TickState` and `NetworkEntity`. `PawnInitializer` adds `ControllerManager` (with `AIController`), `NavigationManager`, `StatManager` (with the movement stats) and `AbilityManager` (with Walk, Sprint and Jump).

---

## 3. Who may talk to whom

1. **A part only talks to its own manager or to the pawn.** A Walk node talks to `AbilityManager` and the pawn, nothing else.
2. **Outside code only calls managers.** For example: `pawn.ability_manager.can_start(&"primary")`.
3. **Only the initializer assembles parts.** Nothing else adds or removes managers at runtime.
4. **Behaviours never touch abilities or the body directly.** They go through `AIController`, the same way a player goes through `PlayerController`. They may *ask* the ability manager questions, such as "could this action start?" or "is it busy?".
5. **Nothing holds intent.** Each tick the controller in charge produces one input command, and that's all the abilities see.

---

## 4. One tick, in order

The pawn registers with `TickDriver` once. Each tick it calls its managers in a fixed order. Parts never register on their own, so a pawn with 30 parts is still one tick entry, and the fixed order keeps replays exact.

| Step | Who | What | Where |
|---|---|---|---|
| 1 | AI parts | Sensing and memory on their turns. On decision ticks, the state is checked and the behaviour manager decides. Every tick, the running behaviour ticks and calls `AIController` (10.9) | Server only. While a player has the pawn, `while_possessed` says what runs (10.3) |
| 2 | `ControllerManager` | Asks the controller in charge for this tick's input command | Everywhere the pawn is simulated |
| 3 | `AbilityManager` | Turns presses into ability starts, ticks running abilities, and runs the locomotion ability, which writes horizontal velocity | Same |
| 4 | `Pawn` | Adds gravity and calls `move_and_slide` | Same |
| 5 | `TickStateComponent` | Saves state for rollback **(built)** | Same |

### 4.1 Heavy load

**What already protects a frame:**
- **Godot:** physics runs at a fixed rate. After a slow frame, Godot runs several physics steps to catch up, up to `max_physics_steps_per_frame` (8 by default). Past that, the game slows down rather than freezing.
- **`TickDriver` (built):** the same idea for ticks. It runs at most `max_ticks_per_frame` ticks per frame, drops the time beyond that, and counts the drops in `dropped_ticks`.

Both protect against the "spiral of death", where every slow frame makes the next one slower. Neither spreads work out. They slow the game down instead.

**Why abilities and `move_and_slide` stay on their own tick:** moving them to the next frame wouldn't lower the cost per tick. Every simulated pawn still has to move every tick, so the work only shifts by one frame. Meanwhile it adds a tick of delay between input and movement, and makes rollback harder.

**What does lower the load, in order:**
1. **Spread work that doesn't need every tick.** That means AI decisions, sensing and repathing, each with a cap per tick, the way `AIActivationManager` caps its checks **(built)**.
2. **Switch off AI where no player is** **(built)**.
3. **Later, if measurements say so:** move far-away AI pawns every second or fourth tick with a bigger step. The AI only runs on the server and is never rolled back, so this is safe for it.

The stress tests (`net_stress`, `chunk_stress`) measure this. We decide from their numbers, not guesses.

---

## 5. The input command

One small set of plain values per tick. Players and AI produce the same shape. It's what goes over the network. **(Built 2026-11-07, step 2:** `InputCommand` and `InputActions` in `assets/scripts/controllers/`, the list in `resources/input_actions.tres`, and `Pawn.apply_input()`, `is_action_held()` and `was_action_pressed()`. Test: `controllers/tests/input_actions_selftest`.**)**

| Field | Type | Meaning |
|---|---|---|
| `move` | Vector3, world space, length 0 to 1 | Which way to walk, and how hard |
| `look_yaw`, `look_pitch` | float | Where the controller is looking |
| `held_actions` | int (bits) | Which named actions are held this tick |

**Named actions:**
- Actions are names like `&"jump"`, `&"sprint"`, `&"primary"` and `&"ability_2"`.
- Like tags, they're declared up front in a list, so each name gets the same bit on every peer.
- A **press** is "held this tick, not held last tick". It's worked out where the input is used, so a press is never sent twice.
- Last tick's held actions (`Pawn.previous_held_actions`) are rollback state, sent in snapshots like position, so a server correction also fixes which presses the client's replay sees. *(Claude 2026-11-07, from the audit of 6df1464: reading it back from the client's own saved input went wrong when the server never received a press. It costs 2 bytes per pawn per snapshot, about 6% more in the stress test.)*
- The player controller maps keys to actions with Godot's input map. The AI controller sets them from behaviour calls.

**A missing input over the network (v1):**
- The server repeats the last command in full for `missing_input_hold_ticks` (3 by default), as it already did **(built)**. Most losses are only a tick or two, and a full repeat is the best guess for those.
- After that, `move` fades to zero over `missing_input_fade_ticks` (6 by default), so a pawn whose player lost connection doesn't keep walking forever.
- Both settings are on `NetworkSession`, set once per game. A pawn can use its own numbers. Its settings of the same names default to -1, meaning "use the session's".
- Held actions keep repeating. Clearing them would make a still-held key count as a new press when input comes back.
- Presses never repeat, because a repeated held action isn't "newly held".
- Smarter guessing is a per-game choice for later.

---

## 6. Controllers

### 6.1 `ControllerBase` (built 2026-11-07)
The shared base class for both controllers. `PlayerController` extends it, and maps keys to actions with its `action_keys` setting.

```gdscript
class_name ControllerBase extends Node
signal pawn_changed(pawn)
var pawn: Pawn
func take_input_command(tick: int) -> InputCommand   # this tick's command (section 5); idle by default
```
Step 3 didn't need hooks for gaining and losing a pawn: `ControllerManager.attach_player()` and `detach_player()` cover it.

### 6.2 `PlayerController` (built)
- Lives outside the pawn and survives with no pawn **(built)**.
- It doesn't tick on its own. When it takes a pawn it attaches to the pawn's `ControllerManager`, which asks it for input each tick **(built, step 3)**.
- Reads keys, mouse and stick, rotates movement by the camera's yaw, and maps keys to actions.
- **Click-to-move (built 2026-11-08, step 7a):**
  1. A click asks the world cursor for a point.
  2. It calls `pawn.navigation_manager.move_to(point)`. A click with no way there does nothing.
  3. While a path is being followed, `move` comes from `navigation_manager.get_move_direction()`.
  4. WASD cancels the path.

### 6.3 `AIController` (placeholder built 2026-11-07, step 3)
- A child of `ControllerManager`.
- It decides nothing. It's the AI's hands: behaviours call it, and it builds the input command.
- Everything it's told stays until changed, except `press()`, which lasts one tick.

```gdscript
func move_in_direction(direction: Vector3) -> void   # built: walks that way until told otherwise
func stop() -> void                                  # built
func look_at_point(point: Vector3) -> void           # built. Until called, it keeps the pawn's own look, so a handover doesn't snap it
func stop_looking() -> void                          # built: back to keeping the pawn's own look
func press(action: StringName) -> void               # built: held for one tick
func hold(action: StringName, held := true) -> void  # built
func release_all() -> void                           # built: back to idle
func move_to(point: Vector3) -> bool                 # built 2026-11-08: passes on to NavigationManager; false if there's no way there
```
- **From step 8a, while it isn't in charge** (a player has the pawn and `while_possessed` is `FULL`, 10.3): it keeps the last order it was given (a target point, held actions, a look target) without touching `NavigationManager`, so it can't overwrite the player's path. When it takes charge again, it carries out that order.

### 6.4 `ControllerManager` (built 2026-11-07, step 3)
- Picks whose input counts. The rule is fixed and simple:
  - This machine's player controller is attached: it's in charge.
  - A player on another machine has the pawn: nobody here is, because input arrives over the network.
  - Nobody has the pawn: the AI controller is in charge.
- The pawn asks `take_input_command()` once per tick, in its input phase. It only asks where its input is decided: offline, on its owner's machine, or on the server for a pawn nobody owns.
- `PlayerController` attaches and detaches itself when it takes or lets go of a pawn.
- When the player lets go, the AI controller takes over at once. *(Claude 2026-11-09: the AI needs nothing special for this. Its next state check works from memory as usual, 10.3.)*
- `controller_changed` is sent once at the end of the frame with the final answer, so listeners never see "nobody" halfway through a possession.
- Test: `controllers/tests/controller_manager_selftest`.

---

## 7. Navigation manager (built 2026-11-08, step 7a)

The pawn's only contact with navigation. Both controllers use it. `assets/scripts/navigation/NavigationManager.gd`, part scene `scenes/pawn/parts/NavigationManager.tscn`. Test: `navigation/tests/navigation_manager_selftest`.

```gdscript
signal arrived                           # once, at the end of a path
func move_to(point: Vector3) -> bool     # false if there's no way there
func stop() -> void
func get_move_direction() -> Vector3     # which way to walk now; zero when there's no path. Once per tick: it also moves on to the next corner
func is_following_path() -> bool
func has_arrived() -> bool               # true from reaching the end until the next move_to or stop()
func get_path_corners() -> PackedVector3Array   # the corners ahead, for debug drawing
```

- It asks `NavServer` for a path and follows the corners. The waypoints stay private.
- It never ticks on its own. The controller in charge asks it for a direction once per tick and puts it in the input command.
- Settings: `corner_reached_distance` (0.5 m), `arrival_distance` (0.3 m), `nav_tier` (0).
- With no nav at all, it walks in a straight line. That covers no navcore library, and no nav under the pawn (a level that feeds no nav).
- A point nowhere near nav: `move_to` returns false. A point on nav it can't reach, such as an island: the path goes as close as it can.
- `ControllerManager` drops the path whenever control changes hands, so the AI never walks the rest of a player's click.
- The path is found at once, on the main thread (`find_path_now`), as the stress test already does. Asking in the background is there (`NavServer.find_path`) if a crowd's paths ever cost too much.
- Not yet: noticing it's stuck, and finding a new path when nav changes.
- **Links (built 2026-11-08, step 7b):** with `use_links` on (the default), a path may cross links: jumps and drops nav finds by itself, and links placed with `NavLink` markers. Reaching a link's start, `take_link_action()` gives the action to press, such as `jump`, and the controller presses it for one tick; a drop has none. If the pawn hasn't reached the far end within `link_timeout` (3 s), it finds one new path to the same place, and after a second miss it stops, neither following nor arrived. `is_crossing_link()` says when it's mid-link. Turn `use_links` off for a pawn that can't jump. See nav spec section 19.1.
- **Over the network:** the client follows its own path and sends directions. The server never sees a path. The stress test already works this way **(built)**. This settles open question 15 in the netcode spec.
- Borrowed for later from the old guide, section 8: repathing when tiles change, size tiers, domains.
- Nav phase 3's links are step 7b, built. Agents in C++ aren't needed: the pawn follows its own path.

---

## 8. Abilities

### 8.1 What an ability is
- An ability is a skill you press, like in an MMO or MOBA.
- It can be one action, such as a jump, or a sequence over several ticks, such as a three-hit combo. A sequence lives inside one ability, which steps through it in `tick`.
- There are two kinds:

| Kind | Examples | Rule |
|---|---|---|
| **Locomotion** | Walk, later Sprint, Swim, Fly | Continuous. Exactly one runs. It reads `move` every tick and writes velocity. The manager has a default (Walk) |
| **Action** | Jump, later Dash, MeleeAttack, Heal | Starts on a press, then runs until it's done |

### 8.2 Binding actions to abilities
- Each ability node names the action that triggers it: `trigger_action = &"primary"`. The designer sets it on the node, so there's no separate table to keep in sync.
- **Several abilities on one action:** the manager starts the first that can start, by `priority`, then by tree order.
- **A held action can switch locomotion.** For example, Sprint is a locomotion ability with `trigger_action = &"sprint"`, used while that action is held.
- **The same path for player and AI.** The player's key presses `&"primary"`, and an AI behaviour presses `&"primary"`. Both reach the same ability through the same rules. That's why possession needs nothing extra.

### 8.3 `AbilityBase` (built 2026-11-07, step 6)
In `assets/scripts/abilities/`. Borrowed from the old guide, section 7.2, and simplified. The changes are listed below the code.

```gdscript
class_name AbilityBase extends Node
enum Kind { LOCOMOTION, ACTION }

@export var kind := Kind.ACTION
@export var trigger_action: StringName = &""     # empty = only the manager starts it, as the default locomotion
@export var category: StringName = &""           # a tag, e.g. movement.jump, for lockouts (tag registry, built)
@export var priority := 0                        # lower wins when several abilities share an action
@export var duration := 0.0                      # seconds. Action: 0 = at once. Locomotion: 0 = as long as wanted
@export var cooldown := 0.0                      # seconds after it stops
@export var locks_out: Array[StringName] = []    # categories that can't start or steer while this runs
@export var buffer_window := 0.0                 # seconds a press waits if it can't start yet

# Rolls back: counts down to 0, so it's small on the network
var ticks_left / cooldown_ticks_left / buffer_ticks_left

func get_rollback_properties() -> Array[String]  # what to register with the pawn's TickState
func can_start() -> bool                         # extra conditions; cooldowns and lockouts are checked already
func start() / tick(dt) / stop() / every_tick(dt)
func read_stat(stat_name, fallback) -> float
```

What changed from the old guide:
- Abilities are started by a **named action**, not by a category request.
- Categories stay, but only for lockouts and, later, for telling nav which links a pawn can use.
- No context object. An ability reaches its pawn and manager directly.
- No separate "bufferable" switch: a buffer window of 0 means a press is tried once.
- **Rollback:** each ability names the properties it keeps between ticks, and the manager registers them with the pawn's `TickStateComponent` (`add_state_properties()`, added for this) before the first tick. A designer adding an ability doesn't edit any list. Timers count *down* to 0 rather than storing "ready at" ticks, so they stay small numbers on the network.

### 8.4 `AbilityManager` (built 2026-11-07, step 6)

```gdscript
func tick_abilities(dt)                      # the pawn calls this each tick, before gravity and move_and_slide
func can_start(action: StringName) -> bool   # behaviours ask this before choosing to press
func is_busy() -> bool                       # a timed action is running
func has_action(action: StringName) -> bool
func cancel(action: StringName) -> void
func is_locked(ability) -> bool
signal ability_started(ability) / ability_finished(ability)
```

**Each tick, in order:**
1. Cooldowns and waiting presses count down, and every ability's `every_tick()` runs.
2. Exactly one locomotion runs: one whose action is held and which can run, otherwise the default (no action, which is Walk).
3. Running timed actions tick. A press starts the first ability bound to that action that can start; one that can't keeps the press for its buffer window. One press starts one ability.

**Lockouts as bit masks:**
- One AND per check, worked out each tick from the running actions.
- A locked-out locomotion stops steering, so the pawn slows to a stop.

**Not built yet** from the old guide: the "stack" buffer mode, costs, and leaving AI presses unbuffered.

Test: `abilities/tests/ability_selftest`.

### 8.5 t0 abilities (built 2026-11-07, step 6)
- **Walk** replaced `GroundMovement`, which is gone along with `MovementModule`.
  - It reads speed, acceleration, deceleration, air control and turn rate from the stat manager, with the old values as fallbacks.
  - The pawn adds gravity and makes the one `move_and_slide` call.
- **Jump** happens at once.
  - It starts from the ground, or within `coyote_time` (0.1 s) of walking off an edge.
  - A press up to 0.15 s before landing waits and jumps on landing.
  - The height comes from the JumpVelocity stat.
- **Sprint** is its own locomotion ability, bound to `&"sprint"`.
  - It has faster numbers, a **maximum duration** and a **cooldown**. There's no stamina yet.
  - While `&"sprint"` is held and Sprint is ready, it runs instead of Walk. When its time runs out it ends, its cooldown starts, and Walk takes over even if the key is still held.
  - The AI uses it the same way: a behaviour such as Chase holds `&"sprint"`, and asks `can_start(&"sprint")` if it cares. So Sprint wins over Walk whenever it's ready, but the cooldown gives it downtime. That's what makes it testable.
- After the AI is built, more abilities come before fights: Dash, then MeleeAttack.

---

## 9. Stats (built 2026-11-07, step 5)

- `StatManager` holds `Stat` nodes, in `assets/scripts/stats/`. One node per stat, named after it: MoveSpeed, JumpVelocity and so on.
- Abilities and behaviours read stats through the manager by name (`get_value(&"MoveSpeed", 5.0)`), and each read has a fallback, so a missing stat is never a crash.
- The default part `scenes/pawn/parts/StatManager.tscn` holds the movement stats `GroundMovement` used to hold, at the same values: MoveSpeed 5, SprintSpeed 9, Acceleration 30, Deceleration 40, AirControl 0.3, TurnRate 720 and JumpVelocity 5.
- **Later:**
  - Stats that change during play (Health, Stamina) will be rollback state. The movement stats don't change yet, so none roll back today.
  - Modifiers (buffs, debuffs).
- Test: `stats/tests/stat_selftest`.

---

## 10. AI (agreed 2026-11-09, build step 8)

*Claude 2026-11-09: rewritten from the owner's decisions of 2026-11-08 and 2026-11-09. The earlier sketch had a "mood" layer, a damage sense and sensing that paused with decisions; all three changed.*

**The idea in one paragraph.** The AI is a brain and a pair of hands. The brain is the parts below: it notices things (sensing), remembers them (memory), works out the situation (states) and picks what to do about it (behaviours). The hands are `AIController` (6.3, built), which turns the brain's calls into the same input command a player's keys make. Abilities can't tell the two apart, so the AI can't cheat past cooldowns, and possession needs nothing extra.

### 10.1 The parts

| Part | Job | C++ later? |
|---|---|---|
| `AISensingManager` | Runs its senses on their turn, gives them one shared list of nearby pawns, and writes what they find into memory. Each sense is a child node; t0 has only `SightSense` | **Yes, the first candidate** (10.4) |
| `AIMemory` | One entry per sensed entity: where it was last seen, when, how aware of it the pawn is, whether it was ever fully spotted, and its threat. Entries fade and are forgotten | Maybe, with sensing. Fading costs nothing in the background (10.5) |
| `AITargetSelector` | Picks the current target from memory by priority: awareness, distance, threat, and a bonus for keeping the current one. Taunts force it (10.5) | No |
| `AIStateManager` + state nodes | Checks each state's prerequisites in priority order and moves the pawn to the first one that fits. t0 states: Idle, Alert, Combat | No |
| `AIBehaviourManager` + behaviour nodes | Keeps the behaviours the current state allows, scores them, and runs the winner | Not planned (below) |
| `AIContextComponent` | Shared data and settings for this pawn's AI: references to the other parts, the current state, the shared inputs (10.8), the random seed, and `while_possessed` (10.3). It makes no decisions | No |
| `AIController` | The hands (6.3) **(built)** | No |

**GDScript first.** Everything is written in GDScript. Parts marked "C++ later" are laid out so a port is mechanical: plain data in packed arrays, one array per field, rather than an object per fact. They move to C++ if the stress tests say so, behind the same functions, the way `NetCodec` was done with `NetPackets` kept as the fallback.

**Why the behaviour manager isn't planned for C++.** *(Claude 2026-11-09, from the owner's review.)* Its cost is mostly the designers' `score()` and `is_available()` functions, which are GDScript, and a C++ manager would still have to call them. Its own work is small: a few behaviours per pawn, a few times a second, gates and ranges that are just comparisons, and one hash per score. If a stress test ever shows it matters, that loop (gates, ranges, jitter, ties) can move to C++ while `score()` stays in GDScript. Until then, the cheap ways to keep it fast are the lightweight-data rules in 10.2, especially creating nothing per decision.

**Class names.** Legacy files still declare global class names such as `InvestigateBehaviour`, `AlertedState` and `AIContext`, and two scripts can't share one. So the new classes are `FadeProfile`, `AITargetSelector`, `AIStateBase`, `AIBehaviourBase`, `AISenseBase`, `SightSense`, `AIIdleState`, `AIAwarenessState`, `AIWanderBehaviour`, `AILookTowardBehaviour`, `AIInvestigateBehaviour`, `AISearchBehaviour` and `AIChaseBehaviour`, none of which exist in legacy. Their nodes keep plain names (Idle, Wander), which are what `allowed_states`, the fixed order and the jitter hash read.

**From the legacy AI.** The ideas come from the legacy `AISensingComponent`, `AIMemoryComponent`, `AIStateManagerComponent`, `AIBehaviourManagerComponent` and `AIContext`, but the code is new, with new names, typed to the new `Pawn`. Tier 0 uses no legacy code (open question 8). What changes:
- **No AI core node.** The initializer assembles the parts.
- **No `GlobalAICoordinator` autoload.** Work is spread across ticks inside the parts (10.9).
- **No timers or `_physics_process`.** Everything runs on the pawn's tick, server only.
- **No intent.** Behaviours call the hands, which make inputs.

### 10.2 Rules that hold everywhere

- **Server only.** Clients never run the AI. They see the movement it makes, like any pawn's.
- **The brain isn't rolled back; the pawn it drives is.** *(Claude 2026-11-09, from the owner's review.)* An AI pawn is a normal pawn: its position, velocity and ability timers are rollback state (`TickStateComponent`), and `LagCompensation.hitscan` and `melee` rewind it for hit checks like any other networked entity **(built)**. So hit detection against AI is already fair. What isn't rolled back is the decision-making: memory, states, behaviours. The server is the only one deciding, so there's nothing to correct. A game would only need the brain rolled back if clients predicted the AI's decisions, or for lockstep networking, as some RTS games use. Neither is t0 (section 14).
- **Players and NPCs are treated the same.** Nothing in sensing, memory, states or behaviours asks who controls a pawn, only its team and what it's doing. A player possessing a goblin is on the goblins' team, so other goblins treat them as a friend.
- **Ticks, not seconds.** Every AI duration is a number of ticks. Seconds in brackets below assume the project's 60 ticks a second.
- **A fixed order.** States are sorted by priority, then name, and behaviours by name, when they register. Never by the order they were added, so the same scene always gives the same choices. A state or behaviour whose name starts with `@` (an automatic name from adding a node in code without naming it, which can differ between runs) gets a warning, because names also feed the random numbers (10.8).
- **Tunable without code.** *(Claude 2026-11-09, from the owner's review.)* Every number in this section is an inspector setting: rates, ranges, angles, thresholds, intervals, weights. Prerequisites and scores read their thresholds from settings, never from numbers in code. When something does need code, it's one small function to override (below).
- **Every fade is a `FadeProfile`.** A small `Resource` that says how a value fades over ticks, edited in the inspector and shareable as a `.tres` file, so one change tunes every behaviour that uses it. One profile, one curve, so designers never have to combine two kinds of fade in their heads:

  | `mode` | Settings | The value, starting from full |
  |---|---|---|
  | `LINEAR` | `hold_ticks`, `fade_ticks` | full for `hold_ticks`, then falls in a straight line to nothing over `fade_ticks` |
  | `HALF_LIFE` | `hold_ticks`, `half_life_ticks` | full for `hold_ticks`, then halves every `half_life_ticks`. Counts as nothing below 1%, which is after 7 halvings |
  | `CURVE` | `hold_ticks`, `fade_ticks`, `curve` (a Godot `Curve`) | full for `hold_ticks`, then follows the drawn curve over `fade_ticks` |

  ```gdscript
  class_name FadeProfile extends Resource
  func value_at(ticks: int) -> float     # 1.0 at the start, falling to 0.0
  func ends_after() -> int               # ticks until it's nothing, so ranges and memory know when it's gone
  ```
  A fade no mode covers is a script that extends `FadeProfile` and overrides those two functions. Every user picks it up with no other change. Used by memory and target selection (10.5) and by persistence (10.7).
- **Lightweight data.** *(Claude 2026-11-09.)* In GDScript, every plain variable takes the same space however small the number, so small types don't save anything. What does is not creating objects while running. So:
  - Anything there are many of (memory entries, candidates) is a packed array, one per field.
  - Ticks are whole numbers.
  - A decision creates no arrays or dictionaries; it reuses ones it keeps.
  - A C++ port can then use small types (16-bit awareness, for example) behind the same functions.
- **Mistakes are made obvious.** In debug builds, a warning names the node when:
  - a behaviour's `score()` is above its `max_score` or below its `min_score`;
  - a state has no behaviour that could run in it;
  - no state's prerequisites hold (Idle always should);
  - `force_state` is called on a client.

### 10.3 While a player has the pawn

`AIContextComponent.while_possessed` says what the AI does while a player has the pawn. Which is right depends on the game:

| Setting | What runs | For |
|---|---|---|
| `OFF` | Nothing | Games where possessed pawns don't need to know what happened |
| `MEMORY_ONLY` (default) | Sensing and memory. States and behaviours pause | An "Agent Smith" mechanic: when the player lets go, the AI already knows what's around |
| `FULL` | Everything | The AI keeps deciding. Its hands keep the last order without acting on it (6.3) |

- **Letting go needs no special code.** The next state check works from memory, as it always does.
- When `AIActivationManager` switches the pawn off, all of the AI stops with it **(built)**.

### 10.4 Sensing

- `AISensingManager` makes a **full pass** every `sense_interval_ticks` (10, a sixth of a second), on its turn (10.9).
  - One shared query finds the pawns of other teams within the longest sense range, and each sense gets that list.
  - Senses are child nodes that extend `AISenseBase`. t0 has only `SightSense`.
- **Cheap refresh between passes.** Every `refresh_interval_ticks` (5), `SightSense` casts one line-of-sight ray to each entity already in memory, and a hit counts as seeing it. This keeps a tracked target fresh without a full pass.
- **Teams.** Each pawn has a `team` number (open question 5). Sensing only puts pawns of other teams into memory. Neutral pawns and factions come later.
- **No hearing in t0** (section 14). **No damage sense:** being hit is a state prerequisite instead (10.6), because the attacker is known.
- **C++ later:** the pass grows with pawns × candidates (queries, angle and distance checks, rays, gain maths). It's the same kind of batch over plain data as `NavServer`, and the natural place for background threads later (14).

**How sight fills awareness.** For each other-team pawn in the list, on each pass or refresh:

```
if there's no line of sight: no gain
gain = fill_rate × ticks_since_last_check × distance_factor × angle_factor × target.detectability
```

| Factor | Rule | Starting value |
|---|---|---|
| `fill_rate` | Awareness a fully visible target adds per tick | 1/30 (full in 30 ticks, half a second) |
| `ticks_since_last_check` | Ticks since this target was last checked. It makes the checking rate not matter: a target checked every 10 ticks gets 10 ticks' worth | |
| `distance_factor` | 1 inside `near_range`, falling in a straight line to 0 at `sight_range`. Measured at the check | 8 m and 25 m |
| `angle_factor` | 1 inside the central cone, `periphery_multiplier` in the periphery, nothing outside it | central cone 90° wide, periphery out to 160°, multiplier 0.3 |
| `target.detectability` | One number the target exposes. 1 is normal, lower is harder to detect, 0 is invisible | 1.0 |

So someone close and in front is spotted in half a second, which is basically instant. Someone 20 m away at the edge of the periphery takes several seconds.

**Detectability belongs to each game.** The pawn exposes `detectability`, defaulting to 1.0, and nothing in the base changes it. How it's worked out is a game rule, so it goes in an optional `GameMode` module that sets it every so often. A cloak giving +10 stealth might be a fixed percentage in one game and a DC roll in another. Light level and similar modifiers fold into the same number, so sensing never calls game code for each pair of pawns. t0 has no such module, so every pawn is at 1.0.

### 10.5 Memory

Each entry holds:
- the entity (its id)
- `last_known_position`, updated whenever it's seen
- `last_seen_tick`
- `awareness_when_seen`: awareness at the last sighting, from 0 to 1
- `spotted`: set the first time awareness reaches 1, cleared when the entry is forgotten
- `threat`: added to by game mechanics, 0 in t0 (target selection, below)

Kept as packed arrays, one per field, so a port to C++ is mechanical (10.1).

**How awareness moves:**
- Sight adds gain (10.4), up to 1.
- Seeing an entity that's already spotted refills it to 1 at once. A guard who knows you're there doesn't need to notice you again.
- **While it isn't seen, it fades by a `FadeProfile`** (10.2): awareness now = `awareness_when_seen × profile.value_at(ticks since seen)`. There are two settings on `AIMemory`:
  - `fade` for entries not spotted: default `LINEAR`, no hold, `fade_ticks` 300 (5 s)
  - `spotted_fade`: default `LINEAR`, no hold, `fade_ticks` 1200 (20 s)

  With the default straight line, an entry is forgotten that many ticks after it was last seen, whatever its awareness was. That's easy to predict. A designer wanting a slow start and a quick end draws a `CURVE` instead, with no code.
- **Nothing drains in the background.** Awareness is worked out when something asks, from two stored numbers and the current tick, the same trick as persistence. An entry is forgotten once its profile's `ends_after()` has passed. So there's no loop over every entry each tick, which also takes memory draining off the C++ list.

**What memory answers:** for any entry, its awareness now, whether it's spotted, ticks since seen, and last known position. Behaviours read these through the context's shared inputs (10.8).

#### Target selection

*(Claude 2026-11-09, from the owner's review: target selection needs priorities, and that's where mechanics like taunts act.)*

`AITargetSelector`, a part beside memory, picks the pawn's **current target** from memory, and puts it on the context for behaviours (`needs_target`) and state prerequisites. It's the standard threat or aggro table from MMOs, kept small.

- **Each candidate gets a target priority**, worked out at each decision:
  ```
  priority = awareness_weight × awareness
           + distance_weight × (1 − distance / sight_range)
           + threat_weight × threat
           + current_target_bonus × current_target_fade   (only for the current target)
  ```
  - Every weight is a setting. The defaults are awareness 1.0, distance 0.5 and threat 1.0.
  - Only entries at awareness 0.3 or more are candidates, also a setting, so a barely noticed shape isn't a target.
- **The current target bonus** stops the pawn flicking between two close targets. It's a `FadeProfile` (10.2) counted from when the target was picked. The default is +0.3, held for 60 ticks, then fading over 60.
- **Threat** is a number per entry that game mechanics add to, such as damage dealt to this pawn (step 10) or healing done near it. It's 0 in t0, and the hook is there.
- **Forcing a target (taunts):** `target_selector.force_target(entity, hold_ticks, priority, reason)`. It overrides the choice for `hold_ticks`. A new force replaces the current one only if its priority is equal or higher, the same rule as forced states (10.6). On a client it does nothing and warns.
- **Ties** go to the nearer entity, then the lower id.
- `target_changed(old_target, new_target, reason)` is sent once, for the debug readout and animation.
- **Recoding:** a game with its own targeting rules extends `AITargetSelector` and overrides `target_priority(entry)`. Everything else stays.

**Memory wakes a decision early** (10.9) when a new entity is added or an entry becomes spotted, so a pawn reacts the moment it spots someone rather than at its next decision tick.

### 10.6 States

**How a state is picked.** At each decision (10.9), the state manager checks each state's prerequisites in priority order and moves the pawn to the first state whose prerequisites hold. That's all: no separate rules for staying, and no minimum time in a state. It works the same way `AbilityManager` picks a locomotion ability. Smoothness comes from memory, which rises and fades steadily. If testing shows a pawn flickering between states, the fix goes in that state's prerequisites, not in a new mechanism.

```gdscript
class_name AIStateBase extends Node
@export var priority := 0                         # higher is checked first
func prerequisites_met(context) -> bool          # the state's own rule
func enter(context) -> void
func exit(context) -> void
```

**One tunable state script for awareness.** *(Claude 2026-11-09, from the owner's review: thresholds must be tunable.)* Alert and Combat aren't two scripts. They're two nodes running the same `AIAwarenessState`, with different settings. A designer makes a new awareness state, say a jumpy "Startled" one, by adding a node and filling in the settings, with no code:

| Setting | Meaning |
|---|---|
| `looks_at` | `CURRENT_TARGET` (10.5) or `ANY_ENTRY` in memory |
| `min_awareness` | awareness it needs, 0 to 1 |
| `requires_spotted` | needs the spotted flag |
| `max_ticks_since_seen` | seen within this many ticks; -1 = any |
| *step 10:* `hit_within_ticks` | or was hit within this many ticks; -1 = off |
| *step 10:* `attacker` | for the hit: `KNOWN` (in memory), `UNKNOWN` or `ANY` |

A state with rules no settings cover is a script that extends `AIStateBase` and overrides `prerequisites_met`.

**The t0 states**, highest priority first:

| State | Script | Priority | Settings | Behaviours |
|---|---|---|---|---|
| **Combat** | `AIAwarenessState` | 20 | current target, spotted, seen within 120 ticks (2 s). *Step 10:* or hit within N ticks by a known attacker | Chase (Attack comes with MeleeAttack, step 9) |
| **Alert** | `AIAwarenessState` | 10 | any entry at awareness 0.3 or more. *Step 10:* or hit within N ticks by an unknown attacker | Look Toward, Investigate, Search |
| **Idle** | `AIIdleState` | 0 | none: always fits | Wander |

**How it plays:**
1. A goblin glimpses the player at the edge of its vision. Awareness creeps to 0.3: **Alert**. Look Toward and Investigate score highest, so it turns and walks over.
2. The player stays visible. Awareness reaches 1 and the entry is spotted: **Combat**. It chases.
3. The player ducks behind a rock. After 2 s unseen, Combat's prerequisites fail: back to **Alert**. The spotted entry fades slowly, so the goblin stays Alert for a while, and Search scores highest because the entry is spotted but stale. It runs to the last known position and searches.
4. If the player peeks out, awareness refills to 1 at once: **Combat**.
5. If the player stays hidden for about 20 s, the entry is forgotten: **Idle**. It wanders off.

**Changing state:**
- `state_changed(old_state, new_state, reason)` is sent once, for the debug readout and later for animation.
- The running behaviour stops if the new state doesn't allow it, unless its interrupt threshold holds it (10.7). Its `exit` gets the reason "state changed", and the behaviour manager decides at once.

**Forcing a state:**
1. **One way in:** `state_manager.force_state(&"Combat", hold_ticks, priority, reason)`. The normal check is skipped for `hold_ticks`, or until `release_forced_state()`, and then it takes over again.
2. **Forces carry a priority** *(Claude 2026-11-09: settles open question 9, because behaviour interrupts need one too, 10.7)*. A new force replaces the current one only if its priority is equal or higher. A weaker one is refused, and a debug build logs both, so a designer sees when two scripts are fighting.
3. **At once.** A forced state takes effect on the same tick, without waiting for a decision tick.
4. **Server only.** On a client, `force_state` does nothing and warns.

**Later:** a state's priority fading down to a minimum while it's active (section 14). It would reuse the persistence countdown (10.7).

### 10.7 Behaviours

```gdscript
class_name AIBehaviourBase extends Node
enum Status { RUNNING, SUCCEEDED, FAILED }

@export var allowed_states: Array[StringName] = []  # empty = any state
@export var max_score := 0.5           # the highest score() can return
@export var min_score := -INF          # optional: the lowest score() can return. Unset, it can't help pruning (10.8)
@export var needs_target := false
@export var presses_action: StringName = &""   # if set, skipped while that action can't start
@export var cooldown_ticks := 0        # hard gate: can't be chosen this long after it ends
@export var min_run_ticks := 0         # once chosen, normal decisions can't replace it for this long
@export var interrupt_threshold := 0   # while it runs, only events of this priority or higher can replace it (below)
@export var cannot_be_interrupted := false   # runs until it finishes, whatever happens
@export var score_jitter := -1.0       # ± random offset on its score; -1 = the manager's default_score_jitter
@export var persistence := 0.0         # signed, added to the score. + tends to keep it chosen, - prefers others
@export var persistence_fade: FadeProfile   # how persistence fades (10.2); empty = no persistence

func is_available(context) -> bool
func score(context) -> float
func enter(context) -> void
func tick(context) -> Status          # calls context.controller.move_to / press / hold / look_at_point
func exit(context, reason) -> void
```

**Persistence.**
- When a behaviour is chosen, its persistence starts: the score gets `persistence × persistence_fade.value_at(ticks along)`. The profile (10.2) sets the shape. The default suggestion is `HALF_LIFE` with a hold, but a straight line or a drawn curve works just as well. Once the profile's `ends_after()` has passed it adds nothing, so its range (10.8) has an end.
- Positive `persistence` makes the AI tend to stick with a choice. Negative makes it prefer something else for a while, which gives variety.
- **Only three numbers are stored:** how far along the profile it was at the last change, the tick of that change, and a speed (1.0 normally). The amount is worked out at decision time, so nothing runs every tick and replays are exact.
- **Modifiers** change those numbers, through the behaviour manager (section 3, rule 2):
  - `add_persistence_ticks(&"Chase", 60)`, say after landing a hit, moves it back along the profile.
  - `set_persistence_speed(&"Chase", 0.5)` makes it fade at half speed from where it is now.
- Persistence flags are tabled.

**Interrupts.** *(Claude 2026-11-09, from the owner's review: a behaviour must be able to lock out others, except high-priority forces, or everything.)* Each event that could replace the running behaviour has a priority:

| Event | Priority |
|---|---|
| A normal decision | 0 |
| A state change | the new state's priority |
| A forced state | the force's priority (10.6) |

While a behaviour runs, an event replaces it only if all three hold:
- it isn't `cannot_be_interrupted`;
- the event's priority is `interrupt_threshold` or higher;
- for a normal decision, `min_run_ticks` has passed.

So, with the t0 states:
- The default (threshold 0, no minimum run time) can be replaced by anything.
- **Threshold 15** ignores normal decisions and a drop back to Alert (10), but gives way to Combat (20) and to strong forces. Good for a heavy attack that shouldn't be cancelled by a passing thought.
- **`cannot_be_interrupted`** runs until it returns SUCCEEDED or FAILED, even if its state no longer allows it. Use it sparingly. Only the pawn being removed or the AI being switched off (10.3) still ends it, and `exit` gets that reason.

Code can change a behaviour's threshold while it's running, through `behaviour_manager.set_interrupt_threshold(&"Chase", 25)`, such as a berserk effect.

**Hard gates stay separate.** `cooldown_ticks` and `min_run_ticks` are promises a designer can rely on, not tendencies. They're checked before any scoring, and they read the same start and end ticks as persistence. The minimum run time also stops a behaviour with negative persistence from swapping back and forth every decision.

**Jitter per behaviour.** *(Claude 2026-11-09, from the owner's review.)* Each behaviour has its own `score_jitter`. -1, the default, uses the manager's `default_score_jitter`, which is 0. Code can change it while running, with `behaviour_manager.set_score_jitter(&"Wander", 0.2)`, for a confused or drunk effect, say.

**t0 behaviours:**

| Behaviour | States | What it does | Step |
|---|---|---|---|
| Wander | Idle | Walks to a random reachable point nearby with `move_to`, pauses, and picks another | 8a |
| Look Toward | Alert | Stops and faces the last known position of the most aware entry | 8b |
| Investigate | Alert | Walks, without sprinting, to the last known position. Scores highest for an entry that isn't spotted | 8b |
| Search | Alert | Runs to the last known position, then walks to a few random points around it. Scores highest for an entry that's spotted but stale | 8b |
| Chase | Combat | Follows the current target (10.5), holding `&"sprint"`, finding a new path every so often rather than every tick | 8b |

Because they all move with `move_to`, they cross nav links (jumps and drops) for free (section 7).

### 10.8 How the behaviour manager picks

At each decision:
0. **Interrupts:** if the running behaviour can't be replaced by this decision's event (10.7: its interrupt threshold, `cannot_be_interrupted`, or its minimum run time), it keeps running and the decision stops here.
1. **Valid behaviours:** the ones the current state allows.
2. **Hard gates,** with no behaviour code run: drop any on cooldown, needing a target when there's none, or whose `presses_action` can't start.
3. **Ranges.** Each remaining behaviour's result can only land in a range:
   - ceiling: `max_score + persistence now + its score_jitter`
   - floor: `min_score + persistence now − its score_jitter`, when `min_score` is set

   A behaviour whose ceiling is below the highest floor can't win, so it's dropped. That's 2n comparisons, still with no behaviour code run.
4. **Scoring,** highest ceiling first. Each survivor's `is_available` and `score` run, and its persistence and jitter are added. As soon as the next ceiling can't beat the best result so far, the rest are skipped. A behaviour that doesn't set `min_score` gets its floor from this step, from real scores, so a behaviour scoring below its max never prunes one that would have won.
5. **Jitter:** each behaviour gets its own offset at each decision, within ± its own `score_jitter` (10.7). The offset is a hash of (seed, pawn id, tick, behaviour name), so it doesn't depend on order or on which behaviours were skipped. The seed comes from the world seed, so a replay makes the same choices.
6. **Ties:** results within a small margin are a tie. With `randomize_ties` (default off) one is picked by the same hash. Otherwise the fixed order decides.
7. **Switching:** if the winner isn't the running behaviour, the old one's `exit` runs, then the new one's `enter`, and its persistence countdown starts.

Between decisions, only the running behaviour's `tick` runs, once per tick. When it returns SUCCEEDED or FAILED, the manager decides at once.

**Shared inputs** on the context: values many behaviours read, such as the current target, its distance, whether it's spotted and how stale it is, and the most aware entry. Later, own health fraction and the last hit. They're worked out the first time something asks during a decision and kept until the next one, so if nothing asks, they cost nothing.

### 10.9 Timing and load

- **Decisions:** every `decision_interval_ticks` (15, four a second). In t0, each pawn is offset by its id, so a crowd doesn't all decide on the same tick. Whether a central queue with a budget replaces this is open question 11.
- **Woken early,** on the same tick: a new entity in memory, an entry becoming spotted, a state change, a forced state, or the running behaviour finishing.
- **Sensing:** a full pass every 10 ticks and the cheap refresh every 5 (10.4), offset by pawn id the same way.
- **The running behaviour** ticks every tick. It should stay cheap: Chase finds a new path every so often, not every tick.
- **Later:** background threads for sensing and pathfinding (section 14). The main thread copies plain data, a worker does the work, and the result is used the next tick. The AI runs only on the server and is never rolled back, so a tick of delay costs nothing.

---

## 11. `PawnInitializer` (built 2026-11-07, step 4)

- A `GameMode` module. The pawn calls `GameMode.pawn_initializer.initialize(self)` from its own `_enter_tree`.
- It adds each default part the pawn doesn't already have. A part placed in the pawn's scene is kept as it is, so a designer can override any default by adding their own with the same name.
- **The defaults file:**
  - `resources/pawn_defaults.tres`, a `PawnDefaultsRes` listing part scenes. The project setting `project_base/game_mode/pawn_defaults` can name another.
  - For t0 it lists today's parts: `scenes/pawn/parts/ControllerManager.tscn` (with its `AIController`), `NavigationManager.tscn`, `StatManager.tscn` and `AbilityManager.tscn`. *(Claude 2026-11-08: this line still named `GroundMovement`.)*
  - Each part is a small scene, so its settings can be changed in the editor.
- A part's name is its scene's root node name. Parts are added in the list's order, the same on every machine.
- **Ways out:**
  - One pawn, every default: `Pawn.fill_in_default_parts` off.
  - One pawn, some defaults: `Pawn.skip_default_parts`.
  - The whole game: leave the module out of `GameMode`'s list.
- **Never added by it:** `TickStateComponent` and `NetworkEntity`. `NetworkSession` reads them as soon as it creates a pawn, before the pawn joins the tree, so they stay in the pawn's scene, along with the network input and state lists. Everything else that was a default in `pawn.tscn` moved to the defaults file.
- Test: `game_mode/tests/pawn_initializer_selftest`.

---

## 12. t0 build order

1. **This spec agreed.**
2. **Inputs and controllers:** `ControllerBase`, `PlayerController` moved onto it, the input command with named actions, and the fading missing input. **(Built 2026-11-07.)**
3. **`ControllerManager`.** **(Built 2026-11-07, with an `AIController` placeholder.)**
4. **`PawnInitializer`** and the defaults file. **(Built 2026-11-07.)**
5. **`StatManager`** and stat nodes for movement. **(Built 2026-11-07.)**
6. **`AbilityManager`, `AbilityBase`, Walk, Jump and Sprint**, replacing `GroundMovement`. The existing pawn, possession and network tests must still pass. **(Built 2026-11-07.)**
7. **`NavigationManager`**, with click-to-move moved onto it. **(Built 2026-11-08 as 7a.)**
   - **7b, nav phase 3 (links):** **(Built 2026-11-08.)** Both kinds, the owner's choice: placed (`NavLink` markers through `NavLinkModule`) and found automatically at ledges and gaps. `NavigationManager` presses each link's action. Nav spec section 19.1.
8. **AI** (section 10, agreed 2026-11-09), in two parts:
   - **8a, deciding:**
     - `FadeProfile`
     - `AIContextComponent` with `while_possessed`
     - `AIStateManager` with priority picking and forced states with priorities
     - `AIBehaviourManager` with interrupts, gates, ranges, jitter per behaviour, ties, the fixed order and persistence
     - `AIController` keeping its last order while not in charge

     An Idle state and Wander prove it, with no senses. Decisions offset by pawn id.
   - **8b, noticing:**
     - the `team` number and `detectability` on the pawn
     - `AISensingManager` with `SightSense` and the cheap refresh
     - `AIMemory` with awareness that fades by profile
     - `AITargetSelector` with `force_target`
     - Alert and Combat as `AIAwarenessState` nodes
     - Look Toward, Investigate, Search and Chase

     Then a stress-test run with a few hundred AI pawns, to decide whether sensing and memory move to C++.
9. **More abilities:** Dash, then MeleeAttack.
10. **Teams and the fight loop:** damage, death. Being hit becomes an Alert and Combat prerequisite (10.6), and damage adds threat for target selection (10.5).
11. **Leftovers from t0:** pawns not stacking, saving terrain edits.
12. **Playing by hand,** with real Host and Join windows.
13. **t0 docs:** an overview, plus a reference for every class and function.

---

## 13. Open questions

| # | Question | Current thinking |
|---|---|---|
| 1 | How many ticks a missing input takes to fade | A few ticks; to tune by playing |
| 2 | Where the action list is declared | A resource, like the tag declarations |
| 3 | Combos: one ability with steps, or several abilities chained | One ability for now |
| 4 | Facing: who turns the pawn | Walk faces the move direction; abilities may take over (aiming, attacks) |
| 5 | Teams | **Settled 2026-11-09:** a `team` number on the pawn, enough for sensing to tell friend from foe (10.4). Neutral pawns and factions later |
| 6 | Death | Comes with the fight loop |
| 7 | Animation: which part plays the Kenney Mini Characters' built-in animations (walk, sprint, jump, die, melee) | Probably a part that listens to the ability manager and `state_changed`. Not decided |
| 8 | Whether `AIMemoryFact` is reused as is, or copied | **Settled 2026-11-09:** neither. Tier 0 uses no legacy code, and memory is packed arrays rather than an object per fact (10.5) |
| 9 | Forced states: does a new force always replace the old one, or does each force carry a priority, so a weaker one can't override a stronger one? | **Settled 2026-11-09:** forces carry a priority, because behaviour interrupts need one (10.6, 10.7). Forced targets use the same rule (10.5) |
| 10 | A debug readout above each AI pawn: state, awareness bars, the top three scores | Claude suggests it early in step 8a, as a debug module outside shipping code: utility AI is hard to tune blind. Not agreed yet |
| 11 | Spreading AI work: each pawn offset by its id, or a central queue that runs at most N decisions and sensing passes per tick (an `AIUpdateScheduler` `GameMode` module), so a struggling host reacts later instead of dropping frames | t0 starts with offsets. Claude suggests the queue, with a count budget rather than milliseconds, so results match across machines. Not agreed yet |
| 12 | A cap on sensing: at most N rays per pass, nearest first | Claude suggests it with the 8b stress test. Not agreed yet |
| 13 | A switch that turns stealth off for a game (awareness fills at once), so autobattler fights start straight away | The default numbers already make close sight nearly instant. Not agreed yet |
| 14 | `personality_jitter`: a fixed score offset per pawn and behaviour, so one goblin is a bit more aggressive than another | Claude's suggestion; could wait. Not agreed yet |
| 15 | The target's value is called `detectability` (1 = normal, lower = harder to detect) rather than "stealth factor" | Claude's suggestion, so the name says what it does. Easy to rename |

---

## 14. Deferred, not t0

- Other pawn body types, such as rigid bodies, as separate classes.
- Response-curve scoring for behaviours.
- Deciding less often for AI far from players.
- Stat modifiers.
- Anti-cheat.
- `TerrainBodyLifter` folding into the terrain edit manager (t1).
- **AI, from the 2026-11-09 decisions:**
  - Hearing and sounds. Sounds with unknown sources would set AIs investigating friendly or neutral AIs once factions exist, and need too many safeguards for t0. Noted for deeper simulation later.
  - Persistence flags (such as counting from when a behaviour ends, clearing on a state change, flipping on failure).
  - A state's priority fading down to a minimum while it's active.
  - Running sensing, pathfinding and other heavy work on background cores.
  - Partial cover (several rays per target) and a ramp that speeds up awareness under a steady gaze.
  - The AI behaving differently because a player has the pawn, built only if a game needs it.
  - Rolling back the AI's decisions, for games where clients predict the AI or use lockstep networking (10.2). The pawns it drives already roll back.
