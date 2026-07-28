"""Resolves every internal link in the documentation tree.

A flat index of sixty entries is exactly where a dead link hides: nobody reads
it top to bottom, so a target that moved is found by the first person who
needed it. This walks every page, pulls every link that stays inside the site,
and resolves it the way VitePress does.

Three kinds of target are checked:

  /modules/Camera        docs/modules/Camera.md
  /ecs/queries/          docs/ecs/queries/index.md
  #a-heading             a heading, or an explicit {#id}, on the same page

Anchors are checked across pages too, so `/modules/Application#crashes` fails
when that section is renamed. Slugs follow GitHub's rule, which is what
VitePress uses: lowercase, spaces to hyphens, punctuation dropped.

External links are not fetched. This says a link resolves inside the tree, not
that github.com still serves what it points at.

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

# An `<a id="...">` anchor, which the generated surface page is full of.
HTML_ANCHOR = re.compile(r'<a id="([^"]+)"')

SKIPPED_PREFIXES = ("http://", "https://", "mailto:", "tel:", "//")


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


def pageFor(route):
    """The file a site-absolute route resolves to, or None."""
    clean = route.strip("/")
    if not clean:
        return DOCS / "index.md"
    direct = DOCS / f"{clean}.md"
    if direct.is_file():
        return direct
    nested = DOCS / clean / "index.md"
    if nested.is_file():
        return nested
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
