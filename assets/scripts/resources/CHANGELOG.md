<!-- Written by Claude (claude-opus-5-5), 2026-11-17: the resources folder's running changelog (the owner's call: history leaves the
code comments and lives here, next to the code). Newest first. -->

# Resources changelog

The Resource classes in this folder (`InputActionsRes`, `PawnDefaultsRes`, `TagDeclarationsRes`, and the definitions' `Definition`, `DefinitionSettings` and `DefinitionRegistry`). Overview: [README.md](README.md).

## Refactor candidates

None found.

## 2026-11-25

- **Definitions live here** (pawn spec 16.10 step 6c). `Definition` and `DefinitionRegistry` moved from `abilities/definitions/` (their history until now is in the abilities changelog), now that AI behaviours have definitions too. `DefinitionSettings` (new) is how a node works out its settings, shared by `AbilityBase` and `AIBehaviourBase`. `ai_behaviours/` (new) holds the samples' behaviour definitions, and the registry numbers them with the ability files. `Definition.resolved_from` became a weak link, ending a cycle that leaked every variant at exit.

## 2026-11-23

- **`archer_bolt_attack.tres`**: the four-faction archers' bolts, a variant of `bolt_attack.tres` with a 6-bolt magazine that comes back whole 10 s after the first is spent. New tags declared: the stances and `status.has_ammo`.
- **Documentation pass:** the README brought up to the resources there are now.

## 2026-11-22

- **`TagDeclarationsRes`** holds each tag with a one-line description (`tags`, a dictionary), plus `redirects` (old name to new) and `deprecated` (tag spec). `tag_declarations.tres` is the one base file, with `nav_tag_declarations.tres` and `effect_tag_declarations.tres` merged into it and every tag renamed with its category. Ability and effect resources were rewritten to the new names.

## 2026-11-19

- **`pawn_defaults.tres` lists `PawnStreamingSource`** as the last default part.

## 2026-11-18

- **Comments rewritten to the reference style** (the documentation pass): the `PawnDefaultsRes` member comments shortened; "the owner's call" on `world_load_distance` dropped (the owner chose a game-wide setting). `GDScript note:` teaching comments removed, keeping any non-obvious fact shortened.

## 2026-11-17

- **Comments cleaned up** for the documentation pass. `TagDeclarationsRes` said its tags were ability categories, "later nav capabilities"; it's now used by three tag sets (abilities, nav, effects), each with its own file.

## 2026-11-16

- **A default AI brain** (the owner's call): `PawnDefaultsRes.ai_brain`, an `AIBehaviourManager` scene with behaviours that a pawn without its own gets.
- **`world_load_distance`** (pawn M2, the owner's call): how far a pawn that keeps the world loaded loads ground, one setting for the game. It was a setting on each pawn. With it, `world_nav_distance`: how far nav is built around such a pawn, shorter than the ground, since building nav as far out would be slow.

## 2026-11-08

- **`PawnDefaultsRes`** (pawn spec section 11, step 4): the parts every pawn gets, for `PawnInitializer`.

## 2026-11-07

- **`InputActionsRes`** (pawn spec section 5): a game's named actions, replacing intent with inputs.

## 2026-11-04

- **`TagDeclarationsRes`**: the tags a game declares up front, for `TagRegistry`.
