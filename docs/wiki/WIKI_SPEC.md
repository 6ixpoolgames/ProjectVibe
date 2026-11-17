<!-- Written by Claude (claude-opus-5-5), 2026-11-17: a first draft of the wiki's design, for the owner to review. Nothing here is built
except what section 6 marks as built. -->

# Wiki spec (draft)

**Status:** draft for discussion. The owner's direction (2026-11-17): a wiki once the code is more mature, maybe after tier 1, specified now alongside the documentation pass "so we can build functionality each wants from the other".

## 1. What it's for

One place to browse the whole base: what each system does, how to use it, every class and function, why things are the way they are, and what's planned. For three readers:

| Reader | Comes for | Starts at |
|---|---|---|
| Designer | How to build a level, a pawn, an ability, an AI, without reading code | Guides, then each system's "How to use it" |
| Modder or programmer | Classes, functions, signals, extension points | The class index and the references |
| The owner | How the pieces fit, what changed, what needs work | The overview, recent changes, the refactor board |

**The rule that shapes everything:** the wiki is *built from* the files next to the code (README, REFERENCE, CHANGELOG) and the specs in `docs/`. Nothing is written twice. Editing the wiki means editing those files.

## 2. Pages

```
Home                     what the base is, who it's for, where to start
Getting started          how a game is put together: GameMode modules, pawn parts, the tick, a first level
Guides                   designer recipes gathered from every README's "How to use it"
Systems                  one section per system folder
  <system>               its README.md
    Reference            its REFERENCE.md
    Changelog            its CHANGELOG.md
Class index              every class A to Z: system, what it extends, its one-line summary
Specs                    the design documents in docs/
Roadmap                  docs/ROADMAP.md
Refactor board           every changelog's refactor candidates in one table, sortable by system and size
Recent changes           every changelog's entries merged by date, newest first
Glossary                 the standard terms the docs use (tick, rollback, nav tier, off-mesh link...), one line each
```

The class index, refactor board and recent changes are generated; the rest come from existing files, plus a hand-written Home, Getting started and Glossary.

## 3. What the wiki needs from the docs

These go into the documentation pass now, so the wiki costs little later. Each is in `tools/docs/README.md` or the generator.

| Need | Why | Status |
|---|---|---|
| The same README layout in every system | Pages look alike, and Guides can gather each "How to use it" section by its heading | In the guide; the rollout follows it |
| A one-line summary first in every class's doc comment | The class index and search results show it | In the guide |
| Links between classes across systems | A reference page links to the classes it mentions, wherever they live | Built: `[ClassName]` becomes a link (engine classes link to Godot's docs) |
| Relative links only, no absolute paths | The same files work on GitHub, in the editor and in the wiki | In the guide |
| The changelog's refactor table in one fixed shape | The refactor board is built by reading every table | In the guide |
| Dated headings (`## YYYY-MM-DD`) in every changelog | Recent changes merges them by date | In the guide |
| A status line per system (built, partial, planned; which tier) | The Systems list shows what's ready to use | In the guide; added during the rollout |
| Images beside the docs that use them (`<system>/images/`) | Pages keep their pictures when built | Not yet: no images so far |

## 4. What the docs want from the wiki

Things the wiki's build can do for the docs, so the plain files don't have to:

- **Search** across everything.
- **A link checker:** every relative link and class link resolves, run with the build, so docs can't quietly point at something renamed.
- **The class index, refactor board and recent changes**, generated (section 2).
- **Diagrams** (Mermaid) in place of the text diagrams in the READMEs, where a picture is clearer.
- **"Planned" marking:** specs describe features that aren't built; the wiki can show which sections are built from the status lines.

## 5. How it's built

A static site, built by one command, from the files where they are:

```
python tools/docs/build_wiki.py
  1. make_reference.py for every system        (REFERENCE.md files)
  2. gather README / REFERENCE / CHANGELOG and docs/ into a build folder, in the page order above
  3. generate the class index, refactor board and recent changes
  4. check every link
  5. build the site into build/wiki/ (not committed)
```

**Tool: MkDocs with the Material theme** (recommended). It's the common choice for Markdown docs:
- It reads Markdown as written, with search, navigation, dark mode and Mermaid.
- It's Python, which the project already needs for its build (SCons).
- The output is plain HTML, which opens from a folder or can be hosted anywhere.

The alternatives, and why not:

| Option | Against it |
|---|---|
| GitHub's wiki | A separate repository, filled by hand or a sync script. No build step for the generated pages, and no link checking |
| Godot's in-editor help | Already works for the reference (the `##` comments show there), but it has no guides, specs or changelogs |
| Hand-written HTML | Everything the tools above give for free would be ours to maintain |

**Hosting** is the owner's call (section 8). The build is the same either way.

*(Built 2026-11-17, the owner: "make it pretty too. Functional and readable", and automate the updates since it's cheap.)* `tools/docs/build_wiki.py` writes `build/wiki/mkdocs.yml`; MkDocs runs `tools/docs/wiki_hook.py` before every build, which gathers the pages and sets the menu, and `--serve` watches `assets/scripts/`, `docs/`, `native/` and `tools/docs/`. So while it serves, an edited README or changelog, or a new system folder with a README, shows within a few seconds, with nothing run by hand; a system's reference refreshes when `make_reference.py` runs (it needs Godot). Every file is written only when its content changed, so a build never sets off another forever. Checked by adding and deleting a throwaway system folder while it served.

**Note:** Material for MkDocs reaches end of life on 5 May 2027 (its own notice). Its successor, Zensical, is by the same team and reads the same `mkdocs.yml`, so moving is expected to be small. Revisit before then.

## 6. Phases

| Phase | When | What |
|---|---|---|
| W0 | Now, with the documentation pass | The docs follow section 3. **Built:** cross-class links in the references, a link checker (`tools/docs/check_links.py`) and the class index as plain Markdown (`docs/CLASS_INDEX.md`, `tools/docs/make_class_index.py`), useful on GitHub before any wiki exists |
| W1 | After tier 1, when the code is more mature | `build_wiki.py` and MkDocs; Home, Getting started and the Glossary written; the refactor board and recent changes generated |
| W2 | Later | Guides with screenshots and short clips; pages per tier (what tier 1 offers against tier 2); hosting, if wanted |

## 7. Risks

- **Docs drift from code.** The references can't drift, since they're generated. READMEs and specs can. The changelog rule (every change adds an entry) and the link checker catch most of it; a "last checked" date per README would catch the rest.
- **Specs describing unbuilt features** read as if they exist. Status lines and "planned" marking (section 4) answer this.
- **Too much at once.** W0 stays small: only what the documentation pass already needs.

## 8. Open questions for the owner

1. **Who reads it?** Only you, a small team, or public modders? That decides hosting: a local build folder, a private host, or GitHub Pages.
2. **MkDocs Material**, or something else you've used and liked?
3. **Specs next to code?** The long specs (`docs/navigation/NAV_SPEC.md`...) stay in `docs/` for now and are linked from each README. Moving them into their system folders would put everything for a system in one place. The wiki doesn't care either way.
4. **Versions per tier:** one wiki that always shows the latest, or a copy kept for each tier?
