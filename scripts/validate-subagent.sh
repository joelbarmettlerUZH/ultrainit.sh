#!/usr/bin/env bash
# validate-subagent.sh — Quality check for a subagent .md file
# Usage: bash scripts/validate-subagent.sh path/to/agent.md
set -euo pipefail

AGENT_PATH="${1:?Usage: validate-subagent.sh <path-to-agent.md>}"
ERRORS=0
WARNINGS=0

if [ ! -f "$AGENT_PATH" ]; then
  echo "ERROR: File not found: $AGENT_PATH" >&2
  exit 1
fi

AGENT_NAME=$(basename "$AGENT_PATH" .md)

echo "=== Validating subagent: $AGENT_NAME ==="
echo ""

# --- Structural Checks ---

if [[ "$AGENT_PATH" != *.md ]]; then
  echo "ERROR: Subagent file must have .md extension" >&2
  ERRORS=$((ERRORS + 1))
fi

# Filename naming (lowercase + hyphens)
if echo "$AGENT_NAME" | grep -qE '[A-Z ]'; then
  echo "WARNING: Agent filename should use lowercase-with-hyphens (got: $AGENT_NAME)" >&2
  WARNINGS=$((WARNINGS + 1))
fi

# Frontmatter delimiters
if ! head -1 "$AGENT_PATH" | grep -q '^---$'; then
  echo "ERROR: Missing opening frontmatter delimiter (---)" >&2
  ERRORS=$((ERRORS + 1))
fi

FRONTMATTER_END=$(awk '/^---$/{n++; if(n==2){print NR; exit}}' "$AGENT_PATH")
if [ -z "$FRONTMATTER_END" ]; then
  echo "ERROR: Missing closing frontmatter delimiter (---)" >&2
  ERRORS=$((ERRORS + 1))
fi

# --- Required Fields ---

# name field
NAME_VAL=$(grep -m1 '^name:' "$AGENT_PATH" 2>/dev/null | sed 's/^name: *//' | tr -d '"'"'"'' || true)
if [ -z "$NAME_VAL" ]; then
  echo "ERROR: Missing required 'name' field in frontmatter" >&2
  ERRORS=$((ERRORS + 1))
else
  if echo "$NAME_VAL" | grep -qE '[A-Z _]'; then
    echo "WARNING: name field should use lowercase-with-hyphens (got: $NAME_VAL)" >&2
    WARNINGS=$((WARNINGS + 1))
  fi
  if [ "$NAME_VAL" != "$AGENT_NAME" ]; then
    echo "WARNING: name field ($NAME_VAL) does not match filename ($AGENT_NAME)" >&2
    WARNINGS=$((WARNINGS + 1))
  fi
fi

# description field
DESC_LINE=$(grep -n '^description:' "$AGENT_PATH" 2>/dev/null | head -1 | cut -d: -f1 || true)
if [ -z "$DESC_LINE" ]; then
  echo "ERROR: Missing required 'description' field in frontmatter" >&2
  ERRORS=$((ERRORS + 1))
else
  DESC=$(awk -v start="$DESC_LINE" '
    NR==start { sub(/^description: */, ""); desc=$0; next }
    NR>start && /^  / { sub(/^  /, ""); desc=desc " " $0; next }
    NR>start { exit }
    END { print desc }
  ' "$AGENT_PATH")

  if ! echo "$DESC" | grep -qiE '(use when|use for|use proactively|invoke)'; then
    echo "WARNING: Description may be missing trigger phrases" >&2
    WARNINGS=$((WARNINGS + 1))
  fi

  if ! echo "$DESC" | grep -qiE '(do not use|don.t use|not for)'; then
    echo "WARNING: Description missing scope boundary (WHEN NOT to use)" >&2
    WARNINGS=$((WARNINGS + 1))
  fi
fi

# --- System Prompt Body ---

if [ -n "$FRONTMATTER_END" ]; then
  BODY_WORDS=$(tail -n +"$FRONTMATTER_END" "$AGENT_PATH" | tail -n +2 | wc -w)

  if [ "$BODY_WORDS" -lt 20 ]; then
    echo "WARNING: System prompt body is very short ($BODY_WORDS words). Subagents need enough context to operate independently." >&2
    WARNINGS=$((WARNINGS + 1))
  fi
fi

# --- Configuration Checks ---

# model field
MODEL_VAL=$(grep -m1 '^model:' "$AGENT_PATH" 2>/dev/null | sed 's/^model: *//' | tr -d '"'"'"'' || true)
if [ -n "$MODEL_VAL" ]; then
  case "$MODEL_VAL" in
    sonnet|opus|haiku|inherit) ;;
    *)
      echo "WARNING: Unusual model value '$MODEL_VAL'. Expected: sonnet, opus, haiku, or inherit" >&2
      WARNINGS=$((WARNINGS + 1))
      ;;
  esac
fi

# bypassPermissions check
if grep -q 'permissionMode.*bypassPermissions' "$AGENT_PATH"; then
  echo "WARNING: bypassPermissions is set. Ensure this is intentional and sandboxed." >&2
  WARNINGS=$((WARNINGS + 1))
fi

# Tool scope check
TOOLS_VAL=$(grep -m1 '^tools:' "$AGENT_PATH" 2>/dev/null | sed 's/^tools: *//' || true)
if [ -z "$TOOLS_VAL" ]; then
  # Check if description suggests read-only intent
  if echo "${DESC:-}" | grep -qiE '(review|analyze|scan|explore|research|read)' && \
     ! echo "${DESC:-}" | grep -qiE '(fix|implement|create|write|modify|update|edit)'; then
    echo "WARNING: Agent description suggests read-only purpose but no 'tools' field set (inherits all). Consider restricting tools." >&2
    WARNINGS=$((WARNINGS + 1))
  fi
else
  if echo "${DESC:-}" | grep -qiE '(review|analyze|scan|audit|check)' && \
     ! echo "${DESC:-}" | grep -qiE '(fix|implement|create|write|modify|update)'; then
    if echo "$TOOLS_VAL" | grep -qiE '(Write|Edit)'; then
      echo "WARNING: Agent appears to be a reviewer/analyzer but has Write/Edit tools. Consider removing them." >&2
      WARNINGS=$((WARNINGS + 1))
    fi
  fi
fi

# --- Codebase Specificity ---

TOTAL_LINES=$(wc -l < "$AGENT_PATH")
WORD_COUNT=$(wc -w < "$AGENT_PATH")
PATH_REFS=$(grep -cE '(`[a-zA-Z_./]+/[a-zA-Z_.]+`|apps/|packages/|src/|backend/|frontend/|scripts/|lib/|\.claude/)' "$AGENT_PATH" 2>/dev/null || true)
PATH_REFS=${PATH_REFS:-0}

echo "Size: $TOTAL_LINES lines, ~$WORD_COUNT words (~$(( WORD_COUNT * 13 / 10 )) tokens est.)"
echo "Codebase-specific references: $PATH_REFS"

if [ "$PATH_REFS" -lt 3 ]; then
  echo "WARNING: Fewer than 3 codebase-specific references. Agent may be too generic." >&2
  WARNINGS=$((WARNINGS + 1))
fi

# Generic phrases
GENERIC_COUNT=$(grep -ciE '(best practice|clean code|solid principle|meaningful name|descriptive variable|proper error handling|industry standard|well-structured|production.ready)' "$AGENT_PATH" 2>/dev/null || true)
GENERIC_COUNT=${GENERIC_COUNT:-0}
if [ "$GENERIC_COUNT" -gt 2 ]; then
  echo "WARNING: Found $GENERIC_COUNT generic programming phrases. System prompt may not be codebase-specific enough." >&2
  WARNINGS=$((WARNINGS + 1))
fi

# Overlap with built-in agents
if [ -n "$FRONTMATTER_END" ]; then
  BODY_LOWER=$(tail -n +"$FRONTMATTER_END" "$AGENT_PATH" | tr '[:upper:]' '[:lower:]')

  if echo "$BODY_LOWER" | grep -qE '(search|scan|find files|explore|discover)' && \
     ! echo "$BODY_LOWER" | grep -qE '(apps/|packages/|src/|backend/|specific)'; then
    echo "WARNING: Agent may overlap with built-in Explore agent. Ensure it adds codebase-specific knowledge." >&2
    WARNINGS=$((WARNINGS + 1))
  fi
fi

# --- Summary ---

echo ""
echo "=== Results ==="
echo "Errors:   $ERRORS"
echo "Warnings: $WARNINGS"

if [ "$ERRORS" -gt 0 ]; then
  echo "VERDICT: FAIL — fix $ERRORS error(s)" >&2
  exit 1
elif [ "$WARNINGS" -gt 4 ]; then
  echo "VERDICT: NEEDS REVISION — address warnings to improve quality" >&2
  exit 0
else
  echo "VERDICT: PASS"
  exit 0
fi
