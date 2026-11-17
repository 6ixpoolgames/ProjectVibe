<!-- Written by Claude (claude-opus-5-5), 2026-11-17: the tags system's running changelog (the owner's call: history leaves the code
comments and lives here, next to the code). Newest first. Add an entry with every change; code comments say what the code does now,
this says how it got here and why. -->

# Tags changelog

Tags are this folder (`TagRegistry`, `Tags`), the declarations file (`resources/tag_declarations.tres`, `TagDeclarationsRes`) and the Tag Picker editor plugin (`addons/tag_picker/`). Design: [docs/pawn/PAWN_SPEC.md](../../../docs/pawn/PAWN_SPEC.md) sections 7.1 and 8.10, and the netcode spec section 13. Overview: [README.md](README.md).

## Refactor candidates

Code that works but doesn't yet fit the project's goals (reusable, extensible, efficient, designer friendly). Each is marked `REFACTOR:` in the code. Sizes are rough: S an hour or two, M a day, L more.

| What | Where | Why | Size |
|---|---|---|---|
| One tag-set class for abilities, nav and effects | `TagRegistry`, `navigation/NavTags`, `effects/EffectTags` | The same rules, copied on purpose when NavTags and EffectTags were written so working code didn't change. A single class used once per tag set is one place to fix and test, and a game's own tag set would come free. The matching row is in navigation's changelog | M |

## 2026-11-17

- **Comments cleaned up** for the documentation pass: dated notes moved here, doc comments in Godot's markup so the editor's help and `REFERENCE.md` show them properly. `MOVEMENT_BASIC` and `MOVEMENT_ADVANCED` got a doc line each, and `get_tag_count` a brief. The REFACTOR row above is marked in `TagRegistry`.

## 2026-11-15

- **`combat.parry`** declared, with `Tags.COMBAT_PARRY`, for `ParryAbility` (pawn spec 8.15).

## 2026-11-10

- **Typo protection** (pawn spec 8.10, the owner's request): `Tags` holds the declared tags as constants, so code can't misspell one, and the Tag Picker plugin gives designers dropdowns, from `TagRegistry.read_declared_tags()` (reads the file only, so it's safe in the editor).
- **Groups:** `movement.basic` (walk, sprint, jump) and `movement.advanced` (dash), now that an ability can carry several tags (`extra_categories`) and the AI asks for a group (`AbilityManager.action_for_tag`).
- **Combo tags** (pawn spec 8.11): `combo.second` and `combo.finisher`, which a swing's boosts raise so the next press picks them.

## 2026-11-04

- **`TagRegistry`** (pawn spec 7.1, netcode spec 13): declared tag names to bits, the same on every machine, with masks that hold parent levels; the netcode handshake compares its `content_hash()`. The any-level search (`level_mask`, `matches_level`: "sword" finding `combat.melee.sword` and `crafting.sword`) was taken out the same day: the owner wants it made more robust before it's offered, so tier 0 matches from the root only.
