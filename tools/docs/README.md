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

**The header.** A plain `#` line first, so it stays out of the reference:
```gdscript
# Written by Claude (claude-opus-5-5), 2026-11-08. History: navigation/CHANGELOG.md.
## The pawn's only contact with navigation: finds paths and says which way to walk.
##
## The longer description...
class_name NavigationManager
```
Keep the original date of a file's header. A file someone else wrote keeps its author.

**Doc comments (`##`)** sit right above the class, a member, a signal, a constant or a function, and are what the editor's help and `REFERENCE.md` show. Godot joins their lines into one paragraph, blank `##` lines too, so structure is written in its markup:
- The first paragraph, up to the first blank `##` line, is the brief: one line saying what the thing is.
- `## [br]` on its own line between paragraphs.
- `## [br]- ` starts each item of a list; an item's next lines are indented two spaces (`##   more`).
- `[codeblock]` ... `[/codeblock]` for usage examples, each line as `## code`.
- `[ClassName]` links to a class; `[method name]`, `[member name]`, `[signal name]` name things in the same class. `[code]x[/code]` for code in a sentence, `[b]bold[/b]` sparingly.

**Plain `#` comments** explain the how and why inside code, for whoever reads the code. Keep `GDScript note:` comments: the owner is relearning GDScript and asked for them.

**What leaves the code.** Dated notes (`Claude 2026-11-09: ...`, `# Claude 2026-11-16 (pawn spec 8.21): was 1`) go. For each one:
- If it explains what the code does now or why, keep that part, rewritten in the present tense without the date. "Claude 2026-11-16: was 1" just goes; "Claude 2026-11-16: a distant pawn runs every 2nd or 4th tick, so this counts ticks_elapsed" keeps its second half.
- The history (what it was before, when it changed, which step or audit) goes into the changelog.
- "Was X", "now Y", "replaces Z", "moved from" are history.
- References to spec sections stay ("pawn spec section 7"); they say where the design is.

**Wrong or stale comments** are fixed to match the code, never the other way round, and noted in the changelog's entry for the pass.

**`# REFACTOR:`** marks code that works but doesn't fit the project's goals: duplicated logic, a game rule hard-coded in the base, a debug tool in a production folder, a class in the wrong folder or with a misleading name, a special case layered on shared code, a hot path that does needless work, something a designer can't set without code. One line or two at the spot, saying what and which goal it misses, and a row in the changelog's table. Don't refactor in a docs pass.

## Checking and building

- `python tools/docs/check_comments_only.py [files]`: proves only comments changed, against the last commit (GDScript and C++). Every docs change must pass it.
- `python tools/docs/make_reference.py [systems]`: runs Godot's doc tool (the editor binary beside the project, or `GODOT`) and writes each `REFERENCE.md`. Run it after changing doc comments. It runs Godot, so never alongside another Godot run.
- `python tools/docs/make_class_index.py`: writes `docs/CLASS_INDEX.md`, every class A to Z with its one-line summary. No Godot needed.
- `python tools/docs/check_links.py`: checks every relative link and #anchor in the docs. Run it after moving or renaming anything.
- `python tools/docs/check_privacy.py [folder]`: the repository and the wiki are public, so nothing private may go in: no local directories (write paths relative to the project), no keys, codes or passwords, no email addresses, no real network addresses (use 192.0.2.x in examples). It also looks for this machine's user name and git email without storing them. Run it before every commit and push; the wiki build runs it before and after building, and stops on a find. Machine-specific notes for Claude go in `CLAUDE.local.md`, which git ignores.
- `python tools/docs/build_wiki.py`: builds the wiki into `build/wiki/site/` (MkDocs Material: `python -m pip install mkdocs-material`). With `--serve` it serves it at http://127.0.0.1:8765 and keeps it up to date while you edit: a new system folder with a README joins by itself. `--references` runs `make_reference.py` first.
- Tests: comments can't change behaviour, but a broken `##` block can stop a script parsing. Run the system's tests after a pass.

## Plain language

The docs follow the owner's writing rules: short sentences, everyday words, the standard term with a short explanation, and no clever phrasing. Say what a thing does, not what it's like.
