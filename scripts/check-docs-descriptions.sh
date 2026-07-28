#!/usr/bin/env bash
#
# Require a non-empty `description:` frontmatter key on every documentation
# page. The description is what labels a page in the site's own navigation and
# in a search result, so a missing one leaves a page unlabeled wherever it is
# listed rather than read.
#
# It used to say the descriptions also fed an offline `tecs docs` command. There
# is no such command and there will not be: the CLI ships a type checker, a
# formatter, a test runner and a build, and a documentation mirror inside a
# binary is a second copy of the site to keep in step. The site is the one copy.
# The check stays, because the frontmatter still does the job above.
#
# Run from the repository root: bash scripts/check-docs-descriptions.sh
set -euo pipefail

missing=()
while IFS= read -r f; do
    if ! awk '
        NR == 1 { if ($0 != "---") exit 1; next }
        /^---[[:space:]]*$/ { exit (found ? 0 : 1) }
        /^description:[[:space:]]*/ {
            v = $0
            sub(/^description:[[:space:]]*/, "", v)
            gsub(/^["'\'']|["'\'']$/, "", v)
            gsub(/[[:space:]]+$/, "", v)
            if (length(v) > 0) found = 1
        }
        END { exit (found ? 0 : 1) }
    ' "$f"; then
        missing+=("$f")
    fi
done < <(find docs -name '*.md' -not -path '*/.vitepress/*' -not -path '*/node_modules/*')

if [ "${#missing[@]}" -gt 0 ]; then
    echo "Missing a non-empty 'description:' frontmatter key in ${#missing[@]} page(s):" >&2
    printf '  %s\n' "${missing[@]}" >&2
    echo >&2
    echo "Every docs page needs a one-line 'description:'. It labels the page in" >&2
    echo "the site's navigation and in a search result." >&2
    exit 1
fi

echo "OK: all docs pages have a description"
