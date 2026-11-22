<!-- Written by Claude (claude-opus-5-5), 2026-11-17: the tags system's overview, beside its code. -->

# Tags

Names like `ability.combat.melee` or `nav.point.cover` that say what something is, turned into bits so a game can ask "is this any kind of combat?" with one quick check, the same way on every machine. One registry for every kind of tag: abilities, effects, a pawn's status, the AI, navigation.

**Status:** built, tier 0 (tag spec step 1). Next: the tags a pawn owns right now, and tag queries (tag spec step 2). Not yet: more than 64 levels in one category.

| File | What it's for |
|---|---|
| [README.md](README.md) | This overview: what's here, how to use it, naming rules, how to rename |
| [REFERENCE.md](REFERENCE.md) | Every class, constant and function, generated from the code's doc comments (`python tools/docs/make_reference.py tags`) |
| [CHANGELOG.md](CHANGELOG.md) | What changed and why, newest first, and the refactor candidates |
| [TAGS.md](../../../docs/tags/TAGS.md) | Every declared tag with what it is, its old names and deprecations (`python tools/tags/make_tag_reference.py`) |
| [TAG_SPEC.md](../../../docs/tags/TAG_SPEC.md) | The design: one registry, categories, owned tags, tag queries, changing a tag later |

## The pieces

```
 resources/tag_declarations.tres ─┐
 (a game's own files, listed in   ├─► TagRegistry ◄── abilities (category, extra_categories, locks_out, cancelled_by)
  project_base/tags/              │   names ⇄ bits     effects (tags, resistances), nav markers (tag)
  extra_declaration_files)       ─┘        ▲           NetworkSession (content_hash in the handshake)
 Tags.ABILITY.MOVEMENT_DASH (code) ────────┘
 addons/tag_picker (designers' dropdowns, by category)
```

- **`TagRegistry`** turns tag names into bits. A tag's first level is its **category** (`ability`, `effect`, `status`, `ai`, `nav`), and each category numbers its own levels in its own 64-bit word. Every level has its own bit and a tag's mask holds its parents' bits too, so a lockout on `ability.combat` catches `ability.combat.melee`. It reads the declarations files on first use and numbers the tags in sorted order, so every machine agrees. A static class: nothing to add to a scene.
- **`Tags`** holds the declared tags as constants for code, one group per category (`Tags.ABILITY.MOVEMENT_DASH`, `Tags.EFFECT.DAMAGE_POISON`), so a typo is an error when the script is checked instead of a warning while playing. The groups are in capitals because a class named `Effect` would clash with the effects system's.
- **`TagDeclarationsRes`** (`resources/`) is a declarations file: every tag with a one-line description, plus redirects (renames) and deprecations.
- The **Tag Picker** editor plugin (`addons/tag_picker/`, not in this folder) gives designers a dropdown of declared tags in the inspector, only of the categories each setting takes.

## How to use it

**Add a tag.** Add its full name and a one-line description to `resources/tag_declarations.tres` (or a game's own declarations file), and its parent levels with theirs. Designers can then pick it in the inspector. Only if code names it, add a constant to `Tags.gd` too (the test checks every constant is declared and named after its tag). Then run `python tools/tags/make_tag_reference.py` to refresh the tag list.

**Tag an ability.** Set the ability's category (and extra categories, for an ability in more than one group, such as `ability.movement.dash` and `ability.combat.evade`) from the dropdown.

**Ask about a tag in code.**
```gdscript
var mask := TagRegistry.mask_of(Tags.ABILITY.COMBAT_MELEE)   # its bit plus its parents'
if TagRegistry.matches(mask, Tags.ABILITY.COMBAT):           # true: ability.combat.melee is inside ability.combat
    pass
```
A lockout or a resistance on a branch uses `own_bit(tag)`; an ability's category uses `mask_of(tag)`. **A mask belongs to one category:** an ability mask is compared with ability tags, an effect mask with effect tags. A list that mixes categories warns.

**An unknown tag** used at runtime is added on the spot with a one-time warning. That's fine offline, but online two machines may number it differently, so declare every tag.

## Naming rules

A tag is hard to change once saved files and replays use it, so it's worth getting right:
- Lowercase, words joined by underscores, levels by dots: `ability.combat.melee`, `status.knocked_down`.
- The category first. A game adds its own categories (`faction`, `squad`) in its own declarations file.
- Say what it is, not who uses it: `status.stunned`, not `ai_should_flee`.
- A noun or a state, at most four levels.
- Every level declared, each with a one-line description.

## Renaming, deprecating, removing

- **Rename:** declare the new name, then add the old one to the declarations file's `redirects` (old → new). The game reads the old name as the new one, with a warning. Run `python tools/tags/apply_redirects.py` (editor closed) to rewrite saved scenes and resources; it lists any old names left in scripts to change by hand. Keep the redirect for good, so old replays and saves still load.
- **Deprecate:** add the tag to `deprecated`. It still works, with a warning, and the picker hides it.
- **Remove:** only once nothing saved uses it. Never reuse a removed name for something else; changing what a tag means is a new tag.
- **Bits are never saved.** Resources, saves and replays store names, so adding a tag (which can renumber others) is always safe.

## Settings worth knowing

| Setting | Where | Default | What it does |
|---|---|---|---|
| `tags` | `resources/tag_declarations.tres` | the base tags | Every tag with its description; every machine numbers them the same |
| `redirects`, `deprecated` | the same file | the old names from before the merge | Renames and tags on their way out |
| `project_base/tags/extra_declaration_files` | Project Settings | none | More declarations files (a game's, a mod's), read after the base one |

## How it works

- **Corner cases** (`tests/tag_registry_selftest.gd`): an empty or blank tag has no bit, mask 0, and matches nothing. Messy names (`ability.combat..melee`, ` ability.combat.melee `) are cleaned up. A tag nobody declared and used at runtime is added on the spot with a one-time warning, in a category of its own if its category is new; only setting up (`declare`, `bit_of`, `own_bit`, `mask_of` and the list versions) adds tags, while queries (`matches`, `has_tag`) never do. Declaring after the registry is in use counts as undeclared (appended and warned), since sorting again would change bits already stored in masks. With no declarations file every tag is simply undeclared.
- **64 levels per category.** Past that a category's tags get no bit, with a warning. The tag spec plans a second word for such a category; today's int masks assume one, so that waits until a category nears the limit (a refactor row in the changelog).

## Tests

`tags/tests/tag_registry_selftest`: bits and masks, categories and their words, two machines agreeing, matching from the root only, late and messy tags, the 64-level limit per category, redirects and deprecation, the declarations file (every tag described, every `Tags` constant declared and named after its tag). Also `addons/tag_picker/tests/tag_picker_selftest`. Run them with `bash tools/run_tests.sh <name>`.
