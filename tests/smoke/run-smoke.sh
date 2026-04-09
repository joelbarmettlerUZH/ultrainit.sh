#!/usr/bin/env bash
# Smoke test: run the real ultrainit against a tiny codebase with real Claude.
#
# Usage:
#   bash tests/smoke/run-smoke.sh              # run bundled script
#   bash tests/smoke/run-smoke.sh --curl       # run via curl-pipe-bash (tests download flow)
#   bash tests/smoke/run-smoke.sh --source     # run from source (unbundled)
#
# Cost: ~$0.50-2 with haiku (default). Override with ULTRAINIT_MODEL=sonnet.
# Uses --skip-research and --model haiku to keep it fast and cheap.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
MINI_PROJECT="$SCRIPT_DIR/mini-project"
MODE="${1:-bundled}"

RED='\033[0;31m'
GREEN='\033[0;32m'
BOLD='\033[1m'
RESET='\033[0m'

pass() { echo -e "${GREEN}✓${RESET} $*"; }
fail() { echo -e "${RED}✗${RESET} $*"; FAILURES=$((FAILURES + 1)); }
FAILURES=0

echo -e "${BOLD}━━━ ultrainit smoke test ━━━${RESET}"
echo ""

# ── Clean previous runs ─────────────────────────────────────
rm -rf "$MINI_PROJECT/.ultrainit" "$MINI_PROJECT/CLAUDE.md" "$MINI_PROJECT/.claude"

# ── Run ultrainit ────────────────────────────────────────────
echo -e "${BOLD}Running ultrainit (mode: $MODE)...${RESET}"
echo ""

# Use haiku for gather agents (fast + cheap), haiku for synthesis too
export ULTRAINIT_MODEL="${ULTRAINIT_MODEL:-haiku}"
COMMON_FLAGS="--non-interactive --skip-research --budget 15 --model haiku"

case "$MODE" in
    --curl)
        # Test the curl-pipe-bash flow using the local bundle as a stand-in
        # (replace URL with real GitHub release URL to test actual deployment)
        bash "$PROJECT_ROOT/dist/ultrainit.sh" $COMMON_FLAGS "$MINI_PROJECT"
        ;;
    --source)
        # Run from source (unbundled)
        bash "$PROJECT_ROOT/ultrainit.sh" $COMMON_FLAGS "$MINI_PROJECT"
        ;;
    *)
        # Run the bundled script (default)
        if [[ ! -f "$PROJECT_ROOT/dist/ultrainit.sh" ]]; then
            echo "Bundle not found. Building..."
            make -C "$PROJECT_ROOT" bundle
        fi
        bash "$PROJECT_ROOT/dist/ultrainit.sh" $COMMON_FLAGS "$MINI_PROJECT"
        ;;
esac

echo ""
echo -e "${BOLD}━━━ Validating output ━━━${RESET}"
echo ""

# ── Check artifacts exist ────────────────────────────────────

if [[ -f "$MINI_PROJECT/CLAUDE.md" ]]; then
    lines=$(wc -l < "$MINI_PROJECT/CLAUDE.md")
    if [[ $lines -ge 50 ]]; then
        pass "CLAUDE.md exists ($lines lines)"
    else
        fail "CLAUDE.md too short ($lines lines, expected 50+)"
    fi
else
    fail "CLAUDE.md not created"
fi

if [[ -d "$MINI_PROJECT/.claude/skills" ]]; then
    skill_count=$(find "$MINI_PROJECT/.claude/skills" -name "SKILL.md" | wc -l)
    if [[ $skill_count -ge 1 ]]; then
        pass "Skills directory has $skill_count skill(s)"
    else
        fail "Skills directory exists but is empty"
    fi
else
    fail "No .claude/skills/ directory"
fi

if [[ -f "$MINI_PROJECT/.claude/settings.json" ]]; then
    if jq empty "$MINI_PROJECT/.claude/settings.json" 2>/dev/null; then
        pass "settings.json is valid JSON"
    else
        fail "settings.json is invalid JSON"
    fi
else
    # settings.json is optional (only if hooks were generated)
    pass "settings.json not generated (no hooks — acceptable)"
fi

# ── Check CLAUDE.md quality ──────────────────────────────────

if [[ -f "$MINI_PROJECT/CLAUDE.md" ]]; then
    # Should mention the project name or tech
    if grep -qiE '(todo|flask|python|api)' "$MINI_PROJECT/CLAUDE.md"; then
        pass "CLAUDE.md mentions project-specific terms"
    else
        fail "CLAUDE.md seems generic (no project terms found)"
    fi

    # Should have commands
    if grep -qE '(```|pytest|pip |python )' "$MINI_PROJECT/CLAUDE.md"; then
        pass "CLAUDE.md contains commands/code blocks"
    else
        fail "CLAUDE.md has no commands or code blocks"
    fi

    # Should NOT have generic filler
    generic=$(grep -ciE '(best practice|clean code|solid principle)' "$MINI_PROJECT/CLAUDE.md" || true)
    if [[ $generic -eq 0 ]]; then
        pass "CLAUDE.md has no generic filler phrases"
    else
        fail "CLAUDE.md has $generic generic phrase(s)"
    fi
fi

# ── Check findings were created ──────────────────────────────

if [[ -d "$MINI_PROJECT/.ultrainit/findings" ]]; then
    finding_count=$(ls "$MINI_PROJECT/.ultrainit/findings/"*.json 2>/dev/null | wc -l)
    if [[ $finding_count -ge 5 ]]; then
        pass "Generated $finding_count findings files"
    else
        fail "Only $finding_count findings (expected 5+)"
    fi
else
    fail "No .ultrainit/findings/ directory"
fi

# ── Check cost was tracked ───────────────────────────────────

if [[ -d "$MINI_PROJECT/.ultrainit/costs" ]]; then
    cost_count=$(ls "$MINI_PROJECT/.ultrainit/costs/"*.cost 2>/dev/null | wc -l)
    if [[ $cost_count -ge 1 ]]; then
        total=$(cat "$MINI_PROJECT/.ultrainit/costs/"*.cost | awk -F'|' '{s+=$3} END {printf "%.2f", s}')
        pass "Cost tracked: \$$total across $cost_count agent(s)"
    else
        fail "No cost files generated"
    fi
else
    fail "No .ultrainit/costs/ directory"
fi

# ── Summary ──────────────────────────────────────────────────

echo ""
if [[ $FAILURES -eq 0 ]]; then
    echo -e "${GREEN}${BOLD}All smoke checks passed!${RESET}"
else
    echo -e "${RED}${BOLD}$FAILURES check(s) failed.${RESET}"
    exit 1
fi
