#!/bin/bash
# ABOUTME: Compiles every package under Examples/ against the local SendspinKit
# ABOUTME: Catches API drift, which the main `swift build`/`swift test` cannot see

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EXAMPLES_DIR="$REPO_ROOT/Examples"

failed=()
built=()

for manifest in "$EXAMPLES_DIR"/*/Package.swift; do
    dir="$(dirname "$manifest")"
    name="$(basename "$dir")"

    printf '%-24s ' "$name"
    start=$(date +%s)

    if (cd "$dir" && swift build > /tmp/build-example-$name.log 2>&1); then
        printf "${GREEN}ok${NC}   %ss\n" "$(( $(date +%s) - start ))"
        built+=("$name")
    else
        printf "${RED}FAIL${NC} %ss\n" "$(( $(date +%s) - start ))"
        grep -E '^/.*error:' "/tmp/build-example-$name.log" \
            | sed "s|$REPO_ROOT/||" | sort -u | sed 's/^/    /' || true
        echo "    (full log: /tmp/build-example-$name.log)"
        failed+=("$name")
    fi
done

echo
if [ ${#failed[@]} -eq 0 ]; then
    echo -e "${GREEN}All ${#built[@]} examples build.${NC}"
    exit 0
fi

echo -e "${RED}${#failed[@]} of $(( ${#built[@]} + ${#failed[@]} )) examples failed:${NC} ${failed[*]}"
echo -e "${YELLOW}For an inexhaustive switch, add the missing case rather than a 'default:'.${NC}"
exit 1
