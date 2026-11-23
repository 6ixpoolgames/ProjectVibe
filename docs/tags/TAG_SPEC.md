# Tag Spec v0.2 (agreed 2026-11-22; steps 1 and 2 built, see 11 and 12)

*Written by Claude (claude-opus-5-5), 2026-11-22, from the discussion with the owner the same day. The owner agreed the recommendations in section 10. Names follow Unreal's gameplay tags where that helps, but this isn't a copy of it: close-enough terms the project already uses stay.*

**What it changes:** the three tag registries become one, with categories as the first level of every tag. Pawns get a record of the tags they own right now (owned tags), and a tag query (all of, any of, none of) can be asked of it. The first user is the AI's score modifiers and blocking modifiers ([pawn spec 10.13](../pawn/PAWN_SPEC.md)); abilities and effects can use the same queries later.

**Why now:**
- **Three copies of one thing.** `TagRegistry` (abilities), `EffectTags` and `NavTags` have the same rules (dotted levels, a tag covers the tags under it, one bit per level), each with its own declarations file, 64-bit limit, constants and network fingerprint.
- **Kinds already mix.** The ability list holds `status.dead` (the Death ability's category) and `combo.second`, which aren't kinds of ability.
- **Nothing records what a pawn is right now.** Abilities and effects carry tags as labels on themselves, but nothing answers "is this pawn stunned, in combat, out of ammo?". The AI's blocking modifiers and tag requirements need exactly that, about anything.

## 1. Terms

Standard terms, as in Unreal's gameplay tags, which this follows:
- **Tag:** a dotted name, such as `ability.combat.melee`. Each part is a **level**; a tag covers the tags under it (`ability.combat` covers `ability.combat.melee`, never `ability.combatant`).
- **Category:** a tag's first level (`ability`, `effect`, `status`). Categories are declared like tags, with a description.
- **Mask:** a tag's bits: its own bit plus its parents'. Runtime only (section 5).
- **Owned tags:** the tags a pawn has right now, counted (section 3).
- **Loose tags:** owned tags a game's code adds itself, rather than ones that come from an ability or effect.
- **Redirect:** an old tag name read as a new one (section 5).
- **Tag query:** all of / any of / none of, asked of owned tags (section 4).

## 2. One registry

**Declarations.** One `TagRegistry`, static as today. Tags are declared in files, each entry a tag and a one-line description. The base has its file; a game, and later a mod, adds its own (a project setting lists them). They're merged and sorted at startup, so every machine numbers them the same.

**Bits.** Every level of every tag gets one bit, numbered within its category:
- Each category owns as many 64-bit words as its levels need, laid out one category after another. Almost every category fits in one word.
- A category that grows past 64 levels takes another word; only checks in that category get longer. Nothing is reserved and there is no hard limit.
- A query is compiled to the words it touches, so a check within one one-word category (an ability lockout) stays one AND, as today.
- C++ gets the same layout as an array of 64-bit words.

**Constants.** One class for code, so a misspelling is an error when the script is checked, grouped by category through inner classes: `Tags.Ability.COMBAT_MELEE`, `Tags.Status.DEAD`. Autocomplete narrows by category, and no constant repeats its category's name.

**The tag picker.** One dropdown source. Each tag setting names the categories it accepts (an ability's category offers `ability.*`, a nav link `nav.*`); a tag query offers everything. Descriptions show as tooltips.

**The network.** One fingerprint of the merged table in the handshake, in place of three.

## 3. Owned tags

Each pawn gets `owned_tags`: a count per tag, and the masks of every tag with a count above 0 (with its parents). Two sources adding the same tag need two removals before it's gone.

**Who adds what:**
- a running ability: its category tags, while it runs
- a held effect: its tags, while it's held
- the AI state manager: `ai.state.<state>`, on the server
- death: `status.dead`
- an AI score modifier: its `granted_tags`, while it's active (pawn spec 10.13)
- an ability with charges: the tag its definition names, while it has charges left (pawn spec 10.13)
- a game's own code: loose tags, `owned_tags.add(tag)` / `owned_tags.remove(tag)`

**Rollback.** Tags from abilities and effects follow state that already rolls back, so they're worked out again after a rollback rather than stored twice. Loose tags are pushed as state (one count per loose tag), so they roll back and a client's prediction agrees with the server. AI tags exist only on the server, which never rolls back AI.

**Signals.** `owned_tags.changed(tag, owned)` fires when a tag goes from not owned to owned or back, for things that react (a stun icon, a decision wake).

## 4. Tag queries

`TagQuery`: a small resource with three lists, all of which must pass:
- `all_of`: every one owned ("only when")
- `any_of`: at least one owned ("when this or that"); empty passes
- `none_of`: none owned ("not when")

`query.matches(owned_tags)` is a few ANDs over the words it touches. Each list's tags cover the tags under them. Nested queries ("(A or B) and not C" inside a larger one) wait until something needs them.

**Users:**
- **AI score modifiers and blocking modifiers** (pawn spec 10.13): which behaviours a modifier applies to (a query over behaviour tags) and when it counts (a query over the pawn's owned tags, its ongoing requirements).
- **Behaviours:** optional tag requirements, beside their conditions over AI inputs. Tags answer yes/no facts; inputs stay for numbers (distance, health).
- **Later:** abilities requiring or blocking tags to start (today's lockouts are a narrow form of this), effect immunities.

## 5. Changing a tag later

The owner's concern: a tag, once made, is hard to change. It can be changed, at the price of a redirect kept for good. What truly breaks things is changing what a tag means.

**Rules:**
- **Bits are never saved.** Resources, saves and replays store tag names; bits exist only while running. The network uses bits only after the handshake proves both sides have the same table. This already holds today, so renumbering (adding a tag) is always safe.
- **Renaming:** add a redirect (old name → new name) to the declarations. Resources, saves and replays are read through the redirects; the picker flags old names; a tool rewrites resources to the new names. The redirect stays so old replays and saves still load. (Unreal keeps a redirect list for the same reason.)
- **Removing:** mark the tag deprecated first (still declared, hidden in the picker, a warning when used), then remove it once nothing saved uses it. Never reuse a removed name for a different meaning.
- **Changing what a tag means:** make a new tag and deprecate the old one.

**Replays:**
- A state-based replay (today's replay v0) stays viewable across versions if it stores the names of the tags it holds and is read through the redirects.
- An input-based (deterministic) replay, which re-simulates from inputs (the state store plan's), is tied to its build anyway: any change to code or data changes the result. It stores its build id and needs that build, as most games do. Tags add nothing to that limit.

## 6. Documentation

Because changes cost a redirect for good, tags get documented as they're made:
- Every category and tag declaration carries a one-line description: what it is, not who uses it.
- A generated tag reference (`docs/tags/TAGS.md`, and in the wiki): every category and tag with its description, its redirects and deprecations.
- Naming rules in the tags README: lowercase, words joined by underscores, the category first, a noun or state ("stunned", not "stun_me"), no more than four levels.
- The rename, deprecation and redirect steps above, in the tags README.

## 7. Categories and today's tags

Proposed base categories, with today's tags moved in:

| Category | What it holds | Today's tags |
|---|---|---|
| `ability` | what an ability is | `movement.*`, `combat.*`, `utility.*`, `combo.*` → `ability.movement.walk`, `ability.combat.melee`, `ability.combo.second`... |
| `effect` | what an effect is | `damage.*`, `heal`, `buff.*`, `debuff.*` → `effect.damage.fire`, `effect.heal`, `effect.buff.combo`... |
| `status` | a condition a pawn is in | `status.dead` (unchanged; it was in the ability list); new: `status.has_ammo.ranged` |
| `ai` | the AI's states and stances | new: `ai.state.combat`, `ai.stance.melee`, `ai.stance.ranged` |
| `nav` | navigation markers and areas | `link.*`, `area.*`, `point.*`, `use.*`, `obstacle.*` → `nav.link.jump`, `nav.area.road`... |

A game adds its own (`faction`, `squad`) in its own file. No top-level `state`: in this codebase "state" already means recorded data (the state store, rollback state), so a pawn's conditions go under `status` and the AI's states under `ai.state`.

## 8. What changes in today's code

- **Merged:** `TagRegistry`, `EffectTags` and `NavTags` into one registry; the three declaration files into one base file; `Tags` and `EffectTags`' constants into one class; the picker's two tag sets into categories; the handshake's three fingerprints into one.
- **Renamed:** every tag gains its category. About 15 scripts use the registries, and 22 saved resources and scenes name tags; all are updated in the same change, legacy files included where they name tags (now allowed). Tests are updated to match.
- **New:** owned tags on the pawn, `TagQuery`, redirects and deprecation, the tag reference generator.
- **Measured:** ability lockout checks and effect resistance checks, before and after, at 300 pawns.

## 9. Build order, once agreed

1. The merged registry, declarations with descriptions, constants, the picker, redirects, the reference generator. Every tag renamed by a rewrite tool that stays for later renames, with a redirect from each old name.
2. Owned tags (with loose tags pushed as state) and `TagQuery`.
3. AI score modifiers and blocking modifiers (pawn spec 10.13). *(Built 2026-11-23, with behaviour tag requirements in place of `allowed_states`.)*
4. Charges and the melee and ranged stances. *(Built 2026-11-23, with ability start requirements.)*
5. The mass battle switch between melee and ranged. *(Scrapped 2026-11-23, the owner: the four-faction archers switch when their magazine runs out instead.)*

## 10. Decided (the owner, 2026-11-22, agreeing the recommendations)

1. Constants grouped by category (`Tags.Ability.COMBAT_MELEE`).
2. Categories as in section 7: `ability`, `effect`, `status`, `ai`, `nav`; no top-level `state`.
3. Loose tags are pushed as state and roll back.
4. The rewrite tool and redirects come with the merge, which is the first rename.

## 11. As built: step 1 (Claude, 2026-11-22)

**Where things are:** `assets/scripts/tags/TagRegistry.gd` (the one registry), `Tags.gd` (constants), `resources/TagDeclarations_resource.gd` and `resources/tag_declarations.tres` (the base file: 59 tags in 5 categories, every one described, 52 redirects from the old names), `tools/tags/apply_redirects.py` and `make_tag_reference.py`, the generated list [TAGS.md](TAGS.md), and the Tag Picker (`addons/tag_picker/`). How to use it, the naming rules and the rename steps: the [tags README](../../assets/scripts/tags/README.md).

**What differs from the text above:**
- **Constant groups are in capitals:** `Tags.ABILITY.COMBAT_MELEE`, `Tags.EFFECT.DAMAGE_POISON`, `Tags.STATUS.DEAD`, `Tags.NAV.POINT_COVER`, with `ALL` for the category itself. Godot refuses an inner class named `Effect` because the effects system has a class of that name, and capitals can't clash with any class.
- **One word per category for now.** Every caller's mask is a single int, so a category past 64 levels gets no more bits (with a warning) rather than a second word. Today's largest, `ability`, has 21 levels. The second word waits until a category nears the limit (a refactor row in the tags changelog).
- **The Death ability's category is `ability.death`.** An ability's tags are compared as one category's masks, so its category can't be `status.dead`; `status.dead` stays declared for the pawn's owned tags (step 2).
- **Tags under `ai`:** the AI states (`ai.state.*`, section 12) and the stances (`ai.stance.melee`, `ai.stance.ranged`, behaviours' own tags). Under `status`: `status.has_ammo.ranged`, owned while a ranged attack has charges.
- **Nav markers' `tag` got a Tag Picker dropdown** along the way.
- `category_mask_of_list` became `full_mask_of_list`, since "category" now means a tag's first level. An ability's own `category` setting keeps its name: it's the ability's main tag, as before.

**Tests:** `tag_registry_selftest` (50 checks), `tag_picker_selftest`, and every suite that uses tags.

## 12. As built: step 2 (Claude, 2026-11-22)

**Where things are:** `assets/scripts/tags/OwnedTags.gd` (a pawn part, `pawn.owned_tags`, in the pawn defaults between StatManager and EffectManager; scene `assets/scenes/pawn/parts/OwnedTags.tscn`) and `TagQuery.gd` (a resource). Usage is in the [tags README](../../assets/scripts/tags/README.md).

**How sources work:** each part that adds tags is a **source**, and `set_source(source, tags)` replaces what that source added before. A rollback or snapshot only has to set a source again from the state it already loads, so nothing is stored twice (section 3):
- an ability: from `AbilityBase.ends_at`'s setter, so only **timed** runs own tags (a Jump, which happens at once, never runs)
- the EffectManager: on every refresh, and at once when `active_effects` is loaded, since a client never counts down the effects of pawns it only draws; once per effect, whatever its stacks
- Death: `status.dead`, under its own source name, since the ability itself is the source of its `ability.death`
- the AI state manager: its state's tag. `AIStateBase.tag`, or `ai.state.<node name in snake case>`; `ai.state.idle`, `ai.state.alert` and `ai.state.combat` are declared

**Loose tags** are one pushed state entry per pawn, `OwnedTags:loose_counts`, a dictionary of counts. The store and snapshots carry dictionaries as they are, so one entry holds every loose tag, rather than one entry per tag.

**What differs from the text above:**
- **Score modifiers and charges** add their tags in steps 3 and 4, when they exist.
- **The `changed` signal** is for the tag itself, not its parents.
- **Queries never add tags:** a tag nobody declared can't be owned, so it fails `all_of` and counts for nothing in `any_of` and `none_of`. `TagRegistry.known_bit_of` (new) looks a bit up without adding it, and `TagRegistry.generation` (new) tells queries and owned tags when to work their bits out again.
- **GDScript only.** Nothing in C++ reads owned tags yet; the batched AI decider will need them as words in step 3.
- **Not measured.** Sources change only when a timed run starts or ends, an effect comes or goes, or the AI's state changes. A 300-pawn measurement waits for step 3, the first user that asks queries every decision.

**Tests:** `owned_tags_selftest` (51 checks); `pawn_initializer_selftest` lists the new part.
