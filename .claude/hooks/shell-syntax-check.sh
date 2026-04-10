#!/usr/bin/env bash
set -euo pipefail

input=$(cat)
[[ -z "$input" ]] && exit 0

file_path=$(echo "$input" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    ti = d.get('tool_input', d)
    print(ti.get('file_path', ti.get('path', '')))
except Exception:
    print('')
" 2>/dev/null || true)

[[ -z "$file_path" ]] && exit 0
[[ "$file_path" != *.sh ]] && exit 0
[[ ! -f "$file_path" ]] && exit 0

# Skip test-repos fixtures — those may have intentional patterns
[[ "$file_path" == *"test-repos/"* ]] && exit 0

if ! bash -n "$file_path" 2>/tmp/ultrainit-bash-syntax-err-$$; then
    echo "BLOCKED: bash -n failed on $file_path" >&2
    cat /tmp/ultrainit-bash-syntax-err-$$ >&2
    echo "" >&2
    echo "Fix the syntax error shown above. The file has been written but contains invalid shell syntax." >&2
    echo "Safe alternative: Fix the indicated line, then re-save the file." >&2
    rm -f /tmp/ultrainit-bash-syntax-err-$$
    exit 2
fi

rm -f /tmp/ultrainit-bash-syntax-err-$$
exit 0

