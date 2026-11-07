<!-- Written by Claude (claude-opus-5-5), 2026-11-07: the new pawn spec, from the owner's 2026-11-07 decisions on the pawn rebuild. A first shape to work from, not finished. Replaces docs/pawn/PAWN_ARCHITECTURE.md, which stays as a guide. -->

# Pawn Spec v0.3

**Revisions:**
- v0.1 (2026-11-07): first shape, from the owner's decisions that day.
- v0.2 (2026-11-07): Sprint is its own ability, with a cooldown and a maximum duration. Heavy load (4.1). A missing input repeats for a few ticks, then its move fades, while held actions keep repeating (5). `ControllerBase` trimmed to what step 2 builds (6.1).
- v0.3 (2026-11-07): step 2 built. After a review: `take_input_command` instead of `get_input_command`, because it uses up saved presses. The missing-input settings live on `NetworkSession` (5).

**Status:** a first shape to work from, written 2026-11-07. Nothing in it is built yet, except what's marked **(built)**. Code sketches are GDScript outlines, not final signatures. Class names are working names. Each one differs from the legacy class names, because legacy files are never changed and new systems sit beside them.

**Scope:** everything on a pawn. That covers its parts, how a controller drives it, abilities, stats, navigation and the AI.

**Related docs:**
- `docs/pawn/PAWN_ARCHITECTURE.md`: the old spec, now a guide. Sections 7.1 to 7.5 (categories, lockouts, cooldowns, input buffer) are borrowed below.
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
├─ AISensingManager                        sees and hears; writes to memory
├─ AIMemory                                facts that fade
├─ AIStateManager                          picks the current state
│  └─ state nodes (Idle, Alerted, ...)
└─ AIBehaviourManager                      picks and runs a behaviour
   └─ behaviour nodes (Wander, Chase, ...)

PlayerController (outside the pawn)        (built) reads devices; joins a pawn through PossessionCoordinator
```

- The parts are kept flat on the pawn, so a designer sees every part in one place.
- The AI parts exist on every peer, but only tick on the server, because AI only runs there.

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
| 1 | AI parts | On decision ticks only: sensing updates memory, states are checked, the behaviour manager decides. The running behaviour ticks and calls `AIController` | Server only. Paused while a player has the pawn, except sensing and memory |
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
Hooks for gaining and losing a pawn get added when the controller manager needs them (step 3).

### 6.2 `PlayerController` (built, gets moved onto the base)
- Lives outside the pawn and survives with no pawn **(built)**.
- Reads keys, mouse and stick, rotates movement by the camera's yaw, and maps keys to actions.
- **Click-to-move:**
  1. A click asks the world cursor for a point.
  2. It calls `pawn.navigation_manager.move_to(point)`.
  3. While a path is being followed, `move` comes from `navigation_manager.get_move_direction()`.
  4. WASD cancels the path. That's today's behaviour **(built)**.

### 6.3 `AIController`
- A child of `ControllerManager`.
- It decides nothing. It's the AI's hands: behaviours call it, and it builds the input command.

```gdscript
func move_to(point: Vector3) -> void      # passes on to NavigationManager
func stop() -> void
func look_at_point(point: Vector3) -> void
func press(action: StringName) -> void    # pressed for one tick
func hold(action: StringName, held: bool) -> void
```

### 6.4 `ControllerManager`
- Picks whose input counts. The rule is fixed and simple: the player if one has the pawn, otherwise the AI controller.
- When the player lets go, the AI controller takes over, and the behaviour manager re-decides at once.
- `PossessionCoordinator` already tells the pawn when a player joins or leaves **(built)**. The manager listens to that.

---

## 7. Navigation manager

The pawn's only contact with navigation. Both controllers use it.

```gdscript
func move_to(point: Vector3) -> bool     # false if there's no way there
func stop() -> void
func get_move_direction() -> Vector3     # which way to walk now; zero when there's no path
func is_following_path() -> bool
func has_arrived() -> bool
```

- It asks `NavServer` for a path and follows the corners. The waypoints stay private.
- With no nav at all, it walks in a straight line.
- **Over the network:** the client follows its own path and sends directions. The server never sees a path. The stress test already works this way **(built)**. This settles open question 15 in the netcode spec.
- Borrowed for later from the old guide, section 8: repathing when tiles change, size tiers, domains.
- Nav phase 3 (agents and links) arrives with this part.

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

### 8.3 `AbilityBase` (sketch)
Borrowed from the old guide, section 7.2. Its changes from that version are listed below the sketch.

```gdscript
class_name AbilityBase extends Node
enum Kind { LOCOMOTION, ACTION }
enum Status { RUNNING, SUCCEEDED, FAILED }

@export var kind := Kind.ACTION
@export var trigger_action: StringName = &""     # empty = only started by code, or the default locomotion
@export var category: StringName = &""           # for lockouts and nav, e.g. movement.jump (tag registry, built)
@export var priority := 0                        # lower wins when several abilities share an action
@export var cooldown := 0.0                      # seconds in the inspector, ticks at runtime
@export var locks_out: Array[StringName] = []    # categories that can't start while this runs
@export var bufferable := true
@export var buffer_window := 0.15                # seconds a press waits

func can_start(context) -> bool                  # default: cooldown, cost, lockouts
func start(context) -> void
func tick(context, delta: float) -> Status       # delta is always the fixed tick
func stop(context, reason) -> void
```

What changed from the old guide:
- Abilities are started by a **named action**, not by a category request.
- Categories stay, but only for lockouts and for telling nav which links a pawn can use.

### 8.4 `AbilityManager`

```gdscript
func can_start(action: StringName) -> bool   # behaviours ask this before choosing to press
func is_busy() -> bool                       # an action ability is running
func has_action(action: StringName) -> bool
func cancel(action: StringName) -> void
signal ability_started(ability) / ability_finished(ability, status)
```

Borrowed as they are from the old guide:
- **Lockouts as bit masks** (section 7.4): one AND per check, recomputed only when an ability starts or stops.
- **Cooldowns** stored as the tick they're ready again.
- **The input buffer** (section 7.5), keyed by tick:
  - First press wins.
  - A press replaces an earlier one by default, so mashing doesn't queue presses.
  - AI presses aren't buffered by default.

### 8.5 t0 abilities
- **Walk** replaces `GroundMovement` **(built)**. It reads its numbers (speed, acceleration, turn rate) from the stat manager, with safe defaults when a stat is missing.
- **Jump** includes the ground check and coyote time, and uses the buffer.
- **Sprint** is its own locomotion ability, bound to `&"sprint"`.
  - It has faster numbers, a **maximum duration** and a **cooldown**. There's no stamina yet.
  - While `&"sprint"` is held and Sprint is ready, it runs instead of Walk. When its time runs out it ends, its cooldown starts, and Walk takes over even if the key is still held.
  - The AI uses it the same way: a behaviour such as Chase holds `&"sprint"`, and asks `can_start(&"sprint")` if it cares. So Sprint wins over Walk whenever it's ready, but the cooldown gives it downtime. That's what makes it testable.
- After the AI is built, more abilities come before fights: Dash, then MeleeAttack.

---

## 9. Stats

- `StatManager` holds stat nodes. One node per stat: Health, MoveSpeed, JumpStrength and so on.
- Abilities and behaviours read stats through the manager by name, and each read has a fallback, so a missing stat is never a crash.
- Stats that change during play (Health, Stamina) are rollback state.
- Modifiers (buffs, debuffs) come later.

---

## 10. AI

### 10.1 The parts

| Part | Job | Starts from |
|---|---|---|
| `AISensingManager` | Sees (cone, line of sight) and hears; writes what it finds into memory | Legacy `AISensingComponent` |
| `AIMemory` | Facts that fade over time | Legacy `AIMemoryComponent`, which is close to reusable |
| `AIStateManager` + state nodes | Picks the current state by priority | Legacy `AIStateManagerComponent` |
| `AIBehaviourManager` + behaviour nodes | Picks and runs one behaviour | Legacy `AIBehaviourManagerComponent` |
| `AIDecisionContext` | Shared data for one pawn's AI: references, current state, scratch space, shared inputs (10.3) | Legacy `AIContext`, minus intent |
| `AIController` | The AI's hands (6.3) | New |

These are new copies beside the legacy files, typed to the new `Pawn`. The legacy files stay as they are.

What changes from the legacy AI:
- **No AI core node.** The initializer assembles the parts.
- **No `GlobalAICoordinator` autoload.** Decisions are spread across ticks inside the AI parts.
- **No timers or `_physics_process`.** Everything runs on the pawn's tick, server only.

### 10.2 While a player has the pawn
- Sensing and memory keep running, so when the player lets go, the AI already knows what's going on.
- States and behaviour decisions pause.
- When `AIActivationManager` switches the pawn off, all of it stops with the pawn **(built)**.

### 10.3 How the behaviour manager decides
It works through cheap checks first, so code on each behaviour node only runs for the few that survive.

**Done by the manager, with no behaviour code running:**
1. **State filter.** Each behaviour lists the states it's allowed in. The manager keeps a ready list per state, built when behaviours register, so this step costs nothing.
2. **Cheap flags.** These are designer-set properties the manager can read directly:
   - Cooldown not over yet.
   - Needs a target, and there isn't one.
   - The action it presses can't start right now.
3. **Best possible score first.** Each behaviour declares `max_score`, the highest score it can ever return, counting its randomness and commitment bonus. The survivors are checked from highest `max_score` down.

**Done by the behaviour, survivors only, best first:**

4. `is_available(context)`: the behaviour's own yes or no.
5. `score(context)`: reads the shared inputs.
6. **Stop early.** As soon as the next behaviour's `max_score` can't beat the best score found so far, stop. The rest aren't asked.

**Then the switch rules** decide whether the winner replaces the running behaviour (legacy, kept):
- Minimum run time.
- Interrupt policy.
- Commitment bonus.
- New: don't switch while the ability manager is busy, unless the interrupt policy allows it.

**Shared inputs:**
- Values many behaviours need: nearest enemy, distance to it, own health fraction, enemies nearby.
- They're worked out once per decision, the first time something asks, and kept on the context until the next decision. So if no behaviour asks, they cost nothing.

**Mistakes made obvious:** in debug builds, a `score()` above its `max_score` gives a warning naming the behaviour, because it would break step 6.

**Decision timing:**
- A few times a second, spread across ticks so a crowd doesn't all decide on the same tick.
- Also immediately when memory gets a fact a behaviour is watching (legacy `wake_on_facts`, kept).

**Later:** scoring from response curves set in the inspector, with no code. The shared inputs in this section are the inputs those curves will read.

### 10.4 Behaviour node (sketch)

```gdscript
class_name AIBehaviourBase extends Node
@export var allowed_states: Array[StringName] = []  # empty = any state
@export var base_score := 0.5
@export var max_score := 0.5           # the highest score() can return, counting randomness and commitment
@export var needs_target := false
@export var presses_action: StringName = &""   # if set, skipped while that action can't start
@export var cooldown := 0.0
@export var min_run_time := 0.0
@export var interrupt_policy := InterruptPolicy.NEVER_UNTIL_DONE
@export var wake_on_facts: Array[StringName] = []

func is_available(context) -> bool
func score(context) -> float
func enter(context) -> void
func tick(context, delta: float) -> Status    # calls context.controller.move_to / press / ...
func exit(context, reason) -> void
```

---

## 11. `PawnInitializer`

- A `GameMode` module. The pawn calls `GameMode.pawn_initializer.initialize(self)` from its own `_enter_tree`.
- It adds each default part the pawn doesn't already have. A part placed in the pawn's scene is kept as it is, so a designer can override any default by adding their own.
- For t0 it holds only the current defaults, in one defaults file per game.
- Parts get fixed names, and are added in a fixed order.
- A pawn can opt out of the initializer, or out of single parts.
- `pawn.tscn` stops being a second source of defaults.

---

## 12. t0 build order

1. **This spec agreed.**
2. **Inputs and controllers:** `ControllerBase`, `PlayerController` moved onto it, the input command with named actions, and the fading missing input. **(Built 2026-11-07.)**
3. **`ControllerManager`.**
4. **`PawnInitializer`** and the defaults file.
5. **`StatManager`** and stat nodes for movement.
6. **`AbilityManager`, `AbilityBase`, Walk, Jump and Sprint**, replacing `GroundMovement`. The existing pawn, possession and network tests must still pass.
7. **`NavigationManager`**, with click-to-move moved onto it, and nav phase 3.
8. **AI:** `AIController`, sensing, memory, states, behaviours, the context with shared inputs, and the decision steps. Wander and Chase behaviours to prove it.
9. **More abilities:** Dash, then MeleeAttack.
10. **Teams and the fight loop:** damage, death.
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
| 5 | Teams | A team number on the pawn, enough for sensing to tell friend from foe |
| 6 | Death | Comes with the fight loop |
| 7 | Animation: which part plays the Kenney Mini Characters' built-in animations (walk, sprint, jump, die, melee) | Probably a part that listens to the ability manager. Not decided |
| 8 | Whether `AIMemoryFact` is reused as is, or copied | It doesn't depend on the old pawn, so reuse is possible |

---

## 14. Deferred, not t0

- Other pawn body types, such as rigid bodies, as separate classes.
- Response-curve scoring for behaviours.
- Deciding less often for AI far from players.
- Stat modifiers.
- Anti-cheat.
- `TerrainBodyLifter` folding into the terrain edit manager (t1).
