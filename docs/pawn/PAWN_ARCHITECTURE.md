<!-- Written by Claude (claude-opus-5-5), 2026-11-04: design spec for the pawn layer (controllers, intent, abilities, navigation manager), from the 2026-11-03/04 design discussion with the owner. Mostly not built yet. -->
<!-- Claude 2026-11-04: revised for multiplayer (principle 7, section 6a, ticks in abilities and buffer, fixed-order tag registry, build order); see docs/netcode/NETCODE_SPEC.md -->


# Pawn Architecture Spec (draft 1)

**Status:** design draft, **not locked**. Written from the design discussion of 2026-11-03/04. Sections marked **(built)** describe code that exists; everything else is a proposal. Function signatures are GDScript sketches, not final.
**Scope:** everything that lives on a pawn: the body, its assembly, how players and AI say what they want, how abilities carry it out, and how the pawn asks navigation for a route.
**Performance numbers** are ballpark estimates, not measurements. A stress scene is planned to replace them (section 12).
**Multiplayer:** the pawn follows `docs/netcode/NETCODE_SPEC.md` (tick driver, rollback state, prediction). Section 6a summarises what that means for the pawn. *(Added 2026-11-04.)*

How to read this:
- Sections 1–3 are the big picture: principles, layers, who is responsible for what.
- Section 4 walks through concrete scenarios end to end. **If you only read one section to understand the flow, read 4.**
- Sections 5–10 go part by part.
- Sections 11–15 cover defaults, performance, migration from the current code, build order and open questions.
- Section 16 lists the decisions made so far, so they don't get re-argued.

---

## 1. Purpose and principles

ProjectBase is **not a game**. It is the base the owner's games are built on: engine-level features that support making games. The example nodes (states, behaviours, abilities) are meant to grow into the **tier 0 implementation** of the common features modern games expect, explicitly built to be extended. It may be handed to modders and designers with little or no programming knowledge.

That leads to seven rules every part of the pawn follows:

1. **Graceful defaults ("escape clauses").** Every dependency a component introduces has a safe default. A missing part degrades the feature; it never throws errors. A pawn with no memory, no stats or no navigation still runs.
2. **Configure before code.** Most variation is inspector settings (exports). A designer should be able to build a new ability or behaviour from an existing one without scripting.
3. **Shallow inheritance, composition for the rest.** One base class per contract (`AbilityBase`, `AIBehaviourComponentBase`…). Concrete classes usually sit a level or two below it; deeper is fine when it earns its keep, just don't go overboard. Everything else is child nodes and settings.
4. **Nothing game-specific in the core.** Names like `"Health"` or `"pawn_seen"` are settings, not hard-coded. Examples live apart from the core classes.
5. **Prefer event-driven.** Where we can help it, work happens when something changes, or only for things actually running, and idle parts switch their frame processing off. A guiding principle, not an absolute rule: per-frame work is fine where it's the simpler or necessary choice.
6. **Every subsystem has a written contract and a headless test.** Corner cases are documented at the top of the manager that owns them (as in `AIBehaviourManagerComponent.gd` and `AIStateManager.gd`).
7. **Network-ready, even offline.** Gameplay runs on the tick driver, timing is in ticks, cross-entity references are entity ids, and predicted parts can save and load their state (netcode spec). Offline this costs nothing extra. *(Added 2026-11-04.)*

---

## 2. The layers

```
BRAIN         Player input                      |  AI core: sensing → memory → states → behaviours
                    │ writes intent                              │ writes intent
CONTROLLERS   PlayerController                  |  AIController            ← hold intent, do nothing else
                    └──────────────┬──────────────────────────────┘
              Controller manager: decides WHO HAS CONTROL (whose intent counts)
                                   │ intent, on the pawn's context
ABILITIES     Ability manager: turns intent and requests into abilities
                 ├─ input buffer + lockouts (bitmasks)          ← what may start, when
                 ├─ locomotion: Walk | Sprint | …  (one active) ← continuous movement
                 └─ actions: Jump, Dash, MeleeAttack …          ← one-shots
                                   │                  ▲
NAVIGATION    Navigation manager ──┘ next point       │ "where next?"   (waypoints stay private)
                                   │
MOTOR         CharacterPawn3D: accelerate toward a velocity, turn, gravity, impulse, move_and_slide
```

The resulting node tree:

```
CharacterPawn3D                (the entity; physics body; movement stats)
├─ CharacterModel, CollisionShape
├─ PawnCameraController        (presentation and possession; stays a direct child of the pawn)
├─ CharacterStatManager        (numeric stats: Health, Stamina…)
└─ PawnNexusComponent          (assembly; owns the context)
   ├─ ControllerManager
   │   ├─ PlayerController
   │   └─ AIController
   ├─ AbilityManager
   │   ├─ Walk      (movement.walk, default locomotion)
   │   ├─ Sprint    (movement.sprint)
   │   ├─ Jump      (movement.jump)
   │   ├─ Dash      (movement.dash)
   │   └─ MeleeAttack (combat.melee)
   ├─ NavigationManager
   └─ AICoreComponent          (built: sensing, memory, states, behaviours)
```

---

## 3. Responsibilities

| Part | Responsible for | Not responsible for |
|---|---|---|
| **Pawn** (`CharacterPawn3D`) | Being *the entity*: the node other entities reference. Physics body: gravity, `move_and_slide`. Motor primitives (section 9) | Deciding anything. Steering math (that's Walk). Holding stats (that's the stat manager) |
| **Nexus** | Assembly: finds or creates components, fills gaps with safe defaults, never errors on a bad setup. **Owns the context.** The one place references are wired | Gameplay |
| **Context** (`AIContext`, to be renamed) | Shared per-pawn knowledge: references to every part, **intent fields** (section 6), current AI state, blackboard | Logic beyond small helpers |
| **Controllers** | Holding **intent** for their source. Player: from input. AI: from behaviours. Sending discrete ability requests | Executing anything |
| **Controller manager** | Selecting **which input to recognise**: whose intent is enacted. Deliberately simple (section 6) | Executing |
| **Ability manager** | Fulfilling intent and requests: choosing which ability serves them, the input buffer, lockouts, cooldowns, costs | Deciding *what* the pawn wants |
| **Abilities** | The *how*: Walk steers and turns; Jump applies an impulse; MeleeAttack hits a target | Choosing goals or targets |
| **Navigation manager** | Whether a path is needed, computing it, handing out the next point. Waypoints stay inside it | Moving the pawn |
| **AI core** (built) | The AI's brain: sensing → memory → states → behaviours, which write the AI controller's intent | Moving the pawn directly |
| **Stat manager** (built) | Numeric stats, **including movement stats** (max speed, acceleration, deceleration, turn rate, air control, jump velocity), so buffs and debuffs apply to them like any other stat | — |
| **Camera arm** (built) | Presentation and possession | Gameplay |

---

## 4. Walkthroughs

### 4.1 Player presses W

1. `PlayerController` reads input, rotates it by the camera's yaw (as today), and writes intent: `move_target` = a point a short distance ahead in that direction, marked **direct**. It re-places the point every frame while the key is held (a "carrot on a stick"), so the pawn never arrives and brakes. Stick strength scales the distance, which gives analog walking speed.
2. The controller manager says the player has control (the pawn is possessed), so the context shows the player's intent.
3. The ability manager sees a move intent and picks a locomotion ability: Walk (or Sprint if `wants_sprint` and Sprint can run).
4. Walk sees a **direct** target: no navigation. It accelerates and turns toward the point using the pawn's stats.
5. The motor applies gravity and `move_and_slide`. Pushing into a wall slides along it, because nothing pathfinds around it.
6. Releasing W clears `move_target`, and Walk decelerates to a stop.

### 4.2 Player clicks a point (click-to-move)

1. `PlayerController` writes `move_target` = the clicked point, marked **navigated**.
2. Walk asks the navigation manager for the next point each update.
3. The navigation manager decides (section 8): close and clear means a straight line; otherwise it computes a path once and hands out corners as Walk reaches them.
4. On arrival, the navigation manager reports done and the controller clears `move_target`.

### 4.3 AI investigates a sound

1. Sensing records a `heard_noise` fact in memory (built).
2. `InvestigateBehaviour` wakes on that fact, scores highest, enters, and writes `move_target` = the remembered position, navigated (built behaviour; the write goes through `context.move_to()`).
3. From here it's identical to 4.2: same Walk, same navigation manager. The AI and the player share one movement path.

### 4.4 Jump pressed just before landing (input buffer)

1. `PlayerController` sends `request_ability(&"movement.jump")`.
2. The request enters the buffer. Jump's `can_perform` fails because the pawn is still airborne.
3. The buffer retries it each tick. Two ticks later the pawn lands, `can_perform` passes, and Jump fires.
4. If the pawn hadn't landed within Jump's `buffer_window`, the request would have been dropped.

### 4.5 Attack and jump pressed in the same tick (lockouts)

1. Both requests enter the buffer.
2. That tick the buffer resolves oldest first. MeleeAttack is unlocked, so it starts and adds its `locks_out` bits to the manager's `locked_mask`.
3. Jump is checked next against the updated mask:
   - MeleeAttack's `locks_out` is `[combat]`: Jump isn't blocked, and **both fire this tick**.
   - MeleeAttack's `locks_out` is `[combat, movement]`: Jump is blocked and waits. It fires when the attack ends, or expires.

---

## 5. Context

**(built, partly)** `AIContext` exists, owned by the AI core, and passed into every state and behaviour call.

**Proposed changes:**
- Ownership moves from the AI core to the **nexus**, because the player side now uses it too. The name stays as it is for now.
- Adds the intent fields (section 6) and references to the ability manager and navigation manager.
- It holds **references and shared facts only**. A part's working data stays private: the navigation manager's waypoints are not on the context, only a reference to the navigation manager.

| Group | Fields |
|---|---|
| References | pawn, nexus, aiCore, memory, sensing, statManager, controllerManager, abilityManager, navigationManager |
| Intent | `move_target`, `move_target_mode`, `face_target`, `wants_sprint` (section 6) |
| AI | `currentState` (built), `blackboard` (built) |
| Helpers | `move_to()`, `stop_moving()`, `get_stat()`, `get_stat_fraction()` (built); `request_ability()`, `has_ability()` (new) |

All references may be null; every helper checks and returns false or a fallback.

---

## 6. Intent and control

**Intent** is what the pawn currently *wants*, continuously. It is a few fields on the context, not a separate system:

| Field | Meaning | Default |
|---|---|---|
| `move_target` | A point (or a node to follow), or none | none (stand still) |
| `move_target_mode` | `DIRECT` (straight steering, never pathfinds) or `NAVIGATED` (ask the navigation manager) | `NAVIGATED` |
| `face_target` | A point or node to face, or none | none = face where I'm moving |
| `wants_sprint` | Held modifier | false |

Rules:
- **Each controller writes its own intent onto the context; the controller manager selects which one is enacted.** It is deliberately simple, a fixed order:
  1. **Player** always wins, unless explicitly **silenced** (e.g. while Incapacitated or Dead).
  2. **Swarm director**, when a game has one, beats the pawn's own AI.
  3. **AI controller.**
  Keeping every source's intent means control can switch back and forth without losing anyone's wishes. *(Revised 2026-11-04: previously "who has control by possession".)*
  *Under discussion: exactly which fields intent holds, and when and how it is read (section 15).*
- **Intent persists until changed.** No resending every frame, unlike today's request bus.
- **Discrete actions are not intent.** Jump, attack and so on are requests to the ability manager (`request_ability`), which go through the input buffer.
- **No order queue in the core.** AI behaviours already sequence their own steps. An optional tier 0 component can feed `move_target` one point at a time for games with RTS-style queued commands. Commands to AI units can be memory facts that an "obey order" behaviour carries out.

### 6a. Networking, for the pawn *(added 2026-11-04)*

Full rules in `docs/netcode/NETCODE_SPEC.md`. What they mean here:
- **The pawn runs on the tick driver.** The nexus registers it at spawn. Each tick: the controller writes an **input command** (this tick's intent plus requests, as plain data), then ability manager → abilities / Walk → motor run with the fixed tick delta. Controllers, abilities and the motor don't run their own `_process` / `_physics_process` for gameplay.
- **An input command is intent frozen for one tick.** Over the network the server rebuilds the remote player's intent from it; offline it's handed straight through.
- **Intent and request targets are entity ids or points** once networked, never node references. Locally the context may resolve ids to nodes for convenience.
- **Predicted state** of the pawn: motor (position, velocity, grounded), the active locomotion, each running ability (phase, elapsed ticks, "ready at" tick, charges), the ability manager's buffer and `locked_mask`, predicted stats (stamina). Health and other server-only stats are **sync** state.
- **The AI runs only on the authority.** Clients never run sensing, memory, states or behaviours; AI pawns are interpolated remote pawns to them.
- **Cosmetic effects** in abilities check `NetworkTime.is_resimulating()`.

---

## 7. Abilities

### 7.1 Categories and the tag registry

**(built 2026-11-04)** `assets/scripts/tags/TagRegistry.gd`, declarations in `assets/scripts/resources/tag_declarations.tres` (a `TagDeclarationsRes`), test in `tags/tests/tag_registry_selftest`. Root matching via `matches()` only. Queries never add tags. *(2026-11-04: an any-level search, e.g. "sword" finding both `combat.melee.sword` and `crafting.smithing.sword`, was built and then removed from tier 0. It's ambiguous and needs a more robust design before it's offered; see section 15.)*

- An ability's **category** is a `StringName` with dot-separated levels: `movement.walk`, `combat.melee.sword`. A dot means "sub-category". Categories are **names**, not class hierarchy and not scene-tree position.
- A query for `combat` matches `combat.melee` and `combat.ranged.bow`, never `combatant`. Matching is by whole levels.
- `extra_categories` (default empty) lets one ability answer to more than one name, e.g. Dash = `movement.dash` + `combat.evade`.
- **Tag registry:** a static class (not an autoload, so it works in tests) that gives every category level a **bit**. *(Revised 2026-11-04 for multiplayer:)* categories are **declared up front in a resource and registered in sorted order at startup**, never on first use, so every peer assigns the same bits. An undeclared category used at runtime is added with a warning (fine offline, a desync risk online). Example: `combat` = bit 0, `combat.melee` = bit 1, and so on. Strings are only touched when abilities register; runtime checks are bit operations.
  - An ability's `category_mask` holds its own bit **and its parents' bits**, so locking `combat` blocks `combat.melee` with one AND.
  - Limit: 64 category levels across the game (one int). The registry warns past that; the mask can later become a small array of ints with no change to designers.
  - **Shared with navigation.** The nav spec's planned `TagMask` / `TagRegistry` (`NAV_SPEC.md` section 4) uses the same registry, so a pawn's movement abilities double as its nav capabilities (a pawn with `movement.jump` may use jump links).

### 7.2 `AbilityBase` (node)

```gdscript
class_name AbilityBase extends Node

enum Status { RUNNING, SUCCEEDED, FAILED }   # same contract as behaviours
enum BufferMode { REPLACE, STACK }
enum Prediction { INHERIT, PREDICTED, NONE }

@export var category: StringName = &""            # empty = never matched
@export var extra_categories: Array[StringName] = []
@export var priority: int = 0                     # lower wins when several abilities fit a request
@export var cooldown: float = 0.0                 # seconds in the inspector; converted to ticks; stored as a "ready at" tick
@export var range: float = 0.0                    # 0 = unlimited
@export var cost_stat: String = ""                # e.g. "Stamina"; empty = free
@export var cost: float = 0.0                     # paid once, on start
@export var cost_per_second: float = 0.0          # paid while running (Sprint)
@export var locks_out: Array[StringName] = []     # categories that can't START while this runs
@export var bufferable: bool = true
@export var buffer_window: float = 0.15           # seconds in the inspector, converted to ticks: how long a request waits
@export var buffer_mode: BufferMode = BufferMode.REPLACE   # REPLACE = re-press replaces (anti-mash)
@export var max_buffered: int = 1                 # for STACK: how many presses are kept
@export var prediction: Prediction = Prediction.INHERIT   # INHERIT (project default) | PREDICTED | NONE (netcode spec section 7)

func can_perform(context, target) -> bool        # default: cooldown, range, cost
func start(context, target) -> void
func tick(context, delta) -> Status              # default: SUCCEEDED (instant); delta is always the fixed tick delta
func stop(context, reason) -> void
func can_start_while(running: AbilityBase) -> bool   # default: the lockout bitmask; override for richer rules
func get_state_properties() -> Array[StringName] # default: phase, elapsed ticks, ready-at tick, charges (netcode rollback state)
func save_state() -> Dictionary / load_state(d)  # default: from get_state_properties(); override for unusual state
```

Designers keep working in **seconds**; the ability converts them to whole ticks when it registers. All runtime timing is in ticks, so it lines up exactly between server and client.

Defaults are chosen so an ability with no code is harmless: no category means it's never chosen, no cost means it's free, no lockouts means nothing is blocked.

### 7.3 Locomotion and actions

| Kind | Examples | Rule |
|---|---|---|
| **Locomotion** | Walk, Sprint, later Fly, Swim, Crouch | Continuous. **Exactly one active.** Takes the move intent every frame and steers. The ability manager has a `default_locomotion` (Walk) |
| **Actions** | Jump, Dash, MeleeAttack, Heal | One-shots or timed. Requested; go through the buffer |

- Walk owns the steering math (accelerate, decelerate, turn, air control), **reading the pawn's movement stats from the context**, with failsafe defaults when they're missing.
- Sprint is a second Walk node with faster numbers and a stamina drain: configured, not subclassed.
- **Locomotion is subject to lockouts every frame.** While its category is locked (e.g. a heavy attack locks `movement`), Walk stops steering. That's how rooting works.
- Each movement ability declares the **nav domain** it serves (Walk and Sprint: ground). The navigation manager uses this to know which domains the pawn can use (section 8).

### 7.4 Ability manager

```gdscript
func request_ability(category: StringName, target = null, source = null) -> void   # into the buffer
func has_ability(category: StringName) -> bool
func find_abilities(category: StringName) -> Array[AbilityBase]
func is_locked(category: StringName) -> bool
func cancel(category: StringName) -> void
signal ability_started(ability) / ability_finished(ability, status) / ability_added(ability) / ability_removed(ability)
```

**Choosing an ability** for a request: candidates are the abilities matching the category whose `can_perform` passes and that aren't locked out. The lowest `priority` wins; a tie goes to the one higher in the tree (the same rules as states). A request can name a narrower category (`movement.dash`) to pin a choice.

**Lockouts (bitmasks):**
- `locked_mask` = OR of the running abilities' lockout masks.
- It's recomputed only when an ability starts or stops, over the one to three running abilities.
- "Is this blocked?" = `ability.category_mask & locked_mask != 0`.

**Bookkeeping without scanning:**
- Category lookups use a table built at registration, rebuilt only when abilities are added or removed.
- Cooldowns are "ready at" ticks.
- The tick driver skips the manager when nothing is running and the buffer is empty.

### 7.5 Input buffer

Every request goes through the buffer, so presses arriving in the same tick are resolved consistently.

1. **On request:** stamped with the **tick** (not wall-clock time, so the server orders a client's requests exactly as the client did). The ability's `buffer_mode` decides what happens to earlier presses of the same category:
   - `REPLACE` (default, anti-mash): the newer press replaces the older.
   - `STACK`: kept, up to `max_buffered`. For games where mashing counts.
2. **Each tick, only if the buffer isn't empty:** walk the requests **oldest first**. If one can start, start it and **add its lockouts to `locked_mask` immediately**, so later requests in the same tick respect it. Otherwise leave it waiting.
3. **Expiry:** requests older than their ability's `buffer_window` are dropped. Abilities with `bufferable = false` (e.g. a parry) are tried once and dropped if they can't start.
4. **Order on conflict:** first pressed wins. A per-ability priority may override this later.
5. **AI requests:** not buffered by default, since behaviours re-decide anyway and a late-firing attack could hit a target the AI has already abandoned. This is a setting on the ability manager.

### 7.6 Prototype abilities

**Batch 1:** chosen so every mechanism is exercised at least once.

| Ability | Category | Proves |
|---|---|---|
| Walk | `movement.walk` | continuous locomotion; steering and turning from context stats with fallbacks; direct vs navigated targets; rooting by lockout |
| Sprint | `movement.sprint` | the manager choosing between movement abilities (`wants_sprint`); cost per second; configure-not-subclass |
| Jump | `movement.jump` | one-shots; ground check and coyote time (moved out of `PlayerControllerComponent`); the input buffer |
| Dash | `movement.dash` | timed abilities (`tick` over a duration); lockouts (`[combat, movement]`); cooldown |
| MeleeAttack | `combat.melee` | targeting, range, wind-up / hit / recovery, damage to the target's Health stat, self-lockout; used by player and AI alike |

**Batch 2:** Ranged attack (hitscan ray, no projectile system yet), Heal (self-target, resource cost), Interact (doors, pickups).

**Damage convention, tier 0:** "decrease the target's `Health` stat through its stat manager", with the stat name as a setting. Teams and factions come with the fight-loop work; they're needed so the AI attacks enemies only.

---

## 8. Navigation manager

The pawn's single point of contact with navigation. **v1 is deliberately simple:** one domain (ground). The future features exist only as overridable hooks that do the simple thing by default.

| Responsibility | v1 | Hook for later (default = v1 behaviour) |
|---|---|---|
| Domain | Ground only | `_choose_domain(destination)` → ground |
| Whether to path | `DIRECT` targets never; `NAVIGATED` targets that are close **and** clear (navmesh raycast) go straight; otherwise compute a path | `_needs_path(...)` |
| Cost | none | `_cost_for(surface, domain)` → 1 |
| Backend | Godot's navigation by default; the NavServer when present | swapped without changing callers |
| Size | Clearance tier from the collision capsule | export to override |
| Repath | destination changed, nav tiles changed (NavServer `tiles_changed`), stuck | — |
| Output | `next_point()`, `is_arrived()`, `has_failed()`; waypoints private | — |

**Escape clause:** no navigation available (no navmesh, or the pawn is off it) falls back to straight-line steering.

**Later, downstream:** multi-domain routes (walk → climb → walk) need nav links (nav spec phase 3). Surface weighting needs per-pawn area costs on NavServer queries (today they only take a tier). Danger-aware routing could read memory.

---

## 9. Motor (the pawn)

`CharacterPawn3D` keeps the physics and gains clean primitives for abilities to call:

```gdscript
func accelerate_toward(velocity: Vector3, rate: float, delta: float) -> void
func turn_toward(yaw: float, rate_deg: float, delta: float) -> void
func apply_impulse(impulse: Vector3) -> void
func set_gravity_enabled(on: bool) -> void       # Fly would turn it off
func is_grounded() -> bool
```

- **The pawn's main job is `move_and_slide`** (plus gravity and the primitives above). Movement stats (speed, acceleration, deceleration, turn speed, air control, jump velocity) **move to the stat manager**. Abilities read them through the context (`get_stat`), with failsafe defaults when a stat is missing. *(Revised 2026-11-04: previously the stats stayed on the pawn.)*
- **Rollback, pawn against pawn** *(added 2026-11-04)*: covered by `TickStateComponent._sync_collision` when both replay. Against a pawn that isn't replayed, it stays where it's drawn and the server corrects the difference, the standard behaviour (netcode spec section 6.5).
- **Rollback** *(added 2026-11-04)*: the motor reads a `grounded` state property rather than `is_on_floor()`, and refreshes the engine's private floor flag after a state load (netcode spec section 5.2). Its `safe_margin` is 0.0014 rather than Godot's 1 mm default, and the body itself never rotates: facing is a `yaw` state value and only the model turns (netcode spec section 5.3).
- **Facing is separate from moving.** The default faces the move direction (today's behaviour); `face_target` overrides it, so the pawn can face an enemy while backing away. Today only `characterModel` turns; the motor keeps that for now.
- **Escape clause:** with no locomotion ability present, the pawn falls back to its current built-in movement, so existing scenes keep working.

---

## 10. AI side (built), and how it connects

Built and tested (headless tests in `assets/scripts/Character Pawn/AI Core Components/tests/`):
- **Memory** (`AIMemoryComponent`): facts with confidence that fade unless refreshed; per-type half-life; signals.
- **States** (`AIStateManagerComponent`): lowest-priority-number valid state; default state; `force_state`; `can_exit` for permanent states. Example states: Dead, Incapacitated, Routed, Aggressive, Alerted.
- **Behaviours** (`AIBehaviourManagerComponent`): utility scores; gated by state; interrupt policy NEVER_UNTIL_DONE by default; cooldowns; wake on memory facts and state changes. Examples: Idle, Investigate.

Changes needed to connect them to this spec:
- Behaviours write the **AI controller's intent** (through context helpers) and send ability requests. They never touch the pawn directly.
- Behaviours gain `required_categories` (default empty): a behaviour whose required abilities the pawn lacks is quietly ineligible (a turret never runs Flee). This is checked with the same category masks.
- The context moves to the nexus (section 5).

---

## 11. Defaults and escape clauses

| Situation | Behaviour |
|---|---|
| No ability manager | `request_ability` does nothing; behaviours needing abilities are ineligible; the pawn uses its built-in movement |
| No locomotion ability | Built-in pawn movement (today's code) |
| Request matches no ability | Dropped; `has_ability()` lets callers check first |
| `cost_stat` set but the pawn lacks that stat | Not performable, with a one-time warning (silently free abilities would hide setup mistakes) |
| Movement stats missing | Walk uses its own failsafe defaults |
| No navigation | Straight-line steering |
| More than 64 category levels | Warning; masks extend later |
| Two abilities fit equally | Higher in the scene tree wins |
| Bad assembly (missing or duplicated components) | The nexus fills gaps with defaults and warns; no errors |

---

## 12. Performance

Per pawn, per frame, the planned work is:
- the active locomotion ability's update (one call)
- any timed action mid-swing (usually zero or one)
- the buffer, only if it holds requests (rare; one AND per entry)
- the motor's `move_and_slide`, which already dominates today

Everything else is event-driven: category tables, lockout masks, cooldown timestamps, idle managers asleep.

Rough estimates, GDScript:

| Pawns | Pawn-layer logic | Note |
|---|---|---|
| 100 | ~0.5 ms/frame | fine |
| 1,000 | ~3–5 ms/frame | physics bodies cost more than this |
| 10,000 | — | needs a separate data-oriented swarm tier (units as data, MultiMesh, flow fields, group decisions). Bitmask lockouts carry over to it unchanged |

**Planned:** a stress scene that spawns N pawns and reports frame times, to replace these guesses.

---

## 13. Migration from the current code

Built **alongside** the old system (per `CLAUDE.md`), switched over pawn by pawn.

| Today | Becomes |
|---|---|
| `MovementControllerManager`: one-frame request bus, priority per request | Controller manager deciding who has control; intent on the context |
| `PlayerControllerComponent` writes `pawn.speed` (sprint) and `pawn.velocity.y` (jump) directly | Writes intent and sends requests; Sprint and Jump become abilities |
| `ClickToMoveComponent` + `AIControllerBase`: near-duplicate path following, **sharing one NavigationAgent3D** | Controllers only write `move_target`; the navigation manager does path following once |
| Camera click signal moves **every** pawn with click-to-move | The player controller writes intent only for the pawn it controls |
| `CharacterPawn3D` turning and acceleration code | Walk ability, using the pawn's stats; the pawn keeps gravity and `move_and_slide` |
| Context owned by `AICoreComponent` | Owned by the nexus |
| About 2 frames of input lag from parent-before-child processing | Gone: the tick driver runs controller → abilities → motor in order within one tick |
| Each component runs its own `_process` / `_physics_process` | The tick driver calls them in fixed phases (netcode spec section 3) |
| `ClickToMoveComponent` | Navigation debug code; replaced, not ported |

---

## 14. Build order

Each step is testable on its own, with a headless test like the AI ones.

*(Revised 2026-11-04: the netcode foundation comes first, so abilities are built on it from day one.)*

1. **Tag registry + category masks.** Static class, declared categories in fixed order, parent bits, a test. **Built 2026-11-04.**
2. **Tick driver, offline** (netcode spec step 1). **Built 2026-11-04.** New pawn parts register with it as they're built.
3. **Networked state contract + offline rollback test** (netcode spec steps 2–3). **Built 2026-11-04:** `TickStateComponent`, `StateEncoding`, `NetworkTime.rollback`.
4. **Motor primitives** on the pawn, with save/load state. No behaviour change.
5. **AbilityBase + ability manager:** lockouts, buffer, cooldowns, costs, all in ticks, with save/load state. Tested with scripted test abilities, including a forced rollback.
6. **Walk + Sprint + intent fields + input commands + controller manager control.** Player WASD and AI `move_to` both drive Walk.
7. **Navigation manager v1:** Godot nav backend, direct/straight/path decision. Click-to-move through it.
8. **Jump + Dash:** buffer and lockouts in real use.
9. **MeleeAttack + teams + Chase/Flee behaviours + template pawn + arena + debug overlay:** the first fight loop.
10. **Stress scene:** real performance numbers.

Networking itself (transport, snapshots, interpolation, lag compensation) follows the netcode spec's build order from its step 4, once these exist.

---

## 15. Open questions

1. **Player input over navigated movement:** when the player presses WASD during a click-to-move, does the navigated target get **cleared** (today's behaviour) or **paused** and resumed on release?
2. **Facing:** confirm facing separate from moving, defaulting to "face where I'm moving".
3. **Who picks the domain** when several work (later): the navigation manager by cost (current lean) or the ability manager.
4. **Ability choice:** priority only (current plan), or scores later for situational choices?
5. **Death:** what a Dead pawn does tier 0 (stop and fall over? disable collision? despawn after a delay?).
6. **Teams and factions:** a team tag on the pawn plus a sensing filter. Also the general tag system for pawns (factions, squads, roles) vs the ability category registry: one registry or two?
7. **Intent contents and reading:** what else intent represents, and when and how each part reads it. Tabled 2026-11-04. A proposal (move target and mode, move scale, face / aim / focus targets, a held-modifier category mask) is ready to revisit. It now also defines the input command's contents.
8. **Ability selection when the requester is the AI:** should behaviours see why a request failed (locked, cooldown, cost, range) so they can react?
9. **Any-level tag search** ("sword" anywhere in a tag's path): removed from tier 0 on 2026-11-04 as too ambiguous. Needs a more robust design (e.g. declared aliases or explicit cross-cutting tags) before it's offered.

---

## 16. Decisions so far

| Decision | Date |
|---|---|
| The project is an engine-level base, not a game; examples grow into tier 0 features; graceful defaults matter for non-programmers | 2026-11-04 |
| Behaviour selection is full utility; interrupt policy defaults to NEVER_UNTIL_DONE; commitment bonus defaults to 0; corner cases documented in the manager | 2026-11-03/04 |
| States: lowest priority number wins; default state; force_state; can_exit; examples ported from the old enum rules | 2026-11-04 |
| Walking is not pathfinding: Walk only steers toward a point. Something else supplies the points | 2026-11-04 |
| WASD = a carrot point ahead in the camera-corrected direction, marked direct (never pathfinds) | 2026-11-04 |
| Walk holds the acceleration and turning code and reads the pawn's stats from the context, with failsafe defaults | 2026-11-04 |
| The pawn is the entity others reference; the nexus assembles it and prevents errors from bad setup | 2026-11-04 |
| Controllers hold intent; the controller manager decides who has control; the ability manager decides which ability fulfils it | 2026-11-04 |
| Intent is a few fields on the context; the final move destination lives there; waypoints stay inside navigation | 2026-11-04 |
| No order queue in the core (behaviours sequence; an optional component for RTS-style queues) | 2026-11-04 |
| A navigation manager per pawn; v1 single domain; it decides whether to path at all; weighting and multi-domain later | 2026-11-04 |
| Ability categories are StringName names with dot levels (not class hierarchy); one category plus optional extras | 2026-11-04 |
| Lockouts are an array of category names per ability, stored as bitmasks via a shared tag registry | 2026-11-04 |
| Lockouts are resolved inside the input buffer, so non-conflicting requests fire together | 2026-11-04 |
| Mashing is per ability: timestamps plus a retention window; REPLACE (anti-mash) by default, STACK optional | 2026-11-04 |
| Prototype batch 1: Walk, Sprint, Jump, Dash, MeleeAttack | 2026-11-04 |
| Inheritance: shallow, but not limited to one level; don't go overboard | 2026-11-04 |
| Event-driven is a preferred principle, not an absolute rule | 2026-11-04 |
| The context keeps its current name for now | 2026-11-04 |
| Movement stats move from the pawn to the stat manager; the pawn's main job is `move_and_slide` | 2026-11-04 |
| Controller manager: fixed order (player unless silenced > swarm director > AI), selecting which intent is enacted | 2026-11-04 |
| Click-to-move and directional input both move through the Walk ability; only the target mode differs | 2026-11-04 |
| Multiplayer: the pawn follows the netcode spec: tick driver, timing in ticks, ids across entities, save/load state on predicted parts | 2026-11-04 |
| Tag registry categories are declared up front and registered in sorted order, so bits match on every peer | 2026-11-04 |
| Abilities are set in seconds in the inspector and converted to ticks; each ability can override prediction | 2026-11-04 |
| The current click-to-move is navigation debug code and is replaced, not ported | 2026-11-04 |
| Tier 0 tag matching is from the root only; the any-level search is removed until it has a more robust design | 2026-11-04 |
