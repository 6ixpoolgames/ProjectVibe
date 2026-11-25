# Written by Claude (claude-opus-5-5), 2026-11-25: checks that every REFACTOR: tag in the code has a row in a changelog's refactor
# table, and that every row still has a tag (CLAUDE.md rule 9: code that works but misses a goal gets a tag and a row, kept together).
#
# Run from the project folder:
#   python tools/docs/check_refactor_tags.py          every system, and native/
#   python tools/docs/check_refactor_tags.py -v       also lists each tag with the row it matched
# Exits 0 when every tag has a row and every row a tag, 1 otherwise, listing each find.
#
# How they're paired. A tag is a comment starting "REFACTOR:" in the base's code (assets/scripts/ outside tests/ and samples/, so
# debug/ tools count; and native/src/), plus the comment lines that follow it. Its changelog is the one the comment names ("ai/CHANGELOG.md",
# "native/CHANGELOG.md"), or else its own system's (native/CHANGELOG.md for C++). A row is a line of the table under a changelog's
# "## Refactor candidates" heading. A tag matches a row in its changelog when the row's "Where" cell names the tag's file, by its
# name without the extension (TickDriver, ai_batch_decider); one row may cover several tags. A row matching no tag is stale (the work
# was done) or its tag is missing. A row about something that can't hold a comment (scenes, a folder layout) says "no tag" in its
# Where cell, and needs none.
import os
import re
import sys

PROJECT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
SCRIPTS = os.path.join(PROJECT, "assets", "scripts")
NATIVE = os.path.join(PROJECT, "native", "src")
NOT_PRODUCTION = {"tests", "samples"}
TAG = re.compile(r"^\s*(#|//)\s*REFACTOR:")
COMMENT = re.compile(r"^\s*(#|//)")
NAMED_CHANGELOG = re.compile(r"\b(native|[a-z_]+)/CHANGELOG\.md")


def production_files():
    """Every production source file, as (path, its changelog by default)."""
    for root, dirs, files in os.walk(SCRIPTS):
        dirs[:] = [d for d in dirs if d not in NOT_PRODUCTION]
        system = os.path.relpath(root, SCRIPTS).split(os.sep)[0]
        for name in files:
            if name.endswith(".gd"):
                yield os.path.join(root, name), os.path.join(SCRIPTS, system, "CHANGELOG.md")
    for name in os.listdir(NATIVE):
        if name.endswith((".h", ".cpp")):
            yield os.path.join(NATIVE, name), os.path.join(PROJECT, "native", "CHANGELOG.md")


def changelog_path(named):
    if named == "native":
        return os.path.join(PROJECT, "native", "CHANGELOG.md")
    return os.path.join(SCRIPTS, named, "CHANGELOG.md")


def find_tags():
    """Each tag as {file, line, stem, changelog, text}."""
    tags = []
    for path, default_changelog in production_files():
        with open(path, encoding="utf-8") as f:
            lines = f.read().split("\n")
        for i, line in enumerate(lines):
            if not TAG.match(line):
                continue
            block = [line]
            for following in lines[i + 1:]:
                if not COMMENT.match(following) or TAG.match(following):
                    break
                block.append(following)
            text = " ".join(part.strip().lstrip("#/").strip() for part in block)
            named = NAMED_CHANGELOG.search(text)
            changelog = changelog_path(named.group(1)) if named else default_changelog
            tags.append({"file": path, "line": i + 1, "stem": os.path.splitext(os.path.basename(path))[0], "changelog": changelog,
                         "text": text})
    return tags


def find_rows(changelog):
    """The refactor table's rows in a changelog, as {line, what, where}; empty if it has none."""
    if not os.path.exists(changelog):
        return []
    rows = []
    in_section = False
    with open(changelog, encoding="utf-8") as f:
        for number, line in enumerate(f, 1):
            if line.startswith("## "):
                in_section = line.strip() == "## Refactor candidates"
                continue
            if not in_section or not line.startswith("|") or line.startswith("|---") or line.startswith("| What |"):
                continue
            cells = [c.strip() for c in line.strip().strip("|").split("|")]
            if len(cells) >= 2:
                rows.append({"line": number, "what": cells[0], "where": cells[1]})
    return rows


def names_stem(where, stem):
    # The file's name as a word in the Where cell: "TickDriver.replace_store", "`ai_batch_decider.*`", "`AIManager`".
    return re.search(r"(?<![A-Za-z0-9_])" + re.escape(stem) + r"(?![A-Za-z0-9_])", where) is not None


def main():
    verbose = "-v" in sys.argv[1:]
    tags = find_tags()
    changelogs = sorted({t["changelog"] for t in tags} | {os.path.join(SCRIPTS, s, "CHANGELOG.md") for s in os.listdir(SCRIPTS)
                         if os.path.isdir(os.path.join(SCRIPTS, s))} | {os.path.join(PROJECT, "native", "CHANGELOG.md")})
    rows = {c: find_rows(c) for c in changelogs}
    matched_rows = set()
    finds = []
    rel = lambda p: os.path.relpath(p, PROJECT).replace(os.sep, "/")
    for tag in tags:
        hits = [r for r in rows.get(tag["changelog"], []) if names_stem(r["where"], tag["stem"])]
        if not hits:
            finds.append("%s:%d  tag with no row in %s: %s" % (rel(tag["file"]), tag["line"], rel(tag["changelog"]), tag["text"][:110]))
        for r in hits:
            matched_rows.add((tag["changelog"], r["line"]))
        if verbose and hits:
            print("%s:%d -> %s:%d" % (rel(tag["file"]), tag["line"], rel(tag["changelog"]), hits[0]["line"]))
    row_count = 0
    for changelog, table in rows.items():
        for r in table:
            row_count += 1
            if (changelog, r["line"]) not in matched_rows and "no tag" not in r["where"]:
                finds.append("%s:%d  row with no tag: %s (where: %s)" % (rel(changelog), r["line"], r["what"][:70], r["where"][:70]))
        with open(changelog, encoding="utf-8") if os.path.exists(changelog) else open(os.devnull) as f:
            if f.read().count("## Refactor candidates") > 1:
                finds.append("%s  has more than one \"## Refactor candidates\" heading" % rel(changelog))
    for find in finds:
        print(find)
    print("%d tags, %d rows, %d finds" % (len(tags), row_count, len(finds)))
    return 1 if finds else 0


if __name__ == "__main__":
    sys.exit(main())
