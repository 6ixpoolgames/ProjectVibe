<!-- Written by Claude (claude-opus-5-5), 2026-11-17: the tags system's running changelog (the owner's call: history leaves the code
comments and lives here, next to the code). Newest first. Add an entry with every change; code comments say what the code does now,
this says how it got here and why. -->

# Tags changelog

Tags are this folder (`TagRegistry`, `Tags`), the declarations file (`resources/tag_declarations.tres`, `TagDeclarationsRes`), the tools in `tools/tags/` and the Tag Picker editor plugin (`addons/tag_picker/`). Design: [docs/tags/TAG_SPEC.md](../../../docs/tags/TAG_SPEC.md); before it, [pawn spec](../../../docs/pawn/PAWN_SPEC.md) sections 7.1 and 8.10 and the netcode spec section 13. Overview: [README.md](README.md).

## Refactor candidates

Code that works but doesn't yet fit the project's goals (reusable, extensible, efficient, designer friendly). Each is marked `REFACTOR:` in the code. Sizes are rough: S an hour or two, M a day, L more.

| What | Where | Why | Size |
|---|---|---|---|
| More than 64 levels in a category | `TagRegistry` | The tag spec gives a category that outgrows its word a second one. Every caller's mask is one int today, so that waits until a category nears 64 levels; past it, tags get no bit with a warning | M |

## 2026-11-22

- **One registry for every kind of tag** (tag spec step 1, agreed with the owner): `TagRegistry` now holds ability, effect and navigation tags, and the AI's and a pawn's status. A tag's first level is its category (`ability`, `effect`, `status`, `ai`, `nav`), each numbering its own levels in its own 64-bit word, so today's one-AND checks are unchanged. `navigation/NavTags` and `effects/EffectTags`, copies of the same rules, are gone (the refactor row is done). New: `category_of`, `get_categories`, `word_of`, `description_of`, `is_deprecated`, `declare_redirects`, `declare_deprecated`; `names_of` takes the category; `category_mask_of_list` is `full_mask_of_list` (the name EffectTags and NavTags used), since "category" now means the first level. A list mixing categories warns.
- **Every tag renamed with its category:** `combat.melee` is `ability.combat.melee`, `damage.poison` is `effect.damage.poison`, `point.cover` is `nav.point.cover`. The Death ability's category is `ability.death` (it was `status.dead`, which stays as the pawn's condition for owned tags). Saved resources and scenes were rewritten; every old name has a redirect.
- **Declarations:** `TagDeclarationsRes` holds each tag with a one-line description, plus `redirects` and `deprecated`. One base file (`resources/tag_declarations.tres`, the three merged); a game lists more in the project setting `project_base/tags/extra_declaration_files` (the old `project_base/tags/declarations_path` and `project_base/nav/tag_declarations_path` are gone).
- **Constants grouped by category:** `Tags.ABILITY.COMBAT_MELEE`, `Tags.EFFECT.DAMAGE_POISON`, `Tags.STATUS.DEAD`, `Tags.NAV.POINT_COVER`; `ALL` is the category itself. The groups are in capitals because an inner class named `Effect` would clash with the effects system's `Effect` (Godot refuses it).
- **Tag Picker:** each tag property names the categories its dropdown offers; nav markers' `tag` gets a dropdown too; deprecated tags are hidden.
- **Tools:** `tools/tags/apply_redirects.py` rewrites old names in saved scenes and resources (and lists any left in scripts); `tools/tags/make_tag_reference.py` writes `docs/tags/TAGS.md`, every tag with its description and old names.
- **Tests:** `tag_registry_selftest` covers categories, words, redirects, deprecation, descriptions and the grouped constants; `nav_tags_selftest` is gone with `NavTags` (its checks are the same rules).

## 2026-11-18

- **Comments rewritten to the reference style** (the documentation pass): the `TagRegistry` class comment cut to the bit rules (the corner cases moved to the README's "How it works"); the `Tags` class comment shortened. `GDScript note:` teaching comments removed, keeping any non-obvious fact shortened.

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
