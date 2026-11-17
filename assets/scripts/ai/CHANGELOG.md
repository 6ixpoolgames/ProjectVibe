<!-- Written by Claude (claude-opus-5-5), 2026-11-17: the AI system's running changelog (the owner's call: history leaves the code
comments and lives here, next to the code). Newest first. Add an entry with every change; code comments say what the code does now,
this says how it got here and why. -->

# AI changelog

The AI is this folder (the context, sensing, memory, target selection, states and behaviours), the AI controller that acts for it (`controllers/AIController`), and its C++ side in `native/src/` (`AIMemoryStore`, `AIPawnGrid`, `AISensingJob`, `SightGeometry`, `ai_sight_rules.h`). Design: [docs/pawn/PAWN_SPEC.md](../../../docs/pawn/PAWN_SPEC.md) section 10, and [docs/scaling/SCALING_SPEC.md](../../../docs/scaling/SCALING_SPEC.md) sections 3 to 7 for the C++ and worker-thread parts. Overview: [README.md](README.md).

## Refactor candidates

Code that works but doesn't yet fit the project's goals (reusable, extensible, efficient, designer friendly). Each is marked `REFACTOR:` in the code. Sizes are rough: S an hour or two, M a day, L more.

| What | Where | Why | Size |
|---|---|---|---|
| One way to find a sibling part early | `_sibling_ability_manager()` in `AIContextComponent` and `AIBehaviourManager` | The same lookup written twice, because `pawn.ability_manager` isn't set until the pawn's own `_ready`, after the parts'. One shared helper (on Pawn, say) is one place to change | S |
| One forcing-and-queueing helper | `AIStateManager.force_state`, `AITargetSelector.force_target` | Forcing with a priority and a hold, refusing a weaker force, and queueing requests made during a tick are the same rules written twice; they could drift apart | M |
| One copy of the sight rule in GDScript | `SightSense.visibility_of`, `has_line_of_sight` | A third copy of the visibility and ray rules, beside `AIMemoryStoreGD` and C++'s `ai_sight_rules.h` (that pair is deliberate: a fallback checked by the tests). Asking the pawn's memory store would leave one GDScript copy | S |
| One `_point_of_interest()` | `AIInvestigateBehaviour`, `AILookTowardBehaviour` | The same function twice; one copy (on the context, say) keeps the two reacting to the same things | S |
| Attack reach from any ability | `AIAttackBehaviour._find_melee` | It reads its reach only from a `MeleeAttackAbility`, so a ranged or other attack can't use the Attack behaviour. A reach asked through `AbilityBase` would let one behaviour drive any attack | M |
| The sprint action's name as a setting | `&"sprint"` in `AIChaseBehaviour`, `AISearchBehaviour`, `AIInvestigateBehaviour` | Written into the code, so a game that names its sprint action differently has to edit three behaviours. A setting, or a tag as Chase's `close_in_tag` is, would need no code | S |

## 2026-11-17

- **The pawn holds only `ai_context`** (the wider code audit, the owner's call). The context finds the pawn's other AI parts itself (`memory`, `state_manager`, `behaviour_manager`, `sensing_manager`, `target_selector`), looking again when a part is added or removed, and stops listening to a pawn it leaves. The pawn used to hold a reference to each.
- **The C++ bundle:** the sensing grid is made by `Pawn.get_grid()`, which the swing hit checks share (`AIPawnGrid.find_touching`); bounds checks in `AIMemoryStore`; fewer engine calls per sensed pawn; SightGeometry checks static bodies less often.
- **Comments cleaned up** for the documentation pass: dated notes moved here, doc comments in Godot's markup. Fixed stale comments: the context's usage said `has_target()` was false "until step 8b"; hits and incoming swings were said to come from `Pawn.receive_hit` and `Pawn.notice_incoming_attack` (they come from the AbilityManager's `hit_arrived` and straight from `MeleeAttackAbility`); the comment above `_exit_tree` described hit listening; `run_ai`'s order left out the queued forces; "the pawn calls this" on functions `run_ai` calls; the Attack behaviour said it pressed once and could start "a follow-up" (it holds through the swing, and combos replaced follow-ups); memory's threat was "0 in t0" (damage adds it); FadeProfile said memory used it "from step 8b"; AIMemoryStoreGD said the test ran both stores at once (one per run). Two comments marked `GDScript note:` that were design notes (Parry's and Wander's scores) lost the label.

## 2026-11-16

- **`run_ai` moved into the context** (pawn M1, the owner's call: the AI's core part runs the AI; the pawn only calls it). It was `Pawn._tick_ai`.
- **Listening instead of being called** (pawn M3): the context notes every hit, parried ones included, from the AbilityManager's `hit_arrived` (`Pawn._take_hit` used to call `note_hit`); the behaviour manager stops the running behaviour on `died` (`Pawn._die` used to call it); an enemy's swing reaches the context's `note_incoming_attack` directly (was `Pawn.notice_incoming_attack`).
- **Teams from the TeamRegistry** (pawn M1): sensing skips its query when the `TeamRegistry` module says no pawn is on another team (was a counter on Pawn). The player check reads the ControllerManager (pawn M4).
- **Stepped pawns** (pawn spec 8.21): decisions, sensing passes and behaviour ticks use `fired_since_last_run`, so a pawn running every 2nd or 4th tick still gets those that fell between its runs. A stepping pawn asks the sensing job ahead, at the end of the tick before its next run, so it no longer senses on the main thread; a repeat ask for the same tick is dropped.
- **Attack holds its action** (pawn spec 8.20): through the swing, so it keeps turning toward its target (TurnToFaceStep), letting go for a tick first if the last swing ended that tick, and when the swing ends. `attack_action` is gone: `presses_action` is the one setting (the two had to match by hand). Parry presses its `presses_action` (it pressed "parry" whatever the setting said).
- **Fixes and speed-ups from the wider audit:** `max_ticks_since_seen` is converted for the match's tick rate (120 ticks was 2 s at 60 and 4 s at 30); the target selector announces a freed old target as null, which typed listeners (the replay, the AI debug timeline) failed on; the context keeps its name hash until the name changes; Attack asks the AbilityManager `is_action_running` instead of copying the pawn's ability list every tick; Go To Point keeps its point and looks again every 2 s instead of every decision; `SightGeometryFeeder` doesn't ask whether the class exists on every pass; the sight sense reuses the settings it sent the job; the TickDriver autoload replaces lookups by path. PerfScopes time sensing, deciding and behaviours for diagnostics.

## 2026-11-15

- **Go To Point** (pawn spec 8.15, the owner's request): idle pawns march in legs to the nearest node in the `rally_point` group, for the mass battle.
- **Parry** (pawn spec 8.15): an enemy's swing warns the pawns it may reach, and `AIParryBehaviour` parries about 30% of them (`parry_chance`), rolled once per swing.

## 2026-11-12

- `at_tick` parameters in `AIBehaviourBase` (`tick` clashed with `tick()` and warned); `String()` in two warnings, so both sides are text; the sight refresh checks `has_target()` before casting, since a freed target was a script error that stopped the faction arena.

## 2026-11-10

- **Chase closes in by tag** (pawn spec 8.10): `close_in_tag` (advanced movement) through `AbilityManager.action_for_tag`, not Dash by name. Dash distances 5.5 to 7.5 m for the reworked dash (were 4 to 6), which works in the air.
- **Attack waits for whichever swing runs** on its action (pawn spec 8.8, 8.11): a follow-up then, a combo's next swing now.

## 2026-11-09

- **AI deciding** (pawn step 8a, pawn spec 10.1 to 10.10): `AIContextComponent`, `AIStateManager` with `AIStateBase` and `AIIdleState`, `AIBehaviourManager` with `AIBehaviourBase` (scoring with ranges, interrupts, persistence, jitter, a fixed order), `FadeProfile`, and `AIWanderBehaviour`.
- **AI noticing** (pawn step 8b, pawn spec 10.11): `AISensingManager`, `AISenseBase` and `SightSense`; `AIMemory` with fading awareness; `AITargetSelector`; `AIAwarenessState` for Alert and Combat; Look Toward, Investigate, Search and Chase. The highest floor comes from the first available behaviour (found in step 8b: a fixed-score behaviour that didn't apply shut out ones that did). Each behaviour's `tick_interval_ticks`, and sight refreshing only the current target, after `ai_stress` measured the cost.
- **AI perception in C++** (pawn spec 10.12): `AIMemoryStore` and `AIPawnGrid` in navcore; the GDScript code moved to `AIMemoryStoreGD` behind the same functions, used without the library or with `AIMemory.use_native` off.
- **Hits** (pawn step 10): the context keeps the last hit and attacker; `AIAwarenessState`'s hit rule (Combat for a known attacker, Alert for an unknown one, no damage sense); Look Toward and Investigate turn to an unknown attacker; damage adds threat (`threat_per_damage`); dead pawns aren't seen and are forgotten. Step 9's Attack behaviour and Chase's `stop_distance` 1.2 (was 1.5), inside the swing's reach; `dash_to_close` for the arena's goblins.
- **Tier 1 (scaling spec):** step 1, the grid reads the shared pawn table (it replaced `track_pawn`); step 2, the sensing job on worker threads; step 3, forces and taunts asked for during a tick wait for the pawn's next AI step, and awareness is held while the last check saw the entity (a target in plain view drifted down between checks); step 4, line of sight in C++ against `SightGeometry`, fed by `SightGeometryFeeder`; step 6 (committed 2026-11-10), every tick setting is written for 60 a second and converted to the match's rate.
