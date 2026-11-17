<!-- Written by Claude (claude-opus-5-5), 2026-11-17: the tags system's overview, beside its code. -->

# Tags

Names like `combat.melee` that say what kind of thing an ability is, turned into bits so a game can ask "is this any kind of combat?" with one quick check, the same way on every machine.

**Status:** built, tier 0. Not yet: searching by any level ("sword" finding `combat.melee.sword`), and more than 64 tag levels.

| File | What it's for |
|---|---|
| [README.md](README.md) | This overview: what's here and how to use it |
| [REFERENCE.md](REFERENCE.md) | Every class, constant and function, generated from the code's doc comments (`python tools/docs/make_reference.py tags`) |
| [CHANGELOG.md](CHANGELOG.md) | What changed and why, newest first, and the refactor candidates |
| [PAWN_SPEC.md](../../../docs/pawn/PAWN_SPEC.md) | The pawn design: section 7.1 (tags) and 8.10 (typo protection, several tags per ability) |

## The pieces

```
 resources/tag_declarations.tres ──► TagRegistry ◄── abilities (category, extra_categories, locks_out)
   (the game's list of tags)         names ⇄ bits      AbilityManager (lockouts, interrupts, action_for_tag)
                                         ▲             NetworkSession (content_hash in the handshake)
 Tags.MOVEMENT_DASH (code) ──────────────┘
 addons/tag_picker (designers' dropdowns)
```

- **`TagRegistry`** turns tag names into bits. Every level of a tag has its own bit, and a tag's mask holds its parents' bits too, so a lockout on `combat` catches `combat.melee.sword`. It reads the declarations file on first use and numbers the tags in sorted order, so every machine agrees. A static class: nothing to add to a scene.
- **`Tags`** holds the declared tags as constants for code (`Tags.MOVEMENT_DASH`), so a typo is an error when the script is checked instead of a warning while playing.
- The **Tag Picker** editor plugin (`addons/tag_picker/`, not in this folder) gives designers a dropdown of declared tags in the inspector, from `TagRegistry.read_declared_tags()`.

Two other tag sets follow the same rules with their own 64 bits: `navigation/NavTags` (nav markers) and `effects/EffectTags` (effect types).

## How to use it

**Add a tag.** Add its full name, such as `combat.ranged.bow`, to `resources/tag_declarations.tres`. Its parent levels come with it. Designers can then pick it in the inspector. Only if code names it, add a constant to `Tags.gd` too (the test checks every constant is declared).

**Tag an ability.** Set the ability's category (and extra categories, for an ability in more than one group, such as `movement.dash` and `combat.evade`) from the dropdown.

**Ask about a tag in code.**
```gdscript
var mask := TagRegistry.mask_of(Tags.COMBAT_MELEE)   # its bit plus its parents'
if TagRegistry.matches(mask, Tags.COMBAT):           # true: combat.melee is inside combat
    pass
```
A lockout or a query on a branch uses `own_bit(tag)`; an ability's category uses `mask_of(tag)`.

**An unknown tag** used at runtime is added on the spot with a one-time warning. That's fine offline, but online two machines may number it differently, so declare every tag.

## Settings worth knowing

| Setting | Where | Default | What it does |
|---|---|---|---|
| `tags` | `resources/tag_declarations.tres` | the project's list | The tags the game declares; every machine numbers them the same |
| `project_base/tags/declarations_path` | Project Settings | `res://assets/scripts/resources/tag_declarations.tres` | Where the declarations file is, if a game keeps it elsewhere |

## How it works

- **Corner cases** (`tests/tag_registry_selftest.gd`): an empty or blank tag has no bit, mask 0, and matches nothing. Messy names (`combat..melee`, ` combat.melee `) are cleaned up. A tag nobody declared and used at runtime is added on the spot with a one-time warning (fine offline, a desync risk online); only setting up (`declare`, `bit_of`, `own_bit`, `mask_of` and the list versions) adds tags, while queries (`matches`, `has_tag`) never do. Declaring after the registry is in use counts as undeclared (appended and warned), since sorting again would change bits already stored in masks. With no declarations file every tag is simply undeclared. If 64 bits ever aren't enough, the mask could become an array of ints without changing how designers use tags.

## Tests

`tags/tests/tag_registry_selftest`: bits and masks, two machines agreeing, matching from the root only, late and messy tags, the 64-level limit, and that every `Tags` constant is declared. Also `addons/tag_picker/tests/tag_picker_selftest`. Run them with `bash tools/run_tests.sh <name>`.
