#!/usr/bin/env bash
set -euo pipefail

# Consume stdin (Stop event payload may be empty)
input=$(cat 2>/dev/null || true)

# Check for modified .sh files or schemas (staged or unstaged)
changed_sh=$(git diff --name-only HEAD 2>/dev/null | grep '\.sh$' | grep -v 'test-repos/' || true)
changed_schemas=$(git diff --name-only HEAD 2>/dev/null | grep '^schemas/.*\.json$' || true)
unstaged_sh=$(git diff --name-only 2>/dev/null | grep '\.sh$' | grep -v 'test-repos/' || true)
unstaged_schemas=$(git diff --name-only 2>/dev/null | grep '^schemas/.*\.json$' || true)

all_sh="${changed_sh}${unstaged_sh}"
all_schemas="${changed_schemas}${unstaged_schemas}"

if [[ -n "$all_sh" || -n "$all_schemas" ]]; then
    echo "" >&2
    echo "=== Quality check reminder ==================================================" >&2
    if [[ -n "$all_sh" ]]; then
        echo "Modified .sh files detected:" >&2
        echo "$all_sh" | sort -u | sed 's/^/  /' >&2
    fi
    if [[ -n "$all_schemas" ]]; then
        echo "Modified schemas detected:" >&2
        echo "$all_schemas" | sort -u | sed 's/^/  /' >&2
    fi
    echo "" >&2
    echo "Run before pushing:" >&2
    echo "  make check      # bash -n syntax + jq empty on all schemas" >&2
    echo "  make test-all   # full bats suite inside Docker" >&2
    echo "=============================================================================" >&2
fi

exit 0

