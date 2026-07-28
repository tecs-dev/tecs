"""Resolves every internal link in the documentation tree.

A flat index of sixty entries is exactly where a dead link hides: nobody reads
it top to bottom, so a target that moved is found by the first person who
needed it. This walks every page, pulls every link that stays inside the site,
and resolves it the way VitePress does.

Three kinds of target are checked:

  /modules/camera        docs/modules/camera.md
  /ecs/queries/          docs/ecs/queries/index.md
  #a-heading             a heading, or an explicit {#id}, on the same page

Anchors are checked across pages too, so `/modules/Application#crashes` fails
when that section is renamed. Slugs follow GitHub's rule, which is what
VitePress uses: lowercase, spaces to hyphens, punctuation dropped.

External links are not fetched. This says a link resolves inside the tree, not
that github.com still serves what it points at. One external target is refused
outright: a link into `README.md`, because a page that sends a reader to the
design record to find out how something works has not documented it.

Run from anywhere: python3 docs/scripts/checklinks.py
"""

import re
import sys
import unicodedata
from pathlib import Path

DOCS = Path(__file__).resolve().parent.parent

# Markdown `[text](target)` and HTML `href="target"`, which the home page's
# feature cards are written in.
MARKDOWN_LINK = re.compile(r"\[[^\]]*\]\(([^)\s]+)\)")
HTML_HREF = re.compile(r'href="([^"]+)"')

# An ATX heading, and the explicit id VitePress lets one carry.
HEADING = re.compile(r"^(#{1,6})\s+(.*?)\s*$")
EXPLICIT_ID = re.compile(r"\{#([^}]+)\}\s*$")

# An `<a id="...">` anchor, which a generated reference section is full of.
HTML_ANCHOR = re.compile(r'<a id="([^"]+)"')

SKIPPED_PREFIXES = ("http://", "https://", "mailto:", "tel:", "//")

# A link into the design record. Refused rather than followed: a site that sends
# a reader to a design document to find out how something works has not
# documented it. What a reader needs to use a module belongs on the module's
# page, in the page's own words. `README.md` keeps the history, which is a
# different job and not one a reader of this site has come for.
DESIGN_RECORD = re.compile(r"README\.md(#|$|\?)")


def slug(text):
    """The id VitePress gives a heading, by GitHub's rule."""
    text = EXPLICIT_ID.sub("", text)
    # Strip inline markup that never reaches the rendered heading text.
    text = re.sub(r"`([^`]*)`", r"\1", text)
    text = re.sub(r"\[([^\]]*)\]\([^)]*\)", r"\1", text)
    text = re.sub(r"[*_]{1,3}([^*_]*)[*_]{1,3}", r"\1", text)
    text = unicodedata.normalize("NFKD", text).lower()
    text = re.sub(r"[^\w\- ]", "", text)
    return text.strip().replace(" ", "-")


def anchorsOf(path):
    """Every id a link can target on one page."""
    found = set()
    fenced = False
    for line in path.read_text(encoding="utf-8").splitlines():
        if line.startswith("```"):
            fenced = not fenced
            continue
        if fenced:
            continue
        found.update(HTML_ANCHOR.findall(line))
        match = HEADING.match(line)
        if not match:
            continue
        explicit = EXPLICIT_ID.search(match.group(2))
        found.add(explicit.group(1) if explicit else slug(match.group(2)))
    return found


def exists(path):
    """Whether the file is there, spelled the way it was asked for.

    `is_file` alone is not enough. The filesystem this is usually run on is
    case insensitive, so it answers True for `Future.md` when the file on disk
    is `future.md`, while VitePress resolves a route against its own table and
    is case sensitive either way. A link that only works locally is the exact
    thing this script exists to catch.
    """
    if not path.is_file():
        return False
    walked = DOCS
    for part in path.relative_to(DOCS).parts:
        names = {entry.name for entry in walked.iterdir()}
        if part not in names:
            return False
        walked = walked / part
    return True


def pageFor(route):
    """The file a site-absolute route resolves to, or None.

    A directory's index is reached only through a trailing slash, because that
    is what VitePress does: `/modules/gfx/` is the page and `/modules/gfx` is a
    dead link. Resolving both here would pass a build that fails.
    """
    clean = route.strip("/")
    if not clean:
        return DOCS / "index.md"
    if route.endswith("/"):
        nested = DOCS / clean / "index.md"
        return nested if exists(nested) else None
    direct = DOCS / f"{clean}.md"
    if exists(direct):
        return direct
    return None


def linksIn(path):
    """Every link target on a page, outside fenced code."""
    found = []
    fenced = False
    for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        if line.startswith("```"):
            fenced = not fenced
            continue
        if fenced:
            continue
        for target in MARKDOWN_LINK.findall(line) + HTML_HREF.findall(line):
            found.append((number, target))
    return found


def main():
    pages = sorted(
        page for page in DOCS.rglob("*.md") if ".vitepress" not in page.parts and "node_modules" not in page.parts
    )
    anchorCache = {}
    broken = []

    for page in pages:
        relative = page.relative_to(DOCS)
        for number, target in linksIn(page):
            if DESIGN_RECORD.search(target):
                broken.append((relative, number, target, "links into the design record"))
                continue
            if target.startswith(SKIPPED_PREFIXES):
                continue

            route, _, fragment = target.partition("#")
            if not route:
                destination = page
            elif route.startswith("/"):
                destination = pageFor(route)
            else:
                # Relative links are not used in this tree, and resolving them
                # silently would let one in without anyone deciding to.
                broken.append((relative, number, target, "relative link"))
                continue

            if destination is None:
                broken.append((relative, number, target, "no such page"))
                continue

            if not fragment:
                continue
            if destination not in anchorCache:
                anchorCache[destination] = anchorsOf(destination)
            if fragment not in anchorCache[destination]:
                broken.append((relative, number, target, "no such anchor"))

    if broken:
        print(f"Broken links: {len(broken)}", file=sys.stderr)
        for relative, number, target, why in broken:
            print(f"  docs/{relative}:{number}  {target}  ({why})", file=sys.stderr)
        return 1

    total = sum(len(linksIn(page)) for page in pages)
    print(f"OK: {len(pages)} pages, {total} links, none broken")
    return 0


if __name__ == "__main__":
    sys.exit(main())
