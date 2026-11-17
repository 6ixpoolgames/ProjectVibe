<!-- Written by Claude (claude-opus-5-5), 2026-11-17: the standard terms the docs use, one line each. -->

# Glossary

The terms the docs use, with the standard name first. Where the base has its own class for it, that's named too.

| Term | Meaning |
|---|---|
| **Ability** | One thing a pawn can do (walk, jump, swing), started by pressing a named action. `AbilityBase` |
| **Ability step** | A piece of an ability that runs in order with others (wind-up, sweep, recover). `AbilityStep` |
| **Authority** | The machine whose word counts for an entity: the server for most things |
| **Autoload** | A Godot node made once at start-up and reachable by name everywhere. The base keeps them few |
| **Awareness** | How sure an AI is that it has seen something; it fills while it watches and fades after |
| **Chunk** | A square piece of terrain that loads and unloads as a whole |
| **Controller** | What drives a pawn: a player's input or an AI. `PlayerController`, `AIController` |
| **Effect** | Something applied to a pawn for a while or at once: damage, a slow, a heal. `EffectManager` |
| **Game mode module** | A node holding one of a game's rules, listed in a project setting. `GameModeModule` |
| **Interest** | An area where nav is built, around something that needs it |
| **Keyframe** | A full copy of the state, which later entries are compared against |
| **Lag compensation** | The server checking a hit against where things were when the player saw them. `LagCompensation` |
| **Load ladder** | Running far-away AI less often when the tick runs out of time |
| **Nav mesh** | The walkable surface as polygons, built from the level (Recast/Detour). `NavServer` |
| **Nav tier** | A nav mesh built for one size of pawn |
| **NavWalking** | Moving along the nav mesh instead of by physics, as Unreal does; cheaper and never through walls |
| **Off-mesh link** | A connection the nav mesh can't walk: a jump, a drop, a ladder, a door. `NavLink` |
| **Pawn** | Anything a player or an AI can drive. `Pawn` |
| **Part** | A child node of a pawn that gives it one ability set: stats, abilities, nav, AI |
| **Point of interest** | A spot that means something to AI: cover, a patrol point. `NavPoint` |
| **Possession** | A player taking control of a pawn; the AI takes over again when they let go |
| **Prediction** | A client running its own pawn ahead of the server, so input feels instant |
| **Replay** | A recording of a match, every tick, that can be played back. `ReplayRecorder` |
| **Rollback** | Going back to an earlier tick and running forward again with corrected input |
| **Smart object** | A spot AI can use, with a set number of users: a seat, a workbench. `NavSmartObject` |
| **Snapshot** | The server's view of the game at one tick, sent to clients |
| **Spawn** | Creating a pawn in the world at a free spot. `SpawnManager` |
| **Stat** | A number on a pawn that effects can change: health, speed, detectability. `Stat` |
| **Streaming source** | Something the world loads around: a player, a camera, an AI group. `StreamingSource` |
| **Tag** | A dotted name such as `link.jump` or `attack.melee`, turned into bits for fast checks |
| **Tick** | One fixed step of the game (1/60 s by default). All gameplay runs in ticks. `TickDriver` |
| **Tick step** | How many ticks a pawn skips: far-away AI runs every 2nd or 4th tick |
| **Tier** | A stage of the base: tier 0 is the foundations, tier 1 the next layer |
