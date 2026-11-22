<!-- Written by Claude (claude-opus-5-5), 2026-11-17: the resources folder's overview, beside its code. -->

# Resources

The Resource classes a game fills in once, and the base's own files made from them. A designer changes these in the inspector, not in code.

**Status:** built, tier 0.

| Class | Files | What it holds | Read by |
|---|---|---|---|
| `InputActionsRes` | `input_actions.tres` | The named actions a game uses (jump, sprint, primary...), each given a bit in list order | `controllers/InputActions` |
| `PawnDefaultsRes` | `pawn_defaults.tres` | The parts every pawn gets, the default AI brain, and how far a player's pawn loads ground and nav | `game_mode/PawnInitializer`, streaming |
| `TagDeclarationsRes` | `tag_declarations.tres` (a game can add its own) | Every tag with a one-line description, plus renames (redirects) and deprecations, so every machine gives them the same bits | `tags/TagRegistry` |

`effects/` holds the ability effects (`Effect` resources) the samples use; see `assets/scripts/effects/`.

**Add an action or a tag:** add its name to the end of the list in the `.tres` file. **Change every pawn's parts:** edit `pawn_defaults.tres` (see [game_mode/README.md](../game_mode/README.md)).

Every class and setting: [REFERENCE.md](REFERENCE.md) (`python tools/docs/make_reference.py resources`). History: [CHANGELOG.md](CHANGELOG.md). Tests are with the systems that read these files.
