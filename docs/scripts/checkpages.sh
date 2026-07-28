#!/usr/bin/env bash
#
# Holds the documentation to the surface: every public name has a page, every
# page under docs/modules/ names something public, and the three places that
# list the surface list all of it in the same order.
#
# The names come out of `src/tecs/init.tl`, which is the definition of what is
# public rather than a list kept beside it. The value fields of `record tecs`
# are the whole surface: the engine half, whose fields are resolved through the
# ENGINE map, and the eager half beside them. A type field is not checked,
# since a type is written in an annotation rather than looked up in an index.
#
# Set equality both ways, because one direction is not enough. Checking only
# that a name has a page lets pages for things that no longer exist pile up,
# which is how a documentation tree ends up describing an engine that is gone.
# Checking only that a page has a name lets a module ship undocumented.
#
# WHAT THIS DOES NOT CATCH, and the list is longer than what it does. It sees a
# module added without a page. It cannot see a function whose signature moved
# without its section moving, a default that changed without the sentence about
# it changing, a page that describes behaviour the code never had, or a page
# that is three sentences of throat-clearing under a correct title. Nothing
# here reads prose, and prose is where the documentation actually is. Treat a
# pass as "the index is complete", never as "the pages are right".
#
# The one machine-checkable claim about content lives next door:
# docs/scripts/surface.sh --check diffs the generated signature page against a
# fresh render, so signatures cannot drift even though the words around them
# can.
#
# Run from anywhere: bash docs/scripts/checkpages.sh
set -euo pipefail

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo=$(CDPATH= cd -- "$here/../.." && pwd)
cd "$repo"

init="src/tecs/init.tl"
if [ ! -f "$init" ]; then
    echo "$init is missing; run this from a checkout" >&2
    exit 1
fi

# Value fields of `record tecs`, in declaration order. A `type X = ...` line
# starts with "type" and is skipped; a doc comment starts with "---".
public=$(awk '
    /^local record tecs$/ { inside = 1; next }
    inside && /^end$/ { exit }
    inside && /^    [A-Za-z_][A-Za-z0-9_]*: / {
        split($1, parts, ":")
        print parts[1]
    }
' "$init")

if [ -z "$public" ]; then
    echo "no public names were found in $init; the record shape must have changed" >&2
    exit 1
fi

# Pages that are the index or are generated from the surface itself, which name
# every module by construction and so prove nothing about coverage.
notAModulePage="index surface"

missing=()
for name in $public; do
    # A page for a name is any page that writes it the way a game writes it.
    # Engine-half names have their own page under docs/modules/; the eager half
    # is documented in the ECS section, where `tecs.newWorld` sits on the World
    # page rather than on one of its own.
    if ! grep -rqF "tecs.$name" --include='*.md' docs/ecs docs/modules docs/index.md docs/getting-started.md 2>/dev/null; then
        missing+=("$name")
    fi
done

orphans=()
for page in docs/modules/*.md; do
    name=$(basename "$page" .md)
    case " $notAModulePage " in
    *" $name "*) continue ;;
    esac
    if ! printf '%s\n' $public | grep -qx "$name"; then
        orphans+=("$name")
    fi
done

# Stubs are a legitimate state: a page that says "this surface is being
# replaced, here is what will still be true" is more honest than a reference
# written against something that moves next week. So this counts them and says
# so rather than failing, because the number going up unnoticed is the failure
# mode, not the number being greater than zero.
stubs=()
while IFS= read -r page; do
    stubs+=("$(basename "$page" .md)")
done < <(grep -rl '^::: warning This page is pending$' --include='*.md' docs/modules | sort)

# The surface is listed three times: the index, the home page and the sidebar.
# Three copies of one list is two chances to disagree, and a name added to two
# of them reads as complete from whichever one you happened to open. So the
# order is derived here rather than trusted, and all three are held to it.
#
# Alphabetical ignoring case, ties broken by byte order so the capitalised
# spelling comes first: `tecs.Application` above `tecs.application`. LC_ALL=C
# pins that, since a locale that collates differently would make this pass on
# one machine and fail on another.
expected=$(printf '%s\n' $public | LC_ALL=C sort -f)

# Markdown writes a name as ``- [`tecs.name`](link)``; the sidebar writes it as
# `{ text: "tecs.name", link: ... }`. Both are matched at the start of a line,
# so a name mentioned in prose is not mistaken for a list entry.
#
# The site config is read from `sidebar:` onwards and only where a `link:` sits
# on the same line. Both exclusions are there for `tecs.ecs`, which is spelled
# like a surface field in the top nav and again as a sidebar group heading, and
# is neither: it is a module a game does not require. Anchoring on those keys
# rather than on indentation keeps this working through a reformat.
listOf() {
    case "$1" in
    *.mts)
        awk '
            /^ *sidebar: \[/ { inside = 1 }
            inside && /link:/ && match($0, /text: "tecs\.[A-Za-z_][A-Za-z0-9_]*"/) {
                print substr($0, RSTART + 12, RLENGTH - 13)
            }
        ' "$1"
        ;;
    *) sed -n 's/^- \[`tecs\.\([A-Za-z_][A-Za-z0-9_]*\)`\].*/\1/p' "$1" ;;
    esac
}

status=0

for listing in docs/modules/index.md docs/index.md docs/.vitepress/config.mts; do
    if [ "$(listOf "$listing")" != "$expected" ]; then
        echo "$listing does not list the surface in the expected order:" >&2
        diff -u <(printf '%s\n' "$expected") <(listOf "$listing") |
            sed -e '1,2d' -e 's/^/  /' >&2
        echo >&2
        echo "One alphabetical list, ignoring case, in all three places. Lines" >&2
        echo "starting - or + above are what that file has wrong." >&2
        echo >&2
        status=1
    fi
done

if [ "${#missing[@]}" -gt 0 ]; then
    echo "Public names in $init with no page: ${#missing[@]}" >&2
    printf '  tecs.%s\n' "${missing[@]}" >&2
    echo >&2
    echo "Every name a game can write needs somewhere to read about it. Add a" >&2
    echo "page under docs/modules/ and list it in docs/modules/index.md." >&2
    echo >&2
    status=1
fi

if [ "${#orphans[@]}" -gt 0 ]; then
    echo "Pages under docs/modules/ naming nothing public: ${#orphans[@]}" >&2
    printf '  docs/modules/%s.md\n' "${orphans[@]}" >&2
    echo >&2
    echo "The surface moved and the page did not. Delete it, or rename it to" >&2
    echo "the field that replaced it." >&2
    echo >&2
    status=1
fi

if [ "$status" -ne 0 ]; then
    exit 1
fi

count=$(printf '%s\n' $public | wc -l | tr -d ' ')
echo "OK: all $count public names have a page, listed alike in three places, and no page outlives its module"

if [ "${#stubs[@]}" -gt 0 ]; then
    echo "Stubbed, pending a surface that is still moving: ${#stubs[@]} (${stubs[*]})"
fi
