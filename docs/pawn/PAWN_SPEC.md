<!-- Written by Claude (claude-opus-5-5), 2026-11-07: the new pawn spec, from the owner's 2026-11-07 decisions on the pawn rebuild. A first shape to work from, not finished. Replaces docs/legacy/PAWN_ARCHITECTURE.md, which stays as a guide. -->

# Pawn Spec v0.19

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
- v0.10 (2026-11-09): step 8a built (12). See 10.10 for what differs from the text above.
- v0.11 (2026-11-09): step 8b built (12). See 10.11 for what differs from the text above. Two changes reach back into the earlier sections: a floor only counts when its behaviour is available (10.8, step 3), and uncertain entries stay at full awareness for 5 s before fading (10.5). Later the same day: `spotted` was renamed `certain` (the owner's call), and the fade delays became their own settings on `AIMemory`.
- v0.12 (2026-11-09): memory, sight checks, target scoring and the nearby-pawns query moved to C++, the owner's call, with every setting still on the GDScript nodes and a GDScript fallback (10.12). Behaviours tick every `tick_interval_ticks` (10.7).
- v0.13 (2026-11-09): step 9 built: Dash, MeleeAttack, Knockback, ability interrupt priorities, lag compensation for melee, and the AI's Attack behaviour (8.6).
- v0.14 (2026-11-09): step 10 built: Health as a stat that changes during play, damage, death as an ability, being hit as a state rule, threat from damage (8.7). The owner's call: no health manager.
- v0.15 (2026-11-09): step 11, saving terrain edits: `TerrainEditLog` saves to and loads from a file (12).
- v0.16 (2026-11-09): the t0 test level, `arena_sample.tscn` (12, step 12, pulled forward at the owner's request). Attack moved to the left mouse button. What a whole pawn costs per tick, `pawn_stress` (12.1), with open question 16.
- v0.19 (2026-11-09): tick foundations for tier 1 (15): the per-tick contract, gates and channels in abilities, resting pawns, hits delivered after simulate. The owner asked for the prep work.
- v0.18 (2026-11-09): rollback recording in C++ (`TickStateRecorder`) and saved only where it's read (`history_interval_ticks`), measured in 12.1. Open question 16 settled.
- v0.17 (2026-11-09): debug shapes for swings and dashes (`AbilityDebugDraw`), `MeleeAttackAbility.hit_window_started`, Chase's `dash_to_close`, and the arena readout's last ability (8.6, 10.7, 12).

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
- **Today (2026-11-09, after step 8b):** `pawn.tscn` holds `CollisionShape3D`, `Visual`, `TickState` and `NetworkEntity`. `PawnInitializer` adds `ControllerManager` (with `AIController`), `NavigationManager`, `StatManager` (with the movement stats), `AbilityManager` (with Walk, Sprint and Jump), `AIContextComponent`, `AISensingManager` (with Sight), `AIMemory`, `AITargetSelector`, `AIStateManager` (with Idle, Alert and Combat) and an empty `AIBehaviourManager`.

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

### 8.6 Step 9: Dash, MeleeAttack, knockback and cancelling (built 2026-11-09)

Agreed with the owner before building; the decisions are in the step 9 notes below.

**Cancelling: interrupt priorities for abilities.** It's the same scheme as behaviours (10.7).
- **Conflict:** two abilities conflict when either one's `locks_out` covers the other's category.
- **The rule:** a conflicting ability can start only if its `interrupt_priority` is at least the `interrupt_threshold` of every conflicting ability running. Those are cancelled (they stop and start their cooldowns, and `ability_cancelled(ability, by)` goes out), and it starts. Otherwise it's locked out, as before.
- **Defaults:**

  | Ability | `interrupt_priority` | `interrupt_threshold` |
  |---|---|---|
  | Walk | 0 | 0 |
  | Jump | 5 | — |
  | Sprint | 10 | 0 |
  | MeleeAttack | 15 | 15 |
  | Dash | 20 | 25 |
  | Knockback | 30 | 100 |

  100, the base default, means nothing in t0 can cancel it.
- **What that gives:**
  - Dash cancels a swing: the player's animation cancel.
  - Sprint and Jump don't cancel a swing.
  - Knockback staggers a swing or a dash.
  - An action with threshold 10 or less (a reload, say) is cancelled by sprinting, like CoD's sprint cancel.
  - An action with threshold 0 (an emote) is cancelled by just moving.
- **Where the rules live:** in the abilities, checked by `AbilityManager`. Controllers only send the inputs, so a player and the AI cancel the same way, and a rollback replay gets the same cancels.
- **`start_ability(ability)`** starts an ability with no trigger action, such as Knockback, by the same rules.
- **Cancel windows** (cancellable only during some phases, such as recovery) are deferred (section 14).

**`DashAbility`** (`&"dash"`, a new action, Left Alt for players):
- **Speed and length:** the `DashSpeed` stat (18 m/s, a new stat) for 0.15 s, 9 ticks, about 2.7 m.
- **Direction:** the way the pawn is moved, or the way it faces when standing still.
- **Ground only:** no air dash.
- **Locks out** walking, sprinting and jumping. Cooldown 1 s.
- **Ending:** it cuts horizontal speed to `MoveSpeed` (`exit_speed_stat`), so it stops crisply. Without this, Walk eased 18 m/s down over several metres; it was measured at 10.6 m in all.
- **Rollback:** its direction rolls back.

**`MeleeAttackAbility`** (`&"primary"`, the left mouse button for players; it was F until the pawn sample's F for raising ground clashed):
- **Phases, in ticks:** `windup_ticks` 8, `hit_ticks` 4, `recovery_ticks` 12. `duration_ticks()`, new on `AbilityBase`, lets an ability count its own ticks.
- **Facing:** it faces the look direction at the start (open question 4), then holds still. Movement and other combat are locked out.
- **`attack_range`** (1.8 m) is the real reach: the hit sphere (`hit_radius` 0.8, at `hit_height` 1.0) sits so its far edge is at that range. (The owner said "range, not reach"; a bare `range` clashes with GDScript's `range()`.)
- **Hits are decided on the server only,** during the hit ticks, never during a rollback replay:
  - each pawn at most once per swing
  - its own team skipped unless `hits_own_team` is on
  - in a network session, through `LagCompensation.melee`; offline, a plain sphere, since there's nobody to rewind
- **Each hit:**
  - The target's `Pawn.receive_hit(HitInfo)` is called directly. No handshake: the server alone decides.
  - That starts the target's knockback, and `Pawn.hit_received` goes out.
  - Then `hit_landed(hit)` goes out on the ability, for local cosmetics.
- **Multi-hit** *(Claude 2026-11-09, the owner asked)*: one swing hits every pawn inside its sphere during its hit ticks, each at most once, and each gets its own damage and its own knockback. The attacker's team is skipped unless `hits_own_team` is on. Checked in `combat_selftest`. Damage and knockback are the only effects a hit carries; there's no general status effect system yet.
- **`hit_window_started(centre, radius)`** *(Claude 2026-11-09)* goes out once per swing, on its first hit tick, on every machine that runs the swing (the server, offline, and a client predicting its own pawn), never in a replay. It says where the swing can hit, not whether it hit. For effects, sounds and debug drawing.
- **The basic attack has no cooldown** (`cooldown` 0). The swing itself, 24 ticks (0.4 s), keeps another from starting until it ends; a press near the end waits for it (`buffer_window` 0.15 s). Dash's cooldown is 1 s. *(Claude 2026-11-09, the owner asked.)*
- **Debug shapes,** `abilities/debug/AbilityDebugDraw.gd` *(Claude 2026-11-09, the owner's request)*. Not part of the base: a sample or test adds one and calls `watch(pawn)`. See-through shapes that fade out in a straight line:
  - each swing's hit sphere, for `attack_seconds` (2 s). A swing that hits labels its sphere with each pawn it hit and the damage, one per line ("pawn_3 -20"), from `hit_landed`. Only where hits are decided: offline and on the server.
  - each dash's trail, a copy of the pawn's capsule every physics frame, each for `dash_seconds` (1 s)
  - Shown where the abilities run: every pawn offline and on the server, and a client's own pawn.
- **`HitInfo`** holds the attacker, target, ability, tick, direction, knockback speed and knockback ticks. Step 10 adds damage.

**`KnockbackAbility`**, on the pawn being hit (the owner's call):
- **Started by** its `receive_hit()`.
- **Movement:** it moves the pawn through the pawn's own movement, setting horizontal velocity to the push, fading in a straight line over the push's ticks, while movement and combat are locked out.
- **Rollback:** the push rolls back, so a client whose pawn is knocked back is corrected and replays it.

**Lag compensation (the owner asked for it from the start):**
- **The input:** `view_ticks_behind` is in the pawn's input list (`pawn.tscn`). `PlayerController` fills it from `NetworkSession.get_view_ticks_behind()`, and the AI sends 0.
- **On the server:** `sanitize_network_input` clamps it to 0 or more and finite, and `LagCompensation` limits how far back it really goes.

**`AIAttackBehaviour`** (Combat):
- **When:** it's available when the current target's last known position is within MeleeAttack's `attack_range` minus `approach_margin` (0.3 m). The AI steps a little closer than the real reach, and changing the range changes both.
- **What it does:** it faces the target, presses `&"primary"`, and finishes when the swing is over.
- **Score and interrupts:** score 0.9, above Chase's 0.8; interrupt threshold 15.
- **Chase:** its `stop_distance` is now 1.2 m, inside 1.8 − 0.3.

**Defaults:**
- The default `AbilityManager.tscn` now holds Dash, MeleeAttack and Knockback, after Walk, Sprint and Jump.
- `StatManager.tscn` has `DashSpeed`.
- New entries go at the end of their lists, so earlier bits don't change: the `combat.knockback` tag and the `dash` action.
- New input-map keys `move_dash` and `attack_primary`, both in `project.godot`.

**Tests:** `abilities/tests/combat_selftest` (35 checks):
- dash: speed, length, direction, ground only, cooldown, jump locked out
- the cancel rules: sprint doesn't cancel a swing, dash does, knockback cancels a dash, walking cancels an emote, sprinting cancels a reload
- hits: only in the hit ticks, once per target, not beyond range, not own team
- knockback direction
- what rolls back
- no hits on a client, and none again in a replay
- `view_ticks_behind` sanitizing
- a goblin chasing, switching to Attack and landing the swing

**Not built:**
- damage, death, and being hit as a state rule (step 10) *(built, 8.7)*
- invulnerability during a dash
- cancel windows
- combos
- hit effects on clients

### 8.7 Step 10: Health, damage and death (built 2026-11-09)

The owner's call: there's no health manager. Health is a stat, and death is an ability.

**Health:**
- It's a `Stat` with the new `changes_during_play` setting. Its `value` (100) is its most, and its `current` goes from 0 up to that.
- `current` starts full, is rollback state listed by `StatManager`, and reaches clients in snapshots.
- Only the server changes it, with `StatManager.change_current(&"Health", amount)`. `Pawn.get_health()` reads it.

**Damage:**
- `HitInfo.damage`; MeleeAttack's `damage` is 20.
- `Pawn.receive_hit()`, on the server, in this order:
  1. The AI notes the hit (`AIContextComponent.note_hit`), which wakes a decision.
  2. Memory adds threat to the attacker's entry: damage × `AIMemory.threat_per_damage` (0.01).
  3. Health goes down. At 0 the pawn dies, and the rest is skipped.
  4. Knockback starts.
  5. `hit_received` goes out.
- A dead pawn, and a client, ignore hits.

**`DeathAbility`** (in the default `AbilityManager`):
- **Started when Health reaches 0.**
- **Locks out** movement, combat and utility, so Walk stops steering and the body slows to a stop.
- **Interrupts:** priority 1000 cancels whatever was running, and threshold 1000 means nothing cancels it.
- **It keeps itself running while Health is 0.** `Pawn.revive()` refills Health, and it ends on its next tick.
- **While it runs, `Pawn.is_dead()` is true:**
  - the pawn ignores its input and its AI, whose running behaviour stopped with the reason "died"
  - other pawns' sight skips it, in both memory stores
  - memories forget it on their next pass
- **`Pawn.died(pawn, hit)`** goes out once.
- **What the base doesn't decide:** the body stays where it falls. Removing it, a death animation or respawning are game rules.

**Being hit, as a state rule** (10.6):
- `AIAwarenessState` gained `hit_within_ticks` and `attacker` (`ANY`, `KNOWN`, `UNKNOWN`).
  - Combat: hit within 120 ticks by an attacker in memory.
  - Alert: hit within 300 ticks by one that isn't.
- There's no damage sense and no memory entry for an unknown attacker: the context keeps `last_hit_from`. Look Toward and Investigate head there within `hit_memory_ticks` (300) when nothing in memory is half-noticed. Once the pawn looks, sight usually finds the attacker.

**New:** the `status.dead` tag, added at the end of the list.

**Tests:** `abilities/tests/fight_selftest` (22 checks):
- Health and what rolls back
- five hits kill, `died` goes out once, a hit on a dead pawn does nothing
- a dead pawn ignores input and abilities
- revive
- a client ignores hits
- an unknown attacker gives Alert, and Look Toward turns to see it
- a known attacker gives Combat, and threat is added
- a dead pawn is forgotten
- a goblin fights an intruder to the death, then leaves Combat

**Not built:**
- other ways to take damage (a ranged attack, a hazard)
- healing abilities
- the base removing bodies
- shields and resistances

---

## 9. Stats (built 2026-11-07, step 5)

- `StatManager` holds `Stat` nodes, in `assets/scripts/stats/`. One node per stat, named after it: MoveSpeed, JumpVelocity and so on.
- Abilities and behaviours read stats through the manager by name (`get_value(&"MoveSpeed", 5.0)`), and each read has a fallback, so a missing stat is never a crash.
- The default part `scenes/pawn/parts/StatManager.tscn` holds the movement stats `GroundMovement` used to hold, at the same values: MoveSpeed 5, SprintSpeed 9, Acceleration 30, Deceleration 40, AirControl 0.3, TurnRate 720 and JumpVelocity 5.
- **Later:**
  - Stats that change during play (Health, Stamina) will be rollback state. The movement stats don't change yet, so none roll back today. *(Claude 2026-11-09: built for Health, step 10: `changes_during_play`, 8.7.)*
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
| `AIMemory` | One entry per sensed entity: where it was last seen, when, how aware of it the pawn is, whether it ever became certain (reached full awareness), and its threat. Entries fade and are forgotten | Maybe, with sensing. Fading costs nothing in the background (10.5) |
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
  func value_at(ticks: float) -> float   # 1.0 at the start, falling to 0.0. A float, so a fade can run at another speed
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
- **Cheap refresh between passes.** Every `refresh_interval_ticks` (5), `SightSense` checks the current target with one line-of-sight ray, and a hit counts as seeing it. This keeps a tracked target fresh without a full pass. *(Claude 2026-11-09, as built: this said "each entity already in memory". In a crowd, that cost more than the full passes, ai_stress in 10.11.)*
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

So someone close and in front becomes certain in half a second, which is basically instant. Someone 20 m away at the edge of the periphery takes several seconds.

**Detectability belongs to each game.** The pawn exposes `detectability`, defaulting to 1.0, and nothing in the base changes it. How it's worked out is a game rule, so it goes in an optional `GameMode` module that sets it every so often. A cloak giving +10 stealth might be a fixed percentage in one game and a DC roll in another. Light level and similar modifiers fold into the same number, so sensing never calls game code for each pair of pawns. t0 has no such module, so every pawn is at 1.0.

### 10.5 Memory

Each entry holds:
- the entity (its id)
- `last_known_position`, updated whenever it's seen
- `last_seen_tick`
- `awareness_when_seen`: awareness at the last sighting, from 0 to 1
- `certain`: set the first time awareness reaches 1, cleared when the entry is forgotten. *(Claude 2026-11-09: was `spotted`; renamed by the owner, with uncertain for the opposite.)*
- `threat`: added to by game mechanics, 0 in t0 (target selection, below)

Kept as packed arrays, one per field, so a port to C++ is mechanical (10.1).

**How awareness moves:**
- Sight adds gain (10.4), up to 1.
- Seeing an entity it's already certain of refills it to 1 at once. A guard who knows you're there doesn't need to notice you again.
- **While it isn't seen, it fades by a `FadeProfile`** (10.2): awareness now = `awareness_when_seen × profile.value_at(ticks since seen)`. There are two settings on `AIMemory`:
  - `uncertain_fade` for uncertain entries: default `LINEAR`, `fade_ticks` 300 (5 s), after `uncertain_fade_delay_ticks` (300, 5 s) at full awareness. *(Claude 2026-11-09, as built: with no hold, a glimpse that just reached Alert's 0.3 dropped back below it within a few ticks, so the goblin turned and forgot at once.)*
  - `certain_fade` for certain entries: default `LINEAR`, `fade_ticks` 1200 (20 s), after `certain_fade_delay_ticks` (0).
  - *(Claude 2026-11-09: the delays are separate settings on `AIMemory`, the owner's request, so designers tune them without opening a `FadeProfile`.)*

  With the default straight line, an entry is forgotten that many ticks after it was last seen, whatever its awareness was. That's easy to predict. A designer wanting a slow start and a quick end draws a `CURVE` instead, with no code.
- **Nothing drains in the background.** Awareness is worked out when something asks, from two stored numbers and the current tick, the same trick as persistence. An entry is forgotten once its profile's `ends_after()` has passed. So there's no loop over every entry each tick, which also takes memory draining off the C++ list.

**What memory answers:** for any entry, its awareness now, whether it's certain, ticks since seen, and last known position. Behaviours read these through the context's shared inputs (10.8).

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

**Memory wakes a decision early** (10.9) when a new entity is added or an entry becomes certain, so a pawn reacts the moment it's sure of someone rather than at its next decision tick.

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
| `requires_certain` | needs the certain flag |
| `max_ticks_since_seen` | seen within this many ticks; -1 = any |
| *step 10:* `hit_within_ticks` | or was hit within this many ticks; -1 = off |
| *step 10:* `attacker` | for the hit: `KNOWN` (in memory), `UNKNOWN` or `ANY` |

A state with rules no settings cover is a script that extends `AIStateBase` and overrides `prerequisites_met`.

**The t0 states**, highest priority first:

| State | Script | Priority | Settings | Behaviours |
|---|---|---|---|---|
| **Combat** | `AIAwarenessState` | 20 | current target, certain, seen within 120 ticks (2 s). *Step 10:* or hit within N ticks by a known attacker | Chase (Attack comes with MeleeAttack, step 9) |
| **Alert** | `AIAwarenessState` | 10 | any entry at awareness 0.3 or more. *Step 10:* or hit within N ticks by an unknown attacker | Look Toward, Investigate, Search |
| **Idle** | `AIIdleState` | 0 | none: always fits | Wander |

**How it plays:**
1. A goblin glimpses the player at the edge of its vision. Awareness creeps to 0.3: **Alert**. Look Toward and Investigate score highest, so it turns and walks over.
2. The player stays visible. Awareness reaches 1 and the entry is certain: **Combat**. It chases.
3. The player ducks behind a rock. After 2 s unseen, Combat's prerequisites fail: back to **Alert**. The certain entry fades slowly, so the goblin stays Alert for a while, and Search scores highest because the entry is certain but stale. It runs to the last known position and searches.
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
@export var tick_interval_ticks := 1   # Claude 2026-11-09: while running, tick() is called every this many ticks
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
- **`cannot_be_interrupted`** runs until it returns SUCCEEDED or FAILED, even if its state no longer allows it. Use it sparingly. Only the pawn being removed still ends it, and `exit` gets the reason "removed". While the AI is paused (10.3), it pauses with it and carries on afterwards. *(Claude 2026-11-09, as built: pausing doesn't end behaviours, so nothing needs to start again after a player lets go.)*

Code can change a behaviour's threshold while it's running, through `behaviour_manager.set_interrupt_threshold(&"Chase", 25)`, such as a berserk effect.

**Hard gates stay separate.** `cooldown_ticks` and `min_run_ticks` are promises a designer can rely on, not tendencies. They're checked before any scoring, and they read the same start and end ticks as persistence. The minimum run time also stops a behaviour with negative persistence from swapping back and forth every decision.

**Jitter per behaviour.** *(Claude 2026-11-09, from the owner's review.)* Each behaviour has its own `score_jitter`. -1, the default, uses the manager's `default_score_jitter`, which is 0. Code can change it while running, with `behaviour_manager.set_score_jitter(&"Wander", 0.2)`, for a confused or drunk effect, say.

**t0 behaviours:**

| Behaviour | States | What it does | Step |
|---|---|---|---|
| Wander | Idle | Walks to a random reachable point nearby with `move_to`, pauses, and picks another | 8a |
| Look Toward | Alert | Stops and faces the last known position of the most aware entry | 8b |
| Investigate | Alert | Walks, without sprinting, to the last known position. Scores highest for an uncertain entry | 8b |
| Search | Alert | Runs to the last known position, then walks to a few random points around it. Scores highest for a certain entry that's stale | 8b |
| Chase | Combat | Follows the current target (10.5), holding `&"sprint"`, finding a new path every so often rather than every tick . Stops within 1.2 m (2026-11-09). *Claude 2026-11-09:* with `dash_to_close` on (off by default), it presses `&"dash"` when the target is 4 to 6 m away (`dash_to_distance`, `dash_from_distance`) and Dash can start | 8b |
| Attack | Combat | Within MeleeAttack's `attack_range` minus `approach_margin`, faces the target and presses `&"primary"` (8.6) | 9 |

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

   *(Claude 2026-11-09, found in step 8b:* a floor is only certain if its behaviour is available. Search has a fixed score, 0.7, but only applies once it became certain of an enemy, and its floor would otherwise shut out Look Toward, at 0.6, even when Search didn't apply. So the highest floor comes from the first available behaviour, checking from the highest floor down. That's usually one `is_available()` call, and the answer is kept for step 4.*)*
4. **Scoring,** highest ceiling first. Each survivor's `is_available` and `score` run, and its persistence and jitter are added. As soon as the next ceiling can't beat the best result so far, the rest are skipped. A behaviour that doesn't set `min_score` gets its floor from this step, from real scores, so a behaviour scoring below its max never prunes one that would have won.
5. **Jitter:** each behaviour gets its own offset at each decision, within ± its own `score_jitter` (10.7). The offset is a hash of (seed, pawn id, tick, behaviour name), so it doesn't depend on order or on which behaviours were skipped. The seed comes from the world seed, so a replay makes the same choices.
6. **Ties:** results within a small margin are a tie. With `randomize_ties` (default off) one is picked by the same hash. Otherwise the fixed order decides.
7. **Switching:** if the winner isn't the running behaviour, the old one's `exit` runs, then the new one's `enter`, and its persistence countdown starts.

Between decisions, only the running behaviour's `tick` runs, once per tick. When it returns SUCCEEDED or FAILED, the manager decides at once.

**Shared inputs** on the context: values many behaviours read, such as the current target, its distance, whether it's certain and how stale it is, and the most aware entry. Later, own health fraction and the last hit. They're worked out the first time something asks during a decision and kept until the next one, so if nothing asks, they cost nothing.

### 10.9 Timing and load

- **Decisions:** every `decision_interval_ticks` (15, four a second). In t0, each pawn is offset by its id, so a crowd doesn't all decide on the same tick. Whether a central queue with a budget replaces this is open question 11.
- **Woken early,** on the same tick: a new entity in memory, an entry becoming certain, a state change, a forced state, or the running behaviour finishing.
- **Sensing:** a full pass every 10 ticks and the cheap refresh every 5 (10.4), offset by pawn id the same way.
- **The running behaviour** ticks every tick. It should stay cheap: Chase finds a new path every so often, not every tick.
- **Later:** background threads for sensing and pathfinding (section 14). The main thread copies plain data, a worker does the work, and the result is used the next tick. The AI runs only on the server and is never rolled back, so a tick of delay costs nothing.

### 10.10 Step 8a, as built (Claude 2026-11-09)

**Where things are:**
- **Scripts:** `assets/scripts/ai/`:
  - `FadeProfile.gd`, `AIContextComponent.gd`
  - `AIStateManager.gd`, `AIStateBase.gd`, `states/AIIdleState.gd`
  - `AIBehaviourManager.gd`, `AIBehaviourBase.gd`, `behaviours/AIWanderBehaviour.gd`
- **Part scenes:** `assets/scenes/pawn/parts/AIContextComponent.tscn`, `AIStateManager.tscn` (with an Idle state) and `AIBehaviourManager.tscn` (empty), all three listed in `resources/pawn_defaults.tres`.
- **The pawn's AI step:** `Pawn._tick_ai`, called at the start of the pawn's input phase. Also on `Pawn`:
  - `runs_ai_here()`: offline, or on the server
  - `get_network_entity()`
  - `ai_context`, `ai_state_manager` and `ai_behaviour_manager`

**What differs from, or adds to, the text above:**
- **The default behaviour list is empty.** Every pawn gets the three AI parts, but no behaviours, so it stands still. That keeps everything that drives `AIController` directly working: samples, tests, and a game's own scripts. A pawn that should wander gets a Wander node, with the class `AIWanderBehaviour`, under its `AIBehaviourManager`.
  - An empty behaviour manager does nothing at all.
  - With behaviours but none able to run, the pawn stands still (`release_all`).
- **Decisions are asked for through the context.** `AIContextComponent.request_decision(priority, normal)` combines every reason for a decision in one tick into one decision, using the strongest reason: a decision tick, a state change, a force, or a force ending. The behaviour manager uses it up.
- **Random numbers:** `AIContextComponent.random_unit(salt)` is a small integer hash of (seed, pawn number, tick, salt), so nothing is stored between calls.
  - The pawn number is its network `entity_id`, or a hash of its name offline.
  - `random_seed` is a setting on the context, 0 by default, which a game can set from its world seed.
- **A forced state that runs out** hands back to the normal check on that tick (`check_force_expiry`), not at the next decision.
- **The AI controller:**
  - While it isn't in charge, `move_to` remembers the point and returns true. `stop`, `move_in_direction` and `release_all` forget it, and none of them touch the player's path.
  - `is_following_order()` says whether its own walk is still under way. Behaviours use it rather than reading `NavigationManager`, so they work the same whether or not the AI is in charge.
- **`min_run_ticks` 0 means no minimum at all,** even for a decision at an earlier tick than the behaviour started.

**Tests:** `ai/tests/`, 106 checks between them:
- `fade_profile_selftest` (18)
- `ai_state_manager_selftest` (24)
- `ai_behaviour_manager_selftest` (64): every decision step, persistence, interrupts, Wander, the three `while_possessed` settings, clients, and rollback

`game_mode/tests/pawn_initializer_selftest` lists the three new default parts.

**Not built yet:** step 8b (10.4, 10.5, Alert and Combat, and the other behaviours), and the debug readout (open question 10). *(Claude 2026-11-09: 8b is built now, see 10.11.)*

### 10.11 Step 8b, as built (Claude 2026-11-09)

**Where things are:**
- **Scripts:** `assets/scripts/ai/`:
  - `AISensingManager.gd`, `AISenseBase.gd`, `senses/SightSense.gd`
  - `AIMemory.gd`, `AITargetSelector.gd`, `states/AIAwarenessState.gd`
  - `behaviours/AILookTowardBehaviour.gd`, `AIInvestigateBehaviour.gd`, `AISearchBehaviour.gd`, `AIChaseBehaviour.gd`
- **Part scenes:** `AISensingManager.tscn` (with a Sight node), `AIMemory.tscn` and `AITargetSelector.tscn`, added to `resources/pawn_defaults.tres`. `AIStateManager.tscn` now holds Idle, Alert and Combat, with the settings in 10.6.
- **On `Pawn`:**
  - `team` and `detectability` settings
  - `count_pawns_not_on_team()`, which counts the pawns in the tree on other teams
  - `ai_sensing_manager`, `ai_memory` and `ai_target_selector`
- **The AI step order:** sensing every tick it's due; then, on decisions, target, then state, then behaviour (`Pawn._tick_ai`).

**What differs from, or adds to, the text above:**
- **Which way the eyes face:**
  - with a look target (`look_at_point`): where the AI looks
  - otherwise: the way the body faces
  - while a player has the pawn: where the player looks

  `AIController.is_looking_at_point()` is new for this. Look Toward turns the eyes, not the body, so the model doesn't turn yet. Turning on the spot is open question 4 (facing).
- **The sight ray:** from 1.6 m above the feet to 1.0 m above the target's feet. Only `sight_blocking_mask` blocks it: layer 1, the world, by default. Pawns don't hide each other.
- **The time factor is capped at `max_gain_ticks` (30)**, so a long gap without checks doesn't give a huge gain at once.
- **Memory fades only while unseen.** Sightings at most `continuous_sighting_ticks` (30) apart, with no unseen check between them, count as one continuous look, so awareness doesn't fade between them. Without this, a target in plain view filled about 3% slower.
- **Uncertain entries stay at full awareness for 5 s before fading** (10.5, `uncertain_fade_delay_ticks`).
- **The sensing query** is a physics sphere on layer 2, returning at most `max_candidates` (32). It's skipped entirely when no pawn of another team is in the tree. This goes part of the way on open question 12.
- **Look Toward, Investigate and Search apply through `is_available()`, with fixed scores (min = max).**
  - Look Toward and Investigate apply while the most aware entry is uncertain.
  - Search applies while it is.
  - In Alert, with Look Toward and Investigate both on cooldown, nothing applies, and the pawn stands still until one does.
- **Behaviour defaults:**

  | Behaviour | Score | Cooldown | Other defaults |
  |---|---|---|---|
  | Look Toward | 0.6 | 180 ticks | looks for 60 ticks |
  | Investigate | 0.5 | 120 ticks | repaths when the last known position moves 2 m; arrived within 1 m |
  | Search | 0.7 | none | 3 points within 5 m, 30-tick pauses, sprints to the centre |
  | Chase | 0.8 | none | new path every 20 ticks or when the target moves 1.5 m; stops within 1.5 m; sprints |
- **Every t0 behaviour ticks every 5 ticks** (`tick_interval_ticks`, new in the base class, default 1). The AI controller follows paths every tick on its own, so a behaviour only re-aims. Timers inside behaviours count ticks with `context.current_tick`, not `tick()` calls, so they last the same at any interval.
- **Context shared inputs:** `current_target_index()` and `most_aware_index()`, worked out once per tick. Also `memory` and `target_selector`.

**Tests:** `ai/tests/`:
- `ai_perception_selftest` (53): memory, each part of sight's gain, eyes, teams, sensing on schedule and while possessed, and target selection.
- `ai_stealth_selftest` (18): the walkthrough in 10.6 with a real goblin and intruder, plus "never noticed" for a friend and an invisible pawn.
- `ai_stress` isn't pass/fail. It prints the AI's cost per tick for 50 to 400 pawns (numbers below). Switches: `--breakdown` (each part timed), `--no-sensing`, `--no-behaviours`, `--no-refresh`.

**Stress numbers** (Windows, the owner's PC, 2026-11-09). This is the worst case: two teams mixed on a grid 4 m apart, so every pawn has the 32-candidate maximum in sight and is fighting. The AI's cost is measured in TickDriver's input phase, with and without the AI parts.

| Pawns | AI per tick | Per pawn |
|---|---|---|
| 50 | 1.3 ms | 0.026 ms |
| 100 | 2.7 ms | 0.027 ms |
| 200 | 6.5 ms | 0.033 ms |
| 400 | 12.5 ms | 0.031 ms |

It grows in a straight line with the number of pawns. `ai_stress -- --breakdown` times each part through test-only subclasses. At 200 pawns, per tick:

| Part | ms | Notes |
|---|---|---|
| Sensing | 4.5 | the nearby-pawns query, 1.5 (about 61 µs each: Godot's shape query builds a dictionary per result); rays, 0.6 (about 2.7 µs each, about 220 a tick); the rest is GDScript per check: angle and distance maths and memory updates |
| Target selection | 1.1 | about 47 µs a call, scoring 32 entries |
| Asking the AI controller for input (path following) | 0.6 | |
| Running behaviours | 0.6 | Chase 0.6; path requests only 0.05 |
| Decisions | 0.4 | |
| State checks | 0.2 | |

Five fixes found with these measurements brought it down from 0.067 ms per pawn:
- The refresh checks only the current target, and sight works out its eyes once per pass.
- The two shared inputs are worked out separately.
- `tick_interval_ticks` on every behaviour (10.7); the t0 behaviours tick every 5. Chase went from 1.8 ms to 0.6 ms, because it had been repeating about a dozen small GDScript calls every tick, each costing 0.3 to 1.5 µs.
- Chase only calls `stop()` when it isn't already standing, and looks up its hands and memory once, in `enter()`.
- `AIMemory` looks entries up by id, not by searching. That barely changed these numbers, but it keeps lookups cheap for larger memories.

What was left was mostly sensing and target selection, both loops over plain data, so they moved to C++ (10.12). Fewer enemies in sight costs less, because sensing, target scoring and Alert's check all loop over what's in memory.

### 10.12 The C++ port (Claude 2026-11-09)

The owner's rule: port code that isn't hard coded and stays tunable from GDScript. Settings stay exported on the GDScript nodes and are handed to C++, and C++ runs the loops. It follows the same pattern as `NetCodec`: C++ when the navcore library loads, and the same thing in GDScript otherwise.

**What moved, in `native/src/`:**
- **`AIMemoryStore`** (`ai_memory_store.h/.cpp`), one per pawn. It holds memory's entries and does:
  - the awareness maths and fades. It reads each `FadeProfile`'s settings: mode, hold, fade, half-life and curve, sampled from the `Curve` itself. A profile whose script overrides `value_at()` is called instead, so a designer's own fade still works.
  - forgetting
  - the most aware entry
  - target scoring, with `AITargetSelector`'s formula
  - the sight check loop: angle, distance, detectability, rays and memory updates
- **`AIPawnGrid`** (`ai_pawn_grid.h/.cpp`), one shared by every pawn. It's a grid of every pawn, rebuilt at most once a tick on the first query, and returns the nearest pawns of other teams first. That answers open question 12: the `max_candidates` cap keeps the nearest. It replaces the physics shape query.

**The GDScript side:**
- **`AIMemory`** keeps every setting, both signals and the functions it had, and passes calls to its store. It picks `AIMemoryStore` (C++) when the class exists, or **`AIMemoryStoreGD`**, the old code moved into the same functions.
  - `AIMemory.use_native = false` forces GDScript for every memory made after it.
  - Fade settings are handed over whenever one changes, and again on every full pass, so edits inside a profile while the game runs apply within a pass.
- **`SightSense`** hands each pass to the store with its settings. `visibility_of()` and `has_line_of_sight()` stay in GDScript, for tests and debug readouts.
- **`AISensingManager`** uses the grid when the C++ library is there (`track_pawn` and `untrack_pawn`, called from `Pawn`), or the physics query otherwise.
- **`AITargetSelector`** has the store score every entry, unless its script overrides `target_priority()`. It notices that when ready, and then scores each entry in GDScript with the override, so a game's own rules always win.

**Kept the same both ways:** `ai_perception_selftest` runs the C++ store by default, and with `-- --gdscript-store` the GDScript one. A new check gives both stores the same calls and compares every answer: awareness for curve, half-life and script-made fades; the most aware entry; the target; and what's forgotten. They match exactly. `ai_stealth_selftest` also passes on both.

**Measured** (the same worst case, 200 pawns, 32 enemies each in sight):

| | GDScript store | C++ store |
|---|---|---|
| AI per tick, 200 pawns | 6.0 ms | 3.2 ms |
| Per pawn per tick | 0.030 ms | 0.016 ms |
| 400 pawns | 12.0 ms | 7.1 ms |

The C++ breakdown at 200 pawns, per tick:

| Part | ms |
|---|---|
| Sensing | 2.2 |
| …of which sight checks and rays | 1.0 |
| …of which the grid query | 0.4 |
| Chase | 0.7 |
| Asking the AI controller for input | 0.6 |
| Decisions | 0.4 |
| States | 0.2 |
| Target selection | 0.2, from 1.1 |

What's left is spread thin: the GDScript calls into C++ each pass, behaviours, and decisions.

**Not done:**
- ~~The Linux library hasn't been rebuilt.~~ *(Claude 2026-11-09: rebuilt, and every suite passed on Linux, the long network tests included.)*
- Background threads (section 14) are still later.

**Not built yet:**
- ~~being hit as a prerequisite (step 10)~~ *(built 2026-11-09)*
- ~~Attack (step 9)~~ *(built 2026-11-09)*
- the debug readout (open question 10)
- turning on the spot (open question 4)

---

## 11. `PawnInitializer` (built 2026-11-07, step 4)

- A `GameMode` module. The pawn calls `GameMode.pawn_initializer.initialize(self)` from its own `_enter_tree`.
- It adds each default part the pawn doesn't already have. A part placed in the pawn's scene is kept as it is, so a designer can override any default by adding their own with the same name.
- **The defaults file:**
  - `resources/pawn_defaults.tres`, a `PawnDefaultsRes` listing part scenes. The project setting `project_base/game_mode/pawn_defaults` can name another.
  - For t0 it lists today's parts: `scenes/pawn/parts/ControllerManager.tscn` (with its `AIController`), `NavigationManager.tscn`, `StatManager.tscn`, `AbilityManager.tscn`, and, from step 8, `AIContextComponent.tscn`, `AISensingManager.tscn` (with Sight), `AIMemory.tscn`, `AITargetSelector.tscn`, `AIStateManager.tscn` (with Idle, Alert and Combat) and `AIBehaviourManager.tscn` (with no behaviours). *(Claude 2026-11-08: this line still named `GroundMovement`.)*
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
   - **8a, deciding:** **(Built 2026-11-09, see 10.10.)**
     - `FadeProfile`
     - `AIContextComponent` with `while_possessed`
     - `AIStateManager` with priority picking and forced states with priorities
     - `AIBehaviourManager` with interrupts, gates, ranges, jitter per behaviour, ties, the fixed order and persistence
     - `AIController` keeping its last order while not in charge

     An Idle state and Wander prove it, with no senses. Decisions offset by pawn id.
   - **8b, noticing:** **(Built 2026-11-09, see 10.11.)**
     - the `team` number and `detectability` on the pawn
     - `AISensingManager` with `SightSense` and the cheap refresh
     - `AIMemory` with awareness that fades by profile
     - `AITargetSelector` with `force_target`
     - Alert and Combat as `AIAwarenessState` nodes
     - Look Toward, Investigate, Search and Chase

     Then a stress-test run with a few hundred AI pawns, to decide whether sensing and memory move to C++.
9. **More abilities:** Dash, then MeleeAttack. **(Built 2026-11-09, see 8.6.)** Also Knockback, ability interrupt priorities, lag compensation for melee, and the AI's Attack behaviour.
10. **Teams and the fight loop:** damage, death. Being hit becomes an Alert and Combat prerequisite (10.6), and damage adds threat for target selection (10.5). **(Built 2026-11-09, see 8.7.)**
11. **Leftovers from t0:** pawns not stacking, saving terrain edits.
   - **Saving terrain edits:** **(built 2026-11-09)**
     - `TerrainEditLog.save_to_file()` and `load_from_file()` store the log as a "PBTE" header followed by its `to_bytes()`.
     - A save writes a temporary file and renames it over the old one, so a crash mid-save never leaves a broken save; loading falls back to the temporary file.
     - Designer settings: `save_path`, `load_on_start`, and `save_every_seconds` (0: only when the log leaves the tree).
     - Only the server or an offline game saves and loads.
     - Missing, broken, or different-ground files are refused, and nothing changes.
     - Tests: in `terrain/tests/terrain_edit_selftest`.
   - **Not built:** merging old edits, so a chunk edited many times builds more slowly. Pawns not stacking.
12. **Playing by hand,** with real Host and Join windows. *(Claude 2026-11-09: the test level is built, pulled forward at the owner's request; the playing by hand itself is the owner's.)*
   - **`assets/scenes/samples/arena_sample.tscn`**, with `samples/ArenaSample.gd`: you against waves of goblins, offline or with Host and Join.
   - **The world** is the pawn sample's: terrain, streaming and nav.
   - **Goblins** (`arena_goblin.tscn`, an inherited pawn scene) are red, on team 1, with all six t0 behaviours.
   - **Keys:** WASD, Shift to sprint, Space to jump, Left Alt to dash, the left mouse button to swing; R for a new wave; Tab to possess a goblin and back; F3 for the readouts.
   - **The readout** over each goblin shows its state, its running behaviour, its awareness of your pawn and its Health. It's sample code; open question 10 is still the base's version.
   - **Deaths are this sample's rules:** bodies are removed after 3 s, and a dead player is revived where they fell after 3 s.
   - **Test:** `samples/tests/arena_sample_selftest`, a headless smoke test: a wave, noticing, a fight, the readouts, a kill, removal, another wave.
   - *(Claude 2026-11-09, the owner's requests:)* debug shapes (`AbilityDebugDraw`, 8.6): swing spheres for 2 s and dash trails for 1 s, hidden with F3. Goblins have Chase's `dash_to_close` on, so a chase switches between Walk, Sprint, Dash and the swing. Each readout shows the goblin's last ability, marked "(running)" while it runs. The test checks the shapes appear and fade, and that chasing goblins sprint, dash and swing.
   - *(Claude 2026-11-09, the owner's request:)* longer cooldowns in this level only (`ArenaSample.DEBUG_COOLDOWNS`), so the switching is easy to see: MeleeAttack 1.5 s, Jump 1 s, Dash 3 s, Sprint 8 s. Knockback and Death keep none: a cooldown on Death would make a revived pawn unkillable for a while. A timer that had no cooldown is registered for rollback when the pawn spawns (`TickStateComponent.add_state_properties`), the same on every machine.
13. **t0 docs:** an overview, plus a reference for every class and function.

### 12.1 What a whole pawn costs (Claude 2026-11-09)

The owner asked for pawn physics diagnostics, to find the next bottleneck after the AI. `pawn/tests/pawn_stress` isn't pass/fail; it prints tables. It puts 100 to 800 pawns on flat ground, one tick per physics frame, in three scenes:
- **standing:** the default parts without the AI, nobody moving. The floor cost of a pawn existing.
- **wandering:** one team, every pawn wandering. Movement and collisions; sensing finds nobody.
- **fighting:** two teams mixed together, with all six t0 behaviours: chasing, swinging, knockback, deaths.

It prints `TickDriver`'s phases (input, which includes the AI; simulate, which is the abilities, gravity and `move_and_slide`; record, which saves rollback state) and Godot's physics frame (the phases plus the physics engine's own step). The physics frame column is a median, because Godot's monitor adds up every step taken in a late frame.

Measured on the owner's PC, Windows, C++ memory store, ms per tick. The budget at 60 ticks a second is 16.7 ms.

| Scene | Pawns | Input + AI | Simulate | Record | All phases | Physics frame |
|---|---|---|---|---|---|---|
| standing | 100 | 0.35 | 1.96 | 4.63 | 8.23 | 10.4 |
| standing | 200 | 0.78 | 4.11 | 8.68 | 16.17 | 21.0 |
| standing | 400 | 1.50 | 7.59 | 17.72 | 32.25 | 35.3 |
| wandering | 100 | 1.12 | 2.63 | 4.52 | 9.60 | 11.0 |
| wandering | 200 | 2.38 | 5.13 | 8.88 | 19.08 | 21.3 |
| wandering | 400 | 4.71 | 9.84 | 18.46 | 38.53 | 42.3 |
| fighting | 100 | 2.21 | 3.20 | 4.47 | 11.37 | 14.3 |
| fighting | 200 | 4.40 | 5.49 | 8.86 | 21.75 | 24.2 |
| fighting | 400 | 9.52 | 11.94 | 19.12 | 46.36 | 50.0 |

800 pawns cost 71, 83 and 97 ms, the same per pawn. Everything grows in a straight line.

**What it shows:**
- **A pawn costs about 0.1 ms per tick,** so about 150 fit in a 60 Hz tick on this PC, on one thread, with nothing else running. Fighting adds about a third.
- **The physics engine itself is cheap:** Jolt's own step is the gap between the last two columns, 2 to 5 ms even at 400 pawns.
- **Recording rollback state is the biggest single cost,** about 45 µs per pawn per tick, more than the abilities and `move_and_slide` together, and more than the AI even in a fight. Every pawn's `TickStateComponent` copies all its listed properties into the history each tick: position, velocity, every ability's timers and Health. It does this offline and on the server too, where nothing ever rolls back. *(Claude 2026-11-09, corrected: the server does read the history, but only the newest tick, and only on snapshot ticks, every 2nd tick at 30 snapshots a second. Recording also rounds the live values each tick, which the server needs so its simulation matches clients' predictions.)* Open question 16.
- **Simulate** is about 20 µs per pawn standing and 30 µs fighting: the abilities in GDScript, and `move_and_slide`.
- **The rest of the phases** (before the tick, capturing input, after the tick) is about 13 µs per pawn.

**After: recording in C++, and saving only what's read** *(Claude 2026-11-09, the owner's call: open question 16, then C++)*. Two changes:
- **`TickStateRecorder`** (`native/src/tick_state_recorder.*`) runs the recording loop: read each property, round it, write it back if rounding changed it, copy it into the history slot. It takes over once every entry is matched to a node and its encoding settled; `TickStateComponent.gd` keeps everything else (matching entries, picking encodings, warnings) and is the fallback where the library is missing. Rounding calls the engine's own `snapped`, `snappedf` and `wrapf`, the functions `StateEncoding.quantize` calls, so the two give the same values by construction. `tick_state_selftest` checks it: 86,884 values and encodings compared, and whole recordings of an entity with every kind of entry, tick by tick, all exactly equal. `TickStateComponent.use_native = false`, or `-- --gdscript-record` in that test, uses GDScript.
- **`TickStateComponent.history_interval_ticks`** says which ticks are saved; the rest are only rounded, so the simulation is the same. `NetworkEntity` sets it: every tick on a client, only snapshot ticks on a server (`NetworkSession.get_snapshot_interval()`), and none offline, where no inputs are saved either. `NetworkEntity.keep_history_offline` turns offline saving back on, for a single-player game that rolls back. Entities `NetworkSession` never configured, as in most tests, save every tick as before.

Measured with `pawn_stress -- --sizes=100,400` and its new `--history=` and `--gdscript-record` switches, ms per tick:

| Scene, pawns | Record: GDScript, every tick (before) | Record: C++, every tick (a client) | C++, every 2nd tick (a server) | C++, never (offline) | All phases: before | All phases: C++, every tick |
|---|---|---|---|---|---|---|
| standing, 100 | 4.75 | 0.44 | 0.41 | 0.38 | 8.41 | 3.93 |
| standing, 400 | 18.89 | 1.91 | 1.62 | 1.52 | 34.33 | 16.31 |
| fighting, 100 | 4.49 | 0.52 | 0.47 | 0.44 | 11.31 | 7.40 |
| fighting, 400 | 19.54 | 1.96 | 1.91 | 1.68 | 47.27 | 28.24 |

- **Recording went from about 47 to about 4.5 µs per pawn per tick,** about 10 times faster. A whole tick at 100 standing pawns went from 8.4 to 3.9 ms; a fighting one from 11.3 to 7.4 ms.
- **Saving less barely matters now:** what's left is reading and rounding each value, which every tick needs; copying it was the cheap part. The history setting is still worth having, since it's free.
- **About 210 fighting pawns fit in a 60 Hz tick on this PC now,** against about 130 before, going by the whole physics frame at 400 (one thread, nothing else running). Standing pawns: about 360, against about 180.
- **The biggest cost now is simulate,** about 19 µs per pawn standing and 29 fighting: the abilities in GDScript and `move_and_slide`.

**Inside simulate** *(Claude 2026-11-09, the owner asked; `pawn_stress -- --breakdown`, through the test-only `TimedAbilityManager`)*. Microseconds per pawn per tick, at 400 pawns (100 was within about 10%):

| Scene | Simulate | Abilities | …locomotion (Walk, Sprint) | …actions (checking presses, running ones) | …counters and locks | The rest: `move_and_slide`, gravity, bookkeeping |
|---|---|---|---|---|---|---|
| standing | 19.2 | 13.7 | 5.9 | 4.2 | 3.6 | 5.5 |
| wandering | 24.3 | 14.1 | 6.2 | 4.2 | 3.7 | 10.1 |
| fighting | 29.9 | 17.1 | 7.2 | 5.7 | 4.1 | 12.8 |

- **The abilities' GDScript is most of simulate: 55 to 70%.** It costs about 14 µs even for a pawn standing still with nothing pressed, because every tick walks every ability: counting cooldowns and buffers down, calling `every_tick()`, rebuilding the locks, checking each action for a press, and Walk reading its stats.
- **`move_and_slide` is the smaller part:** about 5 µs standing and 10 to 13 moving, and it's already engine C++.
- The timing itself adds well under 1 µs per pawn.
- **So the next gain is cheap GDScript work, not threads or C++:** skip what an idle ability doesn't need (counters only for abilities with a cooldown or buffer running, `every_tick()` only where an ability overrides it, the action loop only when something is pressed, buffered or running) and cache stat reads. A guess: abilities from about 14 to about 6 µs standing. Not built; it waits for the owner. Then the AI in a fight (about 22 µs), then the other phases (about 12 µs, mostly saving inputs, still GDScript, which `pawn_stress` pawns do because no session configures them; offline and on a server it's skipped).

---

## 13. Open questions

| # | Question | Current thinking |
|---|---|---|
| 1 | How many ticks a missing input takes to fade | A few ticks; to tune by playing |
| 2 | Where the action list is declared | A resource, like the tag declarations |
| 3 | Combos: one ability with steps, or several abilities chained | One ability for now |
| 4 | Facing: who turns the pawn | Walk faces the move direction; abilities may take over (aiming, attacks). *(2026-11-09: Dash faces its direction and MeleeAttack faces the look direction when they start, 8.6. Turning on the spot without an ability is still open.)* |
| 5 | Teams | **Settled 2026-11-09:** a `team` number on the pawn, enough for sensing to tell friend from foe (10.4). Neutral pawns and factions later |
| 6 | Death | **Settled 2026-11-09:** an ability, `DeathAbility`, started when the Health stat reaches 0 (8.7). The owner's call |
| 7 | Animation: which part plays the Kenney Mini Characters' built-in animations (walk, sprint, jump, die, melee) | Probably a part that listens to the ability manager and `state_changed`. Not decided |
| 8 | Whether `AIMemoryFact` is reused as is, or copied | **Settled 2026-11-09:** neither. Tier 0 uses no legacy code, and memory is packed arrays rather than an object per fact (10.5) |
| 9 | Forced states: does a new force always replace the old one, or does each force carry a priority, so a weaker one can't override a stronger one? | **Settled 2026-11-09:** forces carry a priority, because behaviour interrupts need one (10.6, 10.7). Forced targets use the same rule (10.5) |
| 10 | A debug readout above each AI pawn: state, awareness bars, the top three scores | Claude suggests it early in step 8a, as a debug module outside shipping code: utility AI is hard to tune blind. Not agreed yet |
| 11 | Spreading AI work: each pawn offset by its id, or a central queue that runs at most N decisions and sensing passes per tick (an `AIUpdateScheduler` `GameMode` module), so a struggling host reacts later instead of dropping frames | t0 starts with offsets. Claude suggests the queue, with a count budget rather than milliseconds, so results match across machines. Not agreed yet |
| 12 | A cap on sensing: at most N rays per pass, nearest first | Claude suggests it with the 8b stress test. Not agreed yet |
| 13 | A switch that turns stealth off for a game (awareness fills at once), so autobattler fights start straight away | The default numbers already make close sight nearly instant. Not agreed yet |
| 14 | `personality_jitter`: a fixed score offset per pawn and behaviour, so one goblin is a bit more aggressive than another | Claude's suggestion; could wait. Not agreed yet |
| 15 | The target's value is called `detectability` (1 = normal, lower = harder to detect) rather than "stealth factor" | Claude's suggestion, so the name says what it does. Easy to rename |
| 16 | **Settled and built 2026-11-09** (12.1): recording runs in C++, and is saved only where it's read. The owner's call. Was: recording rollback state only where it's read: a client's predicted entities every tick, the server on snapshot ticks, and offline never. Recording is the biggest cost per pawn (12.1). *(Claude 2026-11-09: this said nothing on the server reads it; snapshots do, see 12.1.)* | Claude suggests it as the first thing to try, before moving recording to C++. Lag compensation keeps its own position history in `NetworkEntity`, so it wouldn't be affected. It changes the netcode core, so it waits for the owner. Not agreed yet |

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
- **Abilities, from step 9 (2026-11-09):**
  - Cancel windows: an action cancellable only during some of its phases, such as recovery. Noted by the owner.
  - Invulnerability during a dash, combos, and hit effects shown on clients.

---

## 15. Tick foundations: t0 prep for tier 1 *(Claude 2026-11-09)*

**Why.** Tier 1 moves server-side work to plain data on worker threads: AI sensing and thinking, then crowd movement (section 12.1, and the owner's scheduler: work that doesn't fit on the main thread overflows to workers, with results due on a fixed tick). That only goes smoothly if the tick already has clear rules about what runs when and who writes what. The owner's words: "solidify the foundations so later work like this we build on it is rock steady". The owner asked for this prep and left the spec to Claude's judgement; it isn't separately agreed.

**Not in t0:** the scheduler, worker threads, the shared table of pawn data, crowd movement and flowfields.

### 15.1 The per-tick contract

One tick runs these phases, for every pawn, in a fixed order (`TickDriver`):

| Phase | What runs | A pawn may write | It may read |
|---|---|---|---|
| before tick | snapshots applied, corrections (clients) | — | — |
| input | AI (server and offline), then the controller in charge | its own input, its own AI parts | other pawns' positions and teams, its own memory |
| capture | inputs saved for replays and snapshots | — | — |
| simulate | abilities, gravity, `move_and_slide` | **only itself**. Effects on another pawn, such as a hit, are queued (15.4) | other pawns' positions, through physics |
| after simulate | queued hits delivered, in a fixed order | the pawn being hit | the hit |
| record | rollback state rounded and saved (`TickStateRecorder`) | its own listed properties (rounding) | — |
| after tick | snapshots sent (server) | — | — |

**The rules:**
1. **Pawns are processed in a fixed order** in every phase: the order they joined the tick driver, which on a server is the order of their entity ids. A result must never depend on another pawn having gone first in the same phase, which is what will let tier 1 run one phase's pawns in parallel.
2. **In simulate, a pawn writes only itself.** Anything aimed at another pawn is queued and delivered after simulate (15.4).
3. **Reads of other pawns in the input phase see last tick's results,** because nothing has moved yet this tick. Tier 1's shared table works the same way: jobs read a frozen copy of tick T-1 and write only their own slots.
4. **Every piece of per-tick logic needs a reason to run** (15.2, 15.3). Idle logic costs nothing.

**Known exceptions, for tier 1 to tidy:**
- Sensing reads other pawns through the shared `AIPawnGrid`, built on the first query of a tick. It's read-only and rebuilt once a tick, so it already fits rule 3.
- `AITargetSelector.force_target` (a taunt) writes into another pawn's AI immediately. It's rare and comes from game code, not from a phase.

### 15.2 Gates and channels in abilities

Before, the `AbilityManager` touched every ability every tick: counting every cooldown and buffer down, calling every `every_tick()`, rebuilding the locks, checking every action for a press, and Walk reading five stats. About 14 µs per pawn even when idle (12.1).

Now each piece runs only when something gives it a reason:
- **Counting down** only for abilities with a timer running (a run, a cooldown or a buffered press). The manager keeps that list and rebuilds it only when a timer starts or reaches 0: the timers' setters tell it, so a rollback that loads new values is noticed too.
- **`every_tick()`** only on abilities whose script overrides it, found once from the script (Jump, in t0).
- **The input channel:** this tick's presses are one bit calculation (`held_actions & ~previous_held_actions`, limited to the actions any ability answers to). With no press, nothing buffered and no action running, the action step is skipped.
- **Locks** are rebuilt only when an action starts or stops.
- **Stats:** Walk (and Sprint) keep their five stat values and read them again only when a stat changes. `StatManager.version` goes up whenever a stat's value changes, or a stat is added or removed.

Timers stay counters, not "ready at tick N" deadlines. With the list above, an idle ability is never touched anyway, and counters stay one byte on the network; deadlines would be absolute tick numbers, several bytes each, in every snapshot.

### 15.3 Resting pawns

A pawn **rests** on a tick when all of these hold:
- `rest_when_idle` is on (the default; a designer can turn it off per pawn)
- it's grounded, its velocity is exactly zero, and it has no move input and no held actions
- nothing has moved it since its last tick (a teleport, or `TerrainBodyLifter` raising it)
- its `AbilityManager` has no timer running, and every ability with `every_tick()` agrees (`AbilityBase.can_rest()`; Jump does once its time off the ground is 0)
- it isn't one of its check ticks: every `rest_check_ticks` (15) it runs a full tick anyway, staggered by entity id, so ground that went away under it is noticed within a quarter of a second

A resting pawn skips its abilities, gravity and `move_and_slide`, and only does its bookkeeping. **What wakes it:** any input or press, any ability starting (a hit's knockback, Death), any velocity, being moved, or a check tick.

**It's a pure rule of the pawn's state and the tick number,** with nothing remembered, so there's nothing extra to roll back, and a server and a client predicting the same pawn rest on exactly the same ticks.

Things to know:
- A standing pawn used to be nudged out of the way by `move_and_slide`'s depenetration when another walked into it. A resting one is nudged only on its check ticks, so crowds can press together a little more between checks.
- The AI still runs on a resting pawn (the input phase), so a goblin that decides to move wakes on its next tick.

### 15.4 Hits are delivered after simulate

`Pawn.receive_hit()` called **during simulate** (an ability hitting) queues the hit. After every pawn has simulated, the queue is delivered in a fixed order (by the attacker's entity id, then the target's, then the order they were queued), through the new `TickDriver.after_simulate` signal. Called at any other time (game code, tests) it takes effect at once, as before.

- So a hit's result never depends on whether the target simulated before or after the attacker. Before, a target that had already simulated started its knockback a tick later than one that hadn't.
- Hits still land in the same tick: the damage, death and knockback start are in that tick's recorded state and snapshot.
- `MeleeAttackAbility.hit_landed` still goes out when the swing finds the target; the target's own `hit_received` goes out when it takes the hit.

### 15.5 Ready for the shared table (design only)

The recorder already reads every pawn's hot values once a tick, in C++. In tier 1, the same read can fill the shared table that AI jobs and the pawn grid use instead of each asking nodes: dense slots, one array per field, entity id to slot, slots kept in entity-id order. Nothing in 15.1 to 15.4 gets in the way of that; nothing of it is built in t0.

### 15.6 As built, and measured *(Claude 2026-11-09)*

**Where it lives:**
- Gates: `AbilityManager` (`timers_changed()`, `can_rest()`, `_timed`, `_every_tick_abilities`, `_action_bits`), the timer setters in `AbilityBase`, `AbilityBase.can_rest()` (Jump overrides it), Walk's `_refresh_stats()`, `StatManager.version`.
- Resting: `Pawn.rest_when_idle`, `rest_check_ticks`, `is_resting` (for readouts and tests) and `_can_rest()`.
- Hits: `Pawn.receive_hit()` queues during simulate; `TickDriver.after_simulate` and `TickDriver.is_in_simulate()`.

**Tests:**
- `ability_selftest`: `every_tick()` runs only where overridden (found in an inner-class script too), a timer written from outside counts down at once, Walk picks up a changed stat.
- `pawn_selftest`: a standing pawn rests 28 of 30 ticks; it wakes for input, a teleport, a hit's knockback, and ground taken away (on its next check tick); and the same walk, stop, jump and stand script ends **exactly** where a never-resting pawn does (0.0000 m apart).
- `combat_selftest`: the same swing with the two pawns joining the tick driver in both orders gives the same tick, damage and knockback path; the target takes the hit after simulate, in the same tick it lands.
- Every other suite passes unchanged.

**Measured** with `pawn_stress -- --sizes=100,400 --breakdown`, microseconds per pawn per tick at 400 pawns, against the morning's numbers (12.1):

| Scene | Simulate: before | now | Abilities: before | now | Physics frame at 400: before | now |
|---|---|---|---|---|---|---|
| standing | 19.2 | 2.7 | 13.7 | 0.4 | 20.1 ms | 11.0 ms |
| wandering | 24.3 | 11.5 | 14.1 | 2.9 | 24.2 ms | 19.7 ms |
| fighting | 29.9 | 23.8 | 17.1 | 10.0 | 32.4 ms | 28.1 ms |

- **Standing pawns are about seven times cheaper to simulate,** and a whole tick for 400 of them nearly halves. Wanderers rest between wanders, so they halve too.
- **Fighting gains less** (about 20%), because fighting pawns are moving and pressing: they really do need their abilities and `move_and_slide` most ticks. About 235 fighting pawns now fit in a 60 Hz tick by the whole physics frame, against about 210 this morning. Fights are where tier 1's AI-on-workers and crowd movement come in.
- **What a standing pawn still costs** is mostly outside simulate: about 13 µs of the other phases, mostly saving its inputs, which `pawn_stress` pawns do because no network session configures them. A real server or offline game skips that (12.1).

**Finer gates** *(Claude 2026-11-09, the owner asked whether simulate's logic could be gated further)*:
- Built: the ability loops test precomputed input bits (`AbilityBase.trigger_bit`) instead of looking each trigger's name up every tick, and the action step keeps what started as bits instead of building a Dictionary every tick. At 400 fighting pawns, abilities went from 10.0 to 8.3 µs per pawn, and simulate from 23.8 to 22.1.
- Tried on paper and left out: skipping Walk on ticks where it would change nothing. A moving pawn's velocity is rounded to 1 mm/s after every tick, and Walk sets it back to the exact target speed, so a moving Walk always has real work and would almost never skip. Making it skip would mean Walk aiming at already-rounded speeds, a behaviour change for about 2 µs.
- What's left in a fighting pawn's simulate (about 22 µs) is mostly `move_and_slide` (about 14), which can't be skipped for a moving pawn at full detail. Tier 1 takes it on: `docs/scaling/SCALING_SPEC.md`, sections 7 and 8.
