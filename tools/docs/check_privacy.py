# Written by Claude (claude-opus-5-5), 2026-11-17: checks that nothing private is in the repository or the wiki built from it, the
# owner's rule: the repository and the wiki are public, so no local directories (a home folder carries its owner's name), no keys,
# codes or passwords, no email addresses, no real network addresses. The wiki build and its publishing workflow run it and stop on a
# find; run it before every commit and push too.
#
# Run from the project folder:
#   python tools/docs/check_privacy.py            every file git tracks, plus new files not yet added (ignored files are skipped)
#   python tools/docs/check_privacy.py <folder>   only the files under a folder, such as build/wiki/site
# Exits 0 when nothing is found, 1 otherwise, listing each find as file:line.
#
# It looks for your own name and email without them being written here (this file is public too): the machine's user name, the
# home folder, and git's user.email are read when it runs. Extra words to look for can go in the PRIVATE_WORDS environment variable,
# separated by commas.
import os
import re
import subprocess
import sys

PROJECT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
SKIP_FOLDERS = ("native/thirdparty/", ".godot/", "assets/legacy/",
                # The built wiki's theme files (MkDocs Material's own scripts and styles, with their authors' credits). Our pages
                # and the search index, which hold everything we wrote, are still checked.
                "build/wiki/site/assets/javascripts/", "build/wiki/site/assets/stylesheets/")
# An SVG icon's drawing data is long runs of numbers, which can look like network addresses.
SVG_PATH_DATA = re.compile(r"\sd=\"[^\"]*\"")
TEXT_ENDINGS = (".gd", ".md", ".txt", ".tscn", ".tres", ".cfg", ".godot", ".cpp", ".h", ".py", ".sh", ".yml", ".yaml", ".json",
                ".gdextension", ".html", ".css", ".js", ".csv", "SConstruct", ".gitignore")
# Addresses that are fine in docs: this machine, any address, broadcast, and the ranges set aside for examples (RFC 5737).
ALLOWED_ADDRESSES = re.compile(r"^(127\.0\.0\.1|0\.0\.0\.0|255\.255\.255\.255|192\.0\.2\.\d+|198\.51\.100\.\d+|203\.0\.113\.\d+)$")
ALLOWED_EMAILS = {"noreply@anthropic.com"} # the commit trailer

PATTERNS = [
    ("a local directory", re.compile(r"\b[A-Za-z]:[\\/](?:Users|Git|Program Files|Documents|Projects?)\b", re.IGNORECASE)),
    ("a local directory", re.compile(r"(?<![\w.])/(?:home|Users|mnt/[a-z])/[\w.-]+")),
    ("a local directory", re.compile(r"(?<![\w.])/c/(?:Users|Git)\b")),
    ("a home folder path", re.compile(r"(?<![\w.$])~/[\w.-]+")),
    ("a key or token", re.compile(r"\b(?:ghp_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|sk-[A-Za-z0-9_-]{20,}|AKIA[0-9A-Z]{16}|"
                                   r"xox[abpr]-[A-Za-z0-9-]{10,}|AIza[0-9A-Za-z_-]{35})\b")),
    ("a private key", re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----")),
    ("a password or secret", re.compile(r"\b(?:password|passwd|secret|api_?key|token)\s*[:=]\s*[\"'][^\"'\s]{6,}[\"']", re.IGNORECASE)),
]
EMAIL = re.compile(r"\b[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}\b")
ADDRESS = re.compile(r"(?<![\d.])(?:\d{1,3}\.){3}\d{1,3}(?![\d.])")


def main() -> int:
    files = files_to_check(sys.argv[1] if len(sys.argv) > 1 else None)
    words = private_words()
    finds = 0
    for path in files:
        try:
            with open(os.path.join(PROJECT, path), encoding="utf-8") as text:
                lines = text.read().split("\n")
        except (UnicodeDecodeError, OSError):
            continue
        for number, line in enumerate(lines, 1):
            for what in problems(line, words):
                finds += 1
                print("%s:%d: %s" % (path, number, what))
    print("%d files checked, %d finds" % (len(files), finds))
    return 1 if finds else 0


def files_to_check(folder):
    if folder:
        root = os.path.join(PROJECT, folder)
        found = []
        for current, _subfolders, names in os.walk(root):
            for name in names:
                found.append(os.path.relpath(os.path.join(current, name), PROJECT).replace(os.sep, "/"))
    else:
        listed = subprocess.run(["git", "ls-files", "-co", "--exclude-standard"], cwd=PROJECT, capture_output=True, text=True)
        found = listed.stdout.split("\n")
    me = os.path.relpath(os.path.abspath(__file__), PROJECT).replace(os.sep, "/")
    return [path for path in found if path and path != me and path.endswith(TEXT_ENDINGS) and not path.startswith(SKIP_FOLDERS)]


# This machine's user name, its home folder's name and git's email, plus any from PRIVATE_WORDS. Read now, never stored.
def private_words() -> list:
    words = set()
    for key in ("USERNAME", "USER"):
        if os.environ.get(key):
            words.add(os.environ[key])
    words.add(os.path.basename(os.path.expanduser("~")))
    email = subprocess.run(["git", "config", "user.email"], cwd=PROJECT, capture_output=True, text=True).stdout.strip()
    if email:
        words.add(email)
        words.add(email.split("@")[0])
    words.update(word.strip() for word in os.environ.get("PRIVATE_WORDS", "").split(",") if word.strip())
    # Too short or too common to search for safely (a CI runner's user name is "runner").
    return [word for word in words if len(word) >= 4 and word.lower() not in {"runner", "user", "admin", "root", "home"}]


def problems(line: str, words: list) -> list:
    found = []
    line = SVG_PATH_DATA.sub("", line)
    for what, pattern in PATTERNS:
        if pattern.search(line):
            found.append(what)
    for email in EMAIL.findall(line):
        if email.lower() not in ALLOWED_EMAILS and not email.lower().endswith(("@example.com", "@example.org")):
            found.append("an email address (%s)" % email)
    for address in ADDRESS.findall(line):
        if not ALLOWED_ADDRESSES.match(address) and all(0 <= int(part) <= 255 for part in address.split(".")):
            found.append("a network address (%s)" % address)
    lowered = line.lower()
    for word in words:
        if word.lower() in lowered:
            found.append("a private name or email (from this machine's settings)")
    return found


if __name__ == "__main__":
    sys.exit(main())
