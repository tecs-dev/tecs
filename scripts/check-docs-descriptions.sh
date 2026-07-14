#!/usr/bin/env bash
#
# Require a non-empty `description:` frontmatter key on every documentation
# page. The descriptions power the generated llms.txt index and the offline
# `tecs docs` reference, so a missing one leaves a page unlabeled in the tree.
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
    echo "Every docs page needs a one-line 'description:' — it labels the page in" >&2
    echo "llms.txt and the offline 'tecs docs' index." >&2
    exit 1
fi

echo "OK: all docs pages have a description"
