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

# Security-critical files — warn with the safe alternative
warn() {
    local file="$1" reason="$2" safe="$3"
    echo "WARNING: Editing security-critical file: $file" >&2
    echo "Reason: $reason" >&2
    echo "Safe alternative: $safe" >&2
    echo "" >&2
}

case "$file_path" in
    *"lib/config.sh"*)
        warn "$file_path" \
            "Handles Claude auth verification, budget arithmetic, and dependency checks. Bugs here silently bypass auth or blow budget." \
            "Add a test in tests/unit/config_budget.bats and run make test-unit before merging."
        ;;
    *"lib/agent.sh"*)
        warn "$file_path" \
            "Controls budget enforcement (--max-budget-usd), cost tracking, and API response validation. Bugs cause runaway API spend." \
            "Add a test in tests/unit/agent_run.bats and run make test-unit before merging."
        ;;
    *"lib/validate.sh"*)
        warn "$file_path" \
            "Enforces quality gates on all generated artifacts. Weakening checks here silently degrades output quality." \
            "Add regression tests in tests/unit/validate_claude_md.bats before modifying validation rules."
        ;;
    *"scripts/validate-skill.sh"*)
        warn "$file_path" \
            "Standalone skill quality validator used in Phase 5 production runs and tested independently." \
            "Update tests/scripts/validate_skill.bats alongside any rule changes. Run make test-scripts."
        ;;
    *"scripts/validate-subagent.sh"*)
        warn "$file_path" \
            "Standalone subagent quality validator. Same risk as validate-skill.sh." \
            "Update tests/scripts/validate_subagent.bats alongside any rule changes. Run make test-scripts."
        ;;
    *".github/workflows/"*)
        warn "$file_path" \
            "CI/CD pipeline definition. Incorrect edits break releases, test runs, or Docker image publishing." \
            "Test pipeline changes in a feature branch first. The docker-test-image.yml only fires when Dockerfile.test changes on main."
        ;;
    *"bundle.sh"*)
        warn "$file_path" \
            "Release bundler. Any stdout output from bundle.sh corrupts the artifact (release.yml does: bash bundle.sh > dist/ultrainit.sh)." \
            "After editing: run make check, bash bundle.sh > dist/ultrainit.sh, bash -n dist/ultrainit.sh, and check bundle size."
        ;;
    *"Dockerfile.test"*)
        warn "$file_path" \
            "Defines the isolated bats-core test environment. Changes affect every CI test run and the published GHCR image." \
            "Build locally with make test-image first. Push to main to trigger docker-test-image.yml."
        ;;
    *"schemas/"*.json)
        warn "$file_path" \
            "Schema changes break structured output parsing for all agents that use it, potentially producing empty findings silently." \
            "Add new fields as optional (not in required). Update tests/fixtures/findings/$(basename "$file_path") and run make test-all."
        ;;
    *".gitignore"*)
        warn "$file_path" \
            "Removing .ultrainit/ would commit intermediate findings including sensitive developer answers." \
            "Append patterns with: echo 'pattern' >> .gitignore — never rewrite the file."
        ;;
esac

exit 0

