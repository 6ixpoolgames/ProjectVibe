# Written by Claude (claude-opus-5-5), 2026-11-17: builds the project's wiki (docs/wiki/WIKI_SPEC.md) from the files next to the code.
# Nothing is written twice: each system's README, REFERENCE and CHANGELOG, the specs in docs/ and the roadmap are copied in as they
# are, their links rewritten to work in the site, and a few pages are generated from them: the systems list, the class index, the
# refactor board and recent changes. The hand-written pages (home, getting started, glossary) live in docs/wiki/pages/.
#
# Run from the project folder:
#   python tools/docs/build_wiki.py              builds the site into build/wiki/site/ (open index.html there)
#   python tools/docs/build_wiki.py --serve      serves it at http://127.0.0.1:8765 and keeps it up to date while you edit
#   python tools/docs/build_wiki.py --references first runs make_reference.py for every system (that runs Godot)
# MkDocs and its Material theme: python -m pip install mkdocs-material. build/ isn't committed.
#
# Staying up to date: MkDocs runs gather() before every build, through tools/docs/wiki_hook.py, and the server watches
# assets/scripts/, docs/, native/ and tools/docs/. So while it serves, an edited README, changelog or spec, or a new system folder
# with a README, shows in the browser within a second or two. A system's REFERENCE.md changes only when make_reference.py runs.
# Every file is written only when its content changed: the server watches docs/ too, and rewriting an unchanged file there would
# start another build, forever.
import os
import re
import subprocess
import sys

PROJECT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
SCRIPTS = os.path.join(PROJECT, "assets", "scripts")
DOCS = os.path.join(PROJECT, "docs")
PAGES = os.path.join(DOCS, "wiki", "pages")
BUILD = os.path.join(PROJECT, "build", "wiki")
SOURCE = os.path.join(BUILD, "docs") # MkDocs' input folder
NOT_PRODUCTION = {"tests", "debug", "samples"}
# The design specs, in the order they're listed, with a title each. docs/legacy is the old code's and stays out.
SPECS = [
    ("pawn/PAWN_SPEC.md", "Pawn"), ("pawn/REDESIGN_LOG.md", "Pawn redesign log"), ("pawn/PLAYER_AND_CAMERA.md", "Player and camera"),
    ("navigation/NAV_SPEC.md", "Navigation"),
    ("netcode/NETCODE_SPEC.md", "Netcode"), ("scaling/SCALING_SPEC.md", "Scaling"), ("streaming/STREAMING_SPEC.md", "Streaming"),
    ("world/WORLD_SPEC.md", "World"), ("replay/REPLAY_SPEC.md", "Replay"), ("diagnostics/DIAGNOSTICS_SPEC.md", "Diagnostics"),
    ("TEST_AND_DEBUG_CODE.md", "Test and debug code"), ("wiki/WIKI_SPEC.md", "Wiki"),
    ("state_store/STATE_STORE_SPEC.md", "State store"), ("abilities/ABILITY_SPEC.md", "Abilities"), ("tags/TAG_SPEC.md", "Tags"),
    ("tags/TAGS.md", "Tag list"), ("ARCHITECTURE.md", "Architecture"),
]
LINK = re.compile(r"(!?\[[^\]]*\])\(([^)\s]+)\)")

# Source file (absolute) -> its page in the site (relative to SOURCE). Filled while gathering, then used to rewrite links.
page_of = {}
# The pages written by this gather, so pages whose source went away are removed.
written = set()
# The folders the server watches for changes.
WATCHED = [SCRIPTS, DOCS, os.path.join(PROJECT, "native"), os.path.dirname(os.path.abspath(__file__))]


def main() -> int:
    if "--references" in sys.argv:
        subprocess.run([sys.executable, os.path.join(PROJECT, "tools", "docs", "make_reference.py")], check=True)
    # The wiki is public: nothing private may go into it (tools/docs/check_privacy.py). Checked before building, and the finished
    # site after, search index included; a find stops the build.
    if not privacy_ok(None):
        return 1
    write_config()
    result = build_site()
    if result == 0 and "--serve" not in sys.argv and os.path.isdir(os.path.join(BUILD, "site")) and not privacy_ok("build/wiki/site"):
        return 1
    return result


def privacy_ok(folder) -> bool:
    command = [sys.executable, os.path.join(PROJECT, "tools", "docs", "check_privacy.py")] + ([folder] if folder else [])
    result = subprocess.run(command, cwd=PROJECT, capture_output=True, text=True)
    if result.returncode != 0:
        print(result.stdout)
        print("Stopped: something private would be published (above). Fix it, then build again.")
        return False
    return True


## Gathers every page into build/wiki/docs/ and returns the site's menu. MkDocs calls it before each build (wiki_hook.py).
def gather() -> list:
    page_of.clear()
    written.clear()
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    import make_class_index # the class index tool, beside this one
    make_class_index.main(quiet=True)
    os.makedirs(SOURCE, exist_ok=True)
    systems = gather_systems()
    plan_pages(systems)
    for source, page in page_of.items():
        copy_page(source, page)
    write_systems_page(systems)
    write_refactor_board(systems)
    write_recent_changes(systems)
    with open(os.path.join(DOCS, "wiki", "theme", "extra.css"), encoding="utf-8") as css:
        write("stylesheets/extra.css", css.read())
    remove_stale_pages()
    return menu(systems)


def remove_stale_pages() -> None:
    for folder, _subfolders, files in os.walk(SOURCE):
        for name in files:
            page = os.path.relpath(os.path.join(folder, name), SOURCE).replace(os.sep, "/")
            if page not in written:
                os.remove(os.path.join(folder, name))
    # Then the folders left empty, deepest first (a system whose folder went away).
    for folder, _subfolders, _files in sorted(os.walk(SOURCE), key=lambda entry: -len(entry[0])):
        if folder != SOURCE and not os.listdir(folder):
            os.rmdir(folder)


# Every system folder with at least a README: (name, folder, status line).
def gather_systems() -> list:
    systems = []
    for name in sorted(os.listdir(SCRIPTS)):
        folder = os.path.join(SCRIPTS, name)
        readme = os.path.join(folder, "README.md")
        if name in NOT_PRODUCTION or not os.path.isfile(readme):
            continue
        with open(readme, encoding="utf-8") as text:
            status = re.search(r"^\*\*Status:\*\*\s*(.+)$", text.read(), re.MULTILINE)
        systems.append((name, folder, status.group(1).strip() if status else "not stated"))
    native = os.path.join(PROJECT, "native")
    if os.path.isfile(os.path.join(native, "README.md")):
        systems.append(("native", native, "the C++ library"))
    return systems


def plan_pages(systems: list) -> None:
    for file_name, page in (("index.md", "index.md"), ("getting-started.md", "getting-started.md"), ("glossary.md", "glossary.md")):
        if os.path.isfile(os.path.join(PAGES, file_name)):
            page_of[os.path.join(PAGES, file_name)] = page
    for name, folder, _status in systems:
        for file_name, page in (("README.md", "index.md"), ("REFERENCE.md", "reference.md"), ("CHANGELOG.md", "changelog.md")):
            if os.path.isfile(os.path.join(folder, file_name)):
                page_of[os.path.join(folder, file_name)] = "systems/%s/%s" % (name, page)
    for path, _title in SPECS:
        if os.path.isfile(os.path.join(DOCS, path)):
            page_of[os.path.join(DOCS, path)] = "specs/" + os.path.basename(path).lower().replace("_", "-")
    page_of[os.path.join(DOCS, "ROADMAP.md")] = "roadmap.md"
    page_of[os.path.join(DOCS, "CLASS_INDEX.md")] = "class-index.md"
    page_of[os.path.join(PROJECT, "tools", "docs", "README.md")] = "writing-docs.md"


def copy_page(source: str, page: str) -> None:
    with open(source, encoding="utf-8") as text:
        content = text.read()
    # The wiki's own pages are written with their links as paths in the site; everything else links by repository paths.
    if not source.startswith(PAGES):
        content = rewrite_links(content, source, page)
    write(page, content)


# A relative link pointed at a file in the repository. In the site it points at that file's page, or, for something that has no page
# (a script, a scene), becomes plain text naming it.
def rewrite_links(content: str, source: str, page: str) -> str:
    def fix(match):
        label, target = match.group(1), match.group(2)
        if re.match(r"^[a-z]+:", target) or target.startswith("#"):
            return match.group(0)
        file_part, _, anchor = target.partition("#")
        destination = os.path.normpath(os.path.join(os.path.dirname(source), file_part))
        if destination in page_of:
            relative = os.path.relpath(page_of[destination], os.path.dirname(page) or ".").replace(os.sep, "/")
            return "%s(%s%s)" % (label, relative, "#" + anchor if anchor else "")
        shown = os.path.relpath(destination, PROJECT).replace(os.sep, "/")
        return "%s (`%s`)" % (label.strip("[]") if not label.startswith("!") else label, shown)
    return LINK.sub(fix, content)


# An icon per system for its card (Material Design icons, https://pictogrammers.com/library/mdi/). A new system gets the default.
ICONS = {
    "abilities": "sword-cross", "ai": "brain", "camera": "camera-outline", "controllers": "gamepad-variant-outline",
    "diagnostics": "chart-timeline-variant", "effects": "auto-fix", "game_mode": "chess-king", "jobs": "cogs",
    "movement": "run-fast", "native": "language-cpp", "navigation": "map-marker-path", "netcode": "lan", "pawn": "account-outline",
    "platform": "laptop", "player": "account-cog-outline", "replay": "replay", "resources": "file-cog-outline",
    "singletons": "cog-outline", "spawning": "account-plus-outline", "stats": "chart-bar", "streaming": "transfer",
    "tags": "tag-multiple-outline", "terrain": "terrain", "ui": "monitor-dashboard", "visuals": "palette-outline",
    "world": "earth",
}


def write_systems_page(systems: list) -> None:
    lines = ["---", "hide:", "  - toc", "---", "", "# Systems", "",
             "Every system in the base, with how far it's built. Each has an overview, a reference of every class and function, "
             "and a changelog.", "", '<div class="grid cards" markdown>', ""]
    for name, folder, status in systems:
        lines += [
            "-   :material-%s:{ .lg .middle } **[%s](systems/%s/index.md)** %s" % (ICONS.get(name, "puzzle-outline"), title_of(name), name,
                                                                                status_badge(status)),
            "", "    ---", "", "    " + summary_of(folder), "",
        ]
        links = []
        if has_page(name, "reference.md"):
            links.append("[:octicons-book-16: Reference](systems/%s/reference.md)" % name)
        if has_page(name, "changelog.md"):
            links.append("[:octicons-history-16: Changelog](systems/%s/changelog.md)" % name)
        if links:
            lines += ["    " + " · ".join(links), ""]
    lines.append("</div>")
    write("systems.md", "\n".join(lines) + "\n")


def has_page(system: str, page: str) -> bool:
    return "systems/%s/%s" % (system, page) in page_of.values()


def title_of(name: str) -> str:
    return {"ai": "AI", "ui": "UI", "native": "Native (C++)"}.get(name, name.replace("_", " ").capitalize())


# A README's status line ("built, tier 0. Not yet: ...") as a coloured badge, with the rest as a small note.
def status_badge(status: str) -> str:
    head = status.split(",")[0].split(".")[0].strip().lower()
    kind = "built" if head.startswith("built") else "partly" if head.startswith("partly") else "planned" if head.startswith("planned") else ""
    return '<span class="pb-status %s">%s</span>' % (kind, head or "status?")


# The README's first paragraph after its title, without the status line: what the system does, in a sentence or two.
def summary_of(folder: str) -> str:
    with open(os.path.join(folder, "README.md"), encoding="utf-8") as text:
        content = re.sub(r"<!--.*?-->", "", text.read(), flags=re.DOTALL)
    for paragraph in re.split(r"\n\s*\n", content):
        paragraph = paragraph.strip()
        if paragraph and not paragraph.startswith(("#", "**Status", "|", "```", "-")):
            text = " ".join(paragraph.split())
            return re.sub(r"\[([^\]]*)\]\([^)]*\)", r"\1", text) # links inside a card would nest
    return ""


# Every changelog's refactor table, with a column saying which system each row is from.
def write_refactor_board(systems: list) -> None:
    rows = []
    for name, folder, _status in systems:
        section = changelog_section(folder, "Refactor candidates")
        for line in section.split("\n"):
            if line.startswith("|") and not re.match(r"^\|\s*(What|-+)\s*\|", line):
                rows.append("| [%s](systems/%s/changelog.md) %s" % (name, name, line))
    lines = ["# Refactor board", "", "Code that works but doesn't yet fit the project's goals (reusable, extensible, efficient, designer "
             "friendly), gathered from every system's changelog. Each is marked `REFACTOR:` in the code. Sizes: S an hour or two, M a "
             "day, L more. %d in all." % len(rows), "", "| System | What | Where | Why | Size |", "|---|---|---|---|---|"]
    write("refactor-board.md", "\n".join(lines + rows) + "\n")


# Every changelog's dated entries merged by date, newest first.
def write_recent_changes(systems: list) -> None:
    by_date = {}
    for name, folder, _status in systems:
        path = os.path.join(folder, "CHANGELOG.md")
        if not os.path.isfile(path):
            continue
        with open(path, encoding="utf-8") as text:
            content = text.read()
        for match in re.finditer(r"^## (\d{4}-\d{2}-\d{2}[^\n]*)\n(.*?)(?=^## |\Z)", content, re.MULTILINE | re.DOTALL):
            body = rewrite_links(match.group(2).strip(), path, "recent-changes.md")
            by_date.setdefault(match.group(1).strip(), []).append((name, body))
    lines = ["# Recent changes", "", "What changed across the base, newest first, from every system's changelog."]
    for date in sorted(by_date, reverse=True):
        lines += ["", "## " + date]
        for name, body in by_date[date]:
            lines += ["", "### [%s](systems/%s/changelog.md)" % (name, name), "", body]
    write("recent-changes.md", "\n".join(lines) + "\n")


def changelog_section(folder: str, heading: str) -> str:
    path = os.path.join(folder, "CHANGELOG.md")
    if not os.path.isfile(path):
        return ""
    with open(path, encoding="utf-8") as text:
        match = re.search(r"^## %s\s*\n(.*?)(?=^## |\Z)" % re.escape(heading), text.read(), re.MULTILINE | re.DOTALL)
    return match.group(1) if match else ""


# The site's menu, as MkDocs takes it: a list of {title: page} and {title: [ ... ]}. Only pages that exist are listed.
def menu(systems: list) -> list:
    system_entries = ["systems.md"]
    for name, _folder, _status in systems:
        pages = [{"Overview": "systems/%s/index.md" % name}]
        for page, label in (("reference.md", "Reference"), ("changelog.md", "Changelog")):
            if has_page(name, page):
                pages.append({label: "systems/%s/%s" % (name, page)})
        system_entries.append({title_of(name): pages})
    specs = [{title: page_of[os.path.join(DOCS, path)]} for path, title in SPECS if os.path.join(DOCS, path) in page_of]
    return [
        {"Home": "index.md"}, {"Getting started": "getting-started.md"}, {"Systems": system_entries},
        {"Class index": "class-index.md"}, {"Specs": specs}, {"Refactor board": "refactor-board.md"},
        {"Recent changes": "recent-changes.md"}, {"Roadmap": "roadmap.md"}, {"Glossary": "glossary.md"},
        {"Writing the docs": "writing-docs.md"},
    ]


# build/wiki/mkdocs.yml. The menu isn't in it: the hook (wiki_hook.py) gathers the pages and sets the menu before every build.
def write_config() -> None:
    os.makedirs(BUILD, exist_ok=True)
    # Claude 2026-11-17: the pages' folder too. MkDocs checks docs_dir exists before its on_config hook gathers the pages into it, so
    # on a fresh checkout (GitHub's build) it stopped with "isn't an existing directory"; locally the folder was left from earlier builds.
    os.makedirs(SOURCE, exist_ok=True)
    # Godot scans every folder under the project; this keeps it out of the build.
    open(os.path.join(PROJECT, "build", ".gdignore"), "a").close()
    def quoted(path):
        return '"%s"' % path.replace(os.sep, "/")
    config = """site_name: Project Base
site_description: A reusable base for real-time 3D games in Godot
docs_dir: docs
site_dir: site
use_directory_urls: false
extra_css: [stylesheets/extra.css]
hooks: [%s]
watch: [%s]
theme:
  name: material
  icon: {logo: material/cube-outline}
  font: {text: Inter, code: JetBrains Mono}
  features:
    - navigation.tabs
    - navigation.sections
    - navigation.indexes
    - navigation.top
    - navigation.footer
    - navigation.instant
    - search.highlight
    - search.suggest
    - content.code.copy
    - toc.follow
  palette:
    - media: "(prefers-color-scheme: light)"
      scheme: default
      toggle: {icon: material/weather-night, name: Dark mode}
    - media: "(prefers-color-scheme: dark)"
      scheme: slate
      toggle: {icon: material/weather-sunny, name: Light mode}
markdown_extensions:
  - tables
  - admonition
  - attr_list
  - md_in_html
  - pymdownx.details
  - toc: {permalink: true}
  - pymdownx.highlight: {anchor_linenums: true}
  - pymdownx.inlinehilite
  - pymdownx.emoji:
      emoji_index: !!python/name:material.extensions.emoji.twemoji
      emoji_generator: !!python/name:material.extensions.emoji.to_svg
  - pymdownx.superfences:
      custom_fences:
        - name: mermaid
          class: mermaid
          format: !!python/name:pymdownx.superfences.fence_code_format
validation:
  links: {not_found: warn, anchors: warn}
""" % (quoted(os.path.join(os.path.dirname(os.path.abspath(__file__)), "wiki_hook.py")), ", ".join(quoted(path) for path in WATCHED))
    with open(os.path.join(BUILD, "mkdocs.yml"), "w", encoding="utf-8", newline=chr(10)) as out:
        out.write(config)


def build_site() -> int:
    try:
        import mkdocs # noqa: F401  (only to see whether it's installed)
    except ImportError:
        gather()
        print("MkDocs isn't installed, so only the pages were gathered into build/wiki/docs/. To build the site: "
              "python -m pip install mkdocs-material")
        return 0
    command = [sys.executable, "-m", "mkdocs", "build", "-f", os.path.join(BUILD, "mkdocs.yml")]
    if "--serve" in sys.argv:
        command = [sys.executable, "-m", "mkdocs", "serve", "-a", "127.0.0.1:8765", "-f", os.path.join(BUILD, "mkdocs.yml")]
    return subprocess.run(command).returncode


# Writes a page into the site's source folder, but only if its content changed (see the top of the file).
def write(page: str, content: str) -> None:
    written.add(page)
    path = os.path.join(SOURCE, page)
    if os.path.isfile(path):
        with open(path, encoding="utf-8") as old:
            if old.read() == content:
                return
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8", newline=chr(10)) as out:
        out.write(content)


if __name__ == "__main__":
    sys.exit(main())
