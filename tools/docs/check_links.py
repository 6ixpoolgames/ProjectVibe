# Written by Claude (claude-opus-5-5), 2026-11-17: checks every relative link in the project's Markdown docs (wiki spec section 4,
# phase W0): the file it points at exists, and so does the heading an #anchor names. Links to websites aren't checked.
#
# Run from the project folder:
#   python tools/docs/check_links.py
# Exits 0 when every link resolves, 1 otherwise, listing each broken one.
import os
import re
import sys

PROJECT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
# Where docs live. docs/legacy is the old code's documentation, kept as it was.
ROOTS = ["assets/scripts", "docs", "tools", "native", "CLAUDE.md"]
# The wiki's own pages link by their paths in the built site, which MkDocs checks when it builds (tools/docs/build_wiki.py).
SKIP = [os.path.join("docs", "legacy"), os.path.join("native", "thirdparty"), os.path.join("docs", "wiki", "pages")]
LINK = re.compile(r"(?<!!)\[[^\]]*\]\(([^)\s]+)\)")


def main() -> int:
    broken = 0
    checked = 0
    for path in markdown_files():
        with open(path, encoding="utf-8") as doc:
            text = strip_code(doc.read())
        for target in LINK.findall(text):
            if re.match(r"^[a-z]+:", target):
                continue # a website or mailto
            checked += 1
            problem = check(path, target)
            if problem:
                broken += 1
                print("%s: %s (%s)" % (os.path.relpath(path, PROJECT), target, problem))
    print("%d links checked, %d broken" % (checked, broken))
    return 1 if broken else 0


def markdown_files():
    for root in ROOTS:
        full = os.path.join(PROJECT, root)
        if os.path.isfile(full):
            yield full
            continue
        for folder, subfolders, files in os.walk(full):
            if any(os.path.relpath(folder, PROJECT).startswith(skip) for skip in SKIP):
                subfolders[:] = []
                continue
            for name in files:
                if name.endswith(".md"):
                    yield os.path.join(folder, name)


# Code blocks and inline code aren't links.
def strip_code(text: str) -> str:
    text = re.sub(r"```.*?```", "", text, flags=re.DOTALL)
    return re.sub(r"`[^`\n]*`", "", text)


def check(source: str, target: str) -> str:
    file_part, _, anchor = target.partition("#")
    destination = source if file_part == "" else os.path.normpath(os.path.join(os.path.dirname(source), file_part))
    if not os.path.exists(destination):
        return "no such file"
    if anchor and destination.endswith(".md"):
        with open(destination, encoding="utf-8") as doc:
            if anchor not in heading_anchors(doc.read()):
                return "no such heading"
    return ""


# GitHub's rule: lower case, punctuation dropped (except - and _), spaces to dashes; repeats get -1, -2.
def heading_anchors(text: str) -> set:
    anchors = set()
    seen = {}
    for heading in re.findall(r"^#{1,6}\s+(.+?)\s*#*$", strip_fences(text), flags=re.MULTILINE):
        heading = re.sub(r"`|\*\*|\*|\[([^\]]*)\]\([^)]*\)", r"\1", heading)
        base = re.sub(r"[^\w\- ]", "", heading.lower()).replace(" ", "-")
        count = seen.get(base, 0)
        seen[base] = count + 1
        anchors.add(base if count == 0 else "%s-%d" % (base, count))
    return anchors


def strip_fences(text: str) -> str:
    return re.sub(r"```.*?```", "", text, flags=re.DOTALL)


if __name__ == "__main__":
    sys.exit(main())
