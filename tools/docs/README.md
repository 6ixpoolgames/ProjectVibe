<!-- Written by Claude (claude-opus-5-5), 2026-11-17: how this project's code is documented, and the tools that check and build it. -->

# Writing the docs

The project's goal is a reusable, extensible, efficient, designer-friendly base for several games. The docs serve that: a designer or modder should find what a system does, how to use it and what every setting means without reading its code, and a programmer should find every class and function. *(The owner's calls, 2026-11-17: docs live next to the code; history lives in changelogs, not in code comments; the reference is generated from the comments; a wiki comes later, built from these same files. See `docs/wiki/WIKI_SPEC.md`.)*

Production code is everything under `assets/scripts/` except `tests/`, `debug/` and `samples/` folders, plus the C++ in `native/src/`. These rules are for production code. Tests, samples and tools keep their own comments as they are (dated notes allowed).

## Each system folder

Every folder under `assets/scripts/` (a system: `ai/`, `netcode/`...) has three documents beside its code. `navigation/` is the worked example.

| File | Written by | What it holds |
|---|---|---|
| `README.md` | hand | What the system is, its pieces and how they connect, how to use it (designer recipes first), the settings worth knowing, its tests |
| `REFERENCE.md` | `python tools/docs/make_reference.py <system>` | Every class, setting, signal, constant and function, from the `##` comments. Never edited by hand |
| `CHANGELOG.md` | hand | Refactor candidates first, then what changed and why, newest first, by date |

`native/` has a `README.md` and a `CHANGELOG.md` the same way; its reference is the comments in the headers (Godot's doc tool doesn't read C++).

### README.md layout

1. `# <System name>` and one or two sentences: what it does for a game. Then a status line: `**Status:** built | partly built | planned, tier 0. <one sentence on what isn't built yet>` (the wiki lists systems by it).
2. A table of the three documents, plus the design spec in `docs/` if there is one.
3. **The pieces**: each main class in a line or two, and how they connect (a small text diagram where it helps). Name the classes in other folders it works with.
4. **How to use it**: short recipes, designer-first ("Add a wall", "Send a pawn somewhere"), each a few sentences and at most a few lines of code.
5. **Settings worth knowing**: a table of the settings a designer is most likely to touch (setting, where, default, what it does). Not every setting: the reference has those.
6. **Tests**: the test scenes and what each covers.

Keep it short enough to read in five minutes. Plain language; the [writing rules](#plain-language) below apply.

### CHANGELOG.md layout

```markdown
<!-- one-line note: what this file is -->
# <System> changelog

<one paragraph: what the system covers, links to README.md and the spec>

## Refactor candidates

| What | Where | Why | Size |
|---|---|---|---|

## <YYYY-MM-DD>

- **Short title.** What changed and why, in a sentence or three.
```

Entries come from the dated notes taken out of the code and from `git log -- <folder>`. Group a day's notes into a few entries rather than one per note. Sizes: S an hour or two, M a day, L more.

## Comments in code

The wiki is the documentation: each system's README is its guide page, and its `##` comments are its reference page. So comments are written to be read as reference, short and plain. `tools/docs/check_comment_style.py` measures every GDScript file under `assets/scripts/` against this section (C++ comments are checked by review).

**The header.** A plain `#` line first, so it stays out of the reference:
```gdscript
# Written by Claude (claude-opus-5-5), 2026-11-08. History: navigation/CHANGELOG.md.
## The pawn's only contact with navigation: finds paths and says which way to walk.
##
## One short paragraph on what it's for and how to use it.
class_name NavigationManager
```
Keep the original date of a file's header. A file someone else wrote keeps its author.

**Class `##` comment** (at most about 12 lines):
- A one-line summary: what it is.
- One short paragraph: what it's for, how it's used, what it works with.
- Optionally a small `[codeblock]` example (2 to 5 lines) and one `Design: <spec> <section>.` line.
- Not here: history, who decided what, long lists of odd cases (the tests hold those), or how it works inside (the README, or `#` comments at the spot).

**Member, signal, constant and function `##` comments:** one line, two at most. Say what it is or does, its unit (ticks at 60 a second, metres), and what a special value means (-1: none). Not how it's done.

**Plain `#` comments** say a non-obvious why, one line each, at the spot. Not what the next line does, not language lessons (no `GDScript note:`), not history.

**Always keep** (shortened, never dropped), because the code can't show it:
- **Twin parity:** where C++ and GDScript must give the same answer (the AI decider, packet encoding, state recording, fade maths, the random hash), say so and name the other copy.
- **Determinism and order:** pawn-id order, "after every pawn has simulated", "must run before X".
- **Threads:** what a worker job reads, and what may not change while it runs.
- **Rollback and network:** what is recorded, replayed or sent, and what must not be.
- **Units and conversions:** ticks at 60 a second converted with `TickDriver.ticks_at_rate`, flat distances, real_t versus double.
- **Gotchas:** a freed node in a typed variable, a packed array copied on assignment, anything that cost a debugging session.
- `# REFACTOR:` tags and spec references.

**Where the rest goes.** How a system works and how to use it, at length: its README. History, who decided, what it replaced: its CHANGELOG. Odd cases: the tests.

**Godot markup** (Godot joins a `##` block into one paragraph, so structure is written in markup): `## [br]` between paragraphs; `## [br]- ` before each list item, with continuation lines indented two spaces; `[codeblock]` ... `[/codeblock]`; `[ClassName]`, `[method x]`, `[member x]`, `[signal x]`, `[constant x]` for links; `[code]x[/code]` for code in a sentence; `[b]bold[/b]` sparingly.

**Example** (`ai/AIInputs.gd`, after the 2026-11-18 pass):
```gdscript
## One pawn's AI inputs: the named numbers its behaviours' conditions read.
##
## Every name has a slot, the same for every pawn, so a crowd's inputs line up as one table the C++ decider reads. The built-in inputs
## (the constants below) are worked out the first time a condition reads them in a decision; any other name is a game's own, kept
## until written again ([method set_input]). Names starting [code]ticks_[/code] are times in ticks, written for 60 a second.
## Design: scaling spec 6.2.
class_name AIInputs

## Flat distance to where the AI last knew its target to be; [constant FAR] with no target.
const TARGET_DISTANCE := &"target_distance"

## The group's nearest node (null if none), kept for 2 seconds while it exists. Go To Point walks to it.
func nearest_in_group(group: StringName, tick: int) -> Node3D:
	# A freed node can't go in a typed variable, so it's checked as a Variant first.
```

**Dated notes** (`Claude 2026-11-09: ...`) don't belong in production code. Keep any part that explains the code as it is now, rewritten in the present tense; the history goes to the changelog. Tests, samples and tools may keep theirs.

**Wrong or stale comments** are fixed to match the code, never the other way round, and noted in the changelog.

**`# REFACTOR:`** marks code that works but misses a goal: duplicated logic, a game rule hard-coded in the base, a debug tool in a production folder, a misleading name, a special case on shared code, needless work in a hot path, something a designer can't set without code. One or two lines at the spot, and a row in the changelog's table. Don't refactor in a docs pass.

**A comment pass, step by step:** rewrite one system's comments to this section; run `check_comments_only.py` on its files (it must report no code changes); run `check_comment_style.py <system>`; move anything long that's worth keeping into the README; add one changelog line ("Comments rewritten to the reference style"); then `make_reference.py <system>` (runs Godot, so one at a time) and the system's tests.

## Checking and building

- `python tools/docs/check_comments_only.py [files]`: proves only comments changed, against the last commit (GDScript and C++). Every docs change must pass it.
- `python tools/docs/check_comment_style.py [systems]`: measures comments against the section above (class and member comment lengths, `GDScript note:`, dated notes and decision history in production code), per system. `--strict` exits 1 on any find. No Godot needed.
- `python tools/docs/make_reference.py [systems]`: runs Godot's doc tool (the editor binary beside the project, or `GODOT`) and writes each `REFERENCE.md`. Run it after changing doc comments. It runs Godot, so never alongside another Godot run.
- `python tools/docs/make_class_index.py`: writes `docs/CLASS_INDEX.md`, every class A to Z with its one-line summary. No Godot needed.
- `python tools/docs/check_links.py`: checks every relative link and #anchor in the docs. Run it after moving or renaming anything.
- `python tools/docs/check_refactor_tags.py`: checks that every `REFACTOR:` tag in the code has a row in a changelog's refactor table, and every row a tag (a tag names its row's changelog when it isn't its own system's; a row about scenes or a folder layout says "no tag"). Run it before a commit that adds, moves or closes one. Exits 1 on a find.
- `python tools/docs/check_privacy.py [folder]`: the repository and the wiki are public, so nothing private may go in: no local directories (write paths relative to the project), no keys, codes or passwords, no email addresses, no real network addresses (use 192.0.2.x in examples). It also looks for this machine's user name and git email without storing them. Run it before every commit and push; the wiki build runs it before and after building, and stops on a find. Machine-specific notes for Claude go in `CLAUDE.local.md`, which git ignores.
- `python tools/docs/build_wiki.py`: builds the wiki into `build/wiki/site/` (MkDocs Material: `python -m pip install mkdocs-material`). With `--serve` it serves it at http://127.0.0.1:8765 and keeps it up to date while you edit: a new system folder with a README joins by itself. `--references` runs `make_reference.py` first.
- Tests: comments can't change behaviour, but a broken `##` block can stop a script parsing. Run the system's tests after a pass.

## Plain language

Short sentences, everyday words, the standard term, no clever phrasing. Say what a thing does, not what it's like.
