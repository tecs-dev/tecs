#!/usr/bin/env bash
#
# Holds the documentation to the public API: every public name has a page,
# every page under docs/modules/ names something public, the two places that
# list the modules list all of them in the same order, and the sidebar has one
# row per page.
#
# The names come out of `src/tecs/init.tl`, which is the definition of what is
# public rather than a list kept beside it. The value fields of `record tecs`
# are the top of it: the modules and namespaces resolved through SURFACE, and
# `tecs.ecs` beside them. A type field is not checked, since a type is written
# in an annotation rather than looked up in an index.
#
# A module may sit inside another, one level and no deeper, and is written the
# way a game writes it: `tecs.gfx.layers`. Those come from `SURFACE`, which is
# where the nesting is declared: a `within` key is a name one level down. The
# records cannot answer this, because a namespace with one principal module
# resolves to that module and is typed by the module's own record rather than by
# one written here. A `within` key that is PascalCase is a class reached through
# its namespace, `tecs.input.Gamepad`, and belongs on its owner's page rather
# than having one of its own; only a luacase one is a module wanting a page.
#
# Set equality both ways, because one direction is not enough. Checking only
# that a name has a page lets pages for things that no longer exist pile up,
# which is how a documentation tree ends up describing an engine that is gone.
# Checking only that a page has a name lets a module ship undocumented.
#
# WHAT THIS DOES NOT CATCH, and the list is longer than what it does. It sees a
# module added without a page. It cannot see a function whose signature moved
# without its section moving, a default that changed without the sentence about
# it changing, a page that describes behavior the code never had, or a page
# that is three sentences of throat-clearing under a correct title. Nothing
# here reads prose, and prose is where the documentation actually is. Treat a
# pass as "the index is complete", never as "the pages are right".
#
# The one machine-checkable claim about content lives next door:
# cargo xtask docs-reference and docs-check own generated reference sections
# page against a fresh render, so signatures cannot drift even though the words
# around them can.
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

# Value fields of `record tecs`, then the subordinate modules of each. A
# `type X = ...` line starts with "type" and is skipped; a doc comment starts
# with "---". The nesting is read out of `SURFACE` beneath the records, by brace
# depth: a descriptor is written on one line while it fits and wraps when it does
# not, so indentation says nothing and the braces say everything. An identifier
# followed by `=` and then `{` opens a table, and one opened at depth three
# inside a `within` is a name one level down. No string in that table holds a
# brace, so no quoting is tracked.
public=$(awk '
    /^local record tecs$/ { intecs = 1; next }
    intecs && /^end$/ { intecs = 0; next }
    intecs && /^    [A-Za-z_][A-Za-z0-9_]*: / {
        split($1, parts, ":")
        order[++count] = parts[1]
        next
    }
    /^local SURFACE/ { insurface = 1; next }
    insurface && /^}$/ { insurface = 0; next }
    insurface { text = text $0 }
    END {
        token = ""; last = ""; key = ""; depth = 0
        for (at = 1; at <= length(text); at++) {
            character = substr(text, at, 1)
            if (character ~ /[A-Za-z0-9_]/) { token = token character; continue }
            if (token != "") { last = token; token = "" }
            if (character == "=") { key = last; last = "" }
            else if (character == "{") {
                nesting[++depth] = key; key = ""; last = ""
                if (depth == 3 && nesting[2] == "within") {
                    below[nesting[1]] = below[nesting[1]] " " nesting[3]
                }
            }
            else if (character == "}") { depth--; key = ""; last = "" }
        }
        for (i = 1; i <= count; i++) {
            name = order[i]
            print name
            found = split(below[name], members, " ")
            for (j = 1; j <= found; j++) {
                if (members[j] ~ /^[a-z]/) {
                    print name "." members[j]
                }
            }
        }
    }
' "$init")

if [ -z "$public" ]; then
    echo "no public names were found in $init; the record shape must have changed" >&2
    exit 1
fi

missing=()
for name in $public; do
    # A page for a name is any page that writes it the way a game writes it.
    # A module has its own page under docs/modules/; `tecs.ecs` is documented
    # across the ECS section, where `tecs.ecs.newWorld` sits on the World page
    # rather than on one of its own.
    if ! grep -rqF "tecs.$name" --include='*.md' docs/ecs docs/modules docs/index.md docs/getting-started.md 2>/dev/null; then
        missing+=("$name")
    fi
done

# The other direction, and it recurses, because a subordinate module has a page
# in a directory named for its parent. A page's path under docs/modules is the
# name it documents with the dots written as slashes, so `gfx/layers.md` is
# `tecs.gfx.layers` and the `index.md` beside it is `tecs.gfx`. The one at the
# top, `docs/modules/index.md`, is the list of names rather than one of them,
# and it names every module by construction, so it proves nothing about
# coverage.
orphans=()
while IFS= read -r page; do
    name=${page#docs/modules/}
    name=${name%.md}
    name=${name%/index}
    if [ "$name" = "index" ]; then
        continue
    fi
    name=${name//\//.}
    if ! printf '%s\n' $public | grep -qx "$name"; then
        orphans+=("$page")
    fi
done < <(find docs/modules -name '*.md' | LC_ALL=C sort)

# Stubs are a legitimate state: a page that says "this module is being
# replaced, here is what will still be true" is more honest than a reference
# written against something that moves next week. So this counts them and says
# so rather than failing, because the number going up unnoticed is the failure
# mode, not the number being greater than zero.
stubs=()
while IFS= read -r page; do
    stubs+=("$(basename "$page" .md)")
done < <(grep -rl '^::: warning This page is pending$' --include='*.md' docs/modules | sort)

# The modules are listed twice, on the index and on the home page. Two copies of
# one list is a chance to disagree, and a name added to one of them reads as
# complete from whichever you happened to open. So the order is derived here
# rather than trusted, and both are held to it.
#
# Alphabetical ignoring case, ties broken by byte order. LC_ALL=C pins that,
# since a locale that collates differently would make this pass on one machine
# and fail on another.
# Fields of `record tecs` that are not modules: a function, a string, or a type
# the root carries because it crosses subsystems. The discriminator is the one
# already used for subordinate modules, and for the same reason: a module is
# luacase and is declared as a type imported from a module ending in its public
# name. Usually the alias matches (`assets: assets`), but it may differ to avoid
# shadowing a standard-library global (`math: vectorMath`).
# `newApplication: function(...)`, `version: string` and `Transform:
# ecs.Transform` are none of those things.
rootnames=$(awk '
    /^local type [a-z][A-Za-z0-9_]* = require\("tecs\.[A-Za-z0-9_.]+"\)$/ {
        alias = $3
        path = $5
        sub(/^require\("tecs\./, "", path)
        sub(/"\)$/, "", path)
        count = split(path, parts, ".")
        module[alias] = parts[count]
        next
    }
    /^local record tecs$/ { intecs = 1; next }
    intecs && /^end$/ { intecs = 0; next }
    intecs && /^    [A-Za-z_][A-Za-z0-9_]*: / {
        split($0, halves, ": ")
        name = halves[1]
        sub(/^ +/, "", name)
        declared = halves[2]
        for (i = 3; i <= length(halves); i++) { declared = declared ": " halves[i] }
        if (name ~ /^[a-z]/ && (declared == name || module[declared] == name)) { next }
        print name
    }
' "$init")

# Three groups, in the order a listing presents them: the modules a game
# reaches directly, then the modules that sit inside one of those, then the
# types and functions on `tecs` itself. Grouping is what a reader wants from a
# list of thirty names, and each group is still a total order, so a listing
# that drops or reorders a name is still caught.
#
# A name with a dot in it is a subordinate module. A name whose last segment
# starts with a capital, or which has a page-less entry, is neither a module
# nor subordinate: it is something on the root.
group() {
    want=$1
    printf '%s\n' $public | while IFS= read -r name; do
        case "$name" in
            *.*) kind=sub ;;
            *)
                if printf '%s\n' "$rootnames" | grep -qx "$name"; then
                    kind=root
                else
                    kind=top
                fi
                ;;
        esac
        if [ "$kind" = "$want" ]; then
            echo "$name"
        fi
    done | LC_ALL=C sort -f
}
expected=$(
    group top
    group sub
    group root
)

# A name is written as ``- [`tecs.name`](link)`` or as a table row, since a page
# may list either way. Both are matched at the start of a line, so a name
# mentioned in prose is not mistaken for a list entry.
listOf() {
    sed -n -e 's/^- \[`tecs\.\([A-Za-z_][A-Za-z0-9_.]*\)`\].*/\1/p' \
           -e 's/^| \[`tecs\.\([A-Za-z_][A-Za-z0-9_.]*\)`\].*/\1/p' "$1"
}

status=0

# `diff` answers 1 when its inputs differ, which is the case every one of these
# is reached in, and `set -e` would take that as the script failing and stop
# here. So each is allowed to answer, and the run ends at the status collected
# below instead: a reader fixing one of these wants all of them at once rather
# than one per run.
report() {
    diff -u <(printf '%s\n' "$1") <(printf '%s\n' "$2") | sed -e '1,2d' -e 's/^/  /' >&2 || true
}

for listing in docs/modules/index.md docs/index.md; do
    if [ "$(listOf "$listing")" != "$expected" ]; then
        echo "$listing does not list the modules in the expected order:" >&2
        report "$expected" "$(listOf "$listing")"
        echo >&2
        echo "One alphabetical list, ignoring case, in both places. Lines" >&2
        echo "starting - or + above are what that file has wrong." >&2
        echo >&2
        status=1
    fi
done

# The sidebar is held to the pages instead, because that is what it is for. It
# moves a reader between pages; a function lives on the page that documents it
# and is reached through that page's own outline. So a row per page, no row for
# anything smaller, and nothing unreachable.
#
# Read from `sidebar:` onwards, so the top nav and the social links are not
# mistaken for navigation into the content. Duplicates collapse, since a group's
# own overview row repeats the link the group heading above it carries.
sidebarLinks=$(awk '
    /^ *sidebar: \[/ { inside = 1 }
    inside && match($0, /link: "\/[^"]*"/) {
        print substr($0, RSTART + 7, RLENGTH - 8)
    }
' docs/.vitepress/config.mts | sort -u)

# Every page, as the link that reaches it. The home page is the site root and is
# not navigated to from the sidebar; node_modules and the theme are not content.
pageLinks=$(find docs -name '*.md' \
    -not -path 'docs/node_modules/*' \
    -not -path 'docs/.vitepress/*' \
    -not -path 'docs/index.md' |
    sed -e 's|^docs||' -e 's|\.md$||' -e 's|/index$|/|' | sort -u)

if [ "$sidebarLinks" != "$pageLinks" ]; then
    echo "docs/.vitepress/config.mts does not have one sidebar row per page:" >&2
    report "$pageLinks" "$sidebarLinks"
    echo >&2
    echo "A line starting - is a page nothing navigates to; one starting + is a" >&2
    echo "sidebar row pointing at no page." >&2
    echo >&2
    status=1
fi

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
    printf '  %s\n' "${orphans[@]}" >&2
    echo >&2
    echo "The module moved and the page did not. Delete it, or rename it to" >&2
    echo "the field that replaced it." >&2
    echo >&2
    status=1
fi

if [ "$status" -ne 0 ]; then
    exit 1
fi

count=$(printf '%s\n' $public | wc -l | tr -d ' ')
echo "OK: all $count public names have a page, listed alike in both indexes, one sidebar row per page, and no page outlives its module"

if [ "${#stubs[@]}" -gt 0 ]; then
    echo "Stubbed, pending a module that is still moving: ${#stubs[@]} (${stubs[*]})"
fi
