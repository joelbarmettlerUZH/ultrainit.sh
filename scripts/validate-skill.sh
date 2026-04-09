#!/usr/bin/env bash
# validate-skill.sh — Quality check for a SKILL.md file
# Usage: bash scripts/validate-skill.sh path/to/SKILL.md
set -euo pipefail

SKILL_PATH="${1:?Usage: validate-skill.sh <path-to-SKILL.md>}"
ERRORS=0
WARNINGS=0

if [ ! -f "$SKILL_PATH" ]; then
  echo "ERROR: File not found: $SKILL_PATH" >&2
  exit 1
fi

SKILL_DIR=$(dirname "$SKILL_PATH")
SKILL_NAME=$(basename "$SKILL_DIR")

echo "=== Validating skill: $SKILL_NAME ==="
echo ""

# --- Structural Checks ---

BASENAME=$(basename "$SKILL_PATH")
if [ "$BASENAME" != "SKILL.md" ]; then
  echo "ERROR: File must be named SKILL.md (got: $BASENAME)" >&2
  ERRORS=$((ERRORS + 1))
fi

# Folder naming (kebab-case)
if echo "$SKILL_NAME" | grep -qE '[A-Z _]'; then
  echo "ERROR: Folder name must be kebab-case (got: $SKILL_NAME)" >&2
  ERRORS=$((ERRORS + 1))
fi

# Frontmatter delimiters
if ! head -1 "$SKILL_PATH" | grep -q '^---$'; then
  echo "ERROR: Missing opening frontmatter delimiter (---)" >&2
  ERRORS=$((ERRORS + 1))
fi

FRONTMATTER_END=$(awk '/^---$/{n++; if(n==2){print NR; exit}}' "$SKILL_PATH")
if [ -z "$FRONTMATTER_END" ]; then
  echo "ERROR: Missing closing frontmatter delimiter (---)" >&2
  ERRORS=$((ERRORS + 1))
fi

# --- Frontmatter Field Checks ---

# name field
NAME_VAL=$(grep -m1 '^name:' "$SKILL_PATH" 2>/dev/null | sed 's/^name: *//' | tr -d '"'"'"'' || true)
if [ -z "$NAME_VAL" ]; then
  echo "ERROR: Missing required 'name' field in frontmatter" >&2
  ERRORS=$((ERRORS + 1))
elif [ "$NAME_VAL" != "$SKILL_NAME" ]; then
  echo "WARNING: name field ($NAME_VAL) does not match folder name ($SKILL_NAME)" >&2
  WARNINGS=$((WARNINGS + 1))
fi

# description field
DESC_LINE=$(grep -n '^description:' "$SKILL_PATH" 2>/dev/null | head -1 | cut -d: -f1 || true)
if [ -z "$DESC_LINE" ]; then
  echo "ERROR: Missing required 'description' field in frontmatter" >&2
  ERRORS=$((ERRORS + 1))
else
  DESC=$(awk -v start="$DESC_LINE" '
    NR==start { sub(/^description: */, ""); sub(/^[>|]-? *$/, ""); desc=$0; next }
    NR>start && /^  / { sub(/^  /, ""); desc=desc " " $0; next }
    NR>start { exit }
    END { print desc }
  ' "$SKILL_PATH")

  DESC_LEN=${#DESC}
  if [ "$DESC_LEN" -gt 1024 ]; then
    echo "ERROR: Description exceeds 1024 characters ($DESC_LEN chars)" >&2
    ERRORS=$((ERRORS + 1))
  fi

  # Trigger phrases
  if ! echo "$DESC" | grep -qiE '(use when|use for|trigger|invoke)'; then
    echo "WARNING: Description may be missing trigger phrases (WHEN to use)" >&2
    WARNINGS=$((WARNINGS + 1))
  fi

  # Negative scope
  if ! echo "$DESC" | grep -qiE '(do not use|don.t use|not for|instead use|do not trigger)'; then
    echo "WARNING: Description missing negative scope (WHEN NOT to use)" >&2
    WARNINGS=$((WARNINGS + 1))
  fi

  # XML angle brackets
  if echo "$DESC" | grep -qE '[<>]'; then
    echo "ERROR: Description contains XML angle brackets (< or >), which are forbidden" >&2
    ERRORS=$((ERRORS + 1))
  fi
fi

# --- Content Quality Checks ---

TOTAL_LINES=$(wc -l < "$SKILL_PATH")
WORD_COUNT=$(wc -w < "$SKILL_PATH")

echo "Size: $TOTAL_LINES lines, ~$WORD_COUNT words (~$(( WORD_COUNT * 13 / 10 )) tokens est.)"

if [ "$TOTAL_LINES" -gt 600 ]; then
  echo "WARNING: Skill is $TOTAL_LINES lines — consider splitting into multiple skills or moving reference material to a separate file" >&2
  WARNINGS=$((WARNINGS + 1))
fi

# Codebase-specific references: backtick-wrapped filenames (with or without path),
# or well-known directory names. Matches `app.py`, `src/routes.ts`, `tests/test_app.py`, etc.
PATH_REFS=$(grep -cE '(`[a-zA-Z_./-]+\.[a-zA-Z]+`|`[a-zA-Z_./]+/[a-zA-Z_.]+`|apps/|packages/|src/|backend/|frontend/|scripts/|lib/|tests/)' "$SKILL_PATH" 2>/dev/null || true)
PATH_REFS=${PATH_REFS:-0}
echo "Codebase-specific path references: $PATH_REFS"

if [ "$PATH_REFS" -lt 3 ]; then
  echo "ERROR: Fewer than 3 codebase-specific references. Skill is too generic." >&2
  ERRORS=$((ERRORS + 1))
fi

# Verification step
if ! grep -qiE '(verif|## verify|## check|## test|## validate|## confirm)' "$SKILL_PATH"; then
  echo "WARNING: No verification section found. Skills should end with a concrete check." >&2
  WARNINGS=$((WARNINGS + 1))
fi

# Generic phrases
GENERIC_COUNT=$(grep -ciE '(best practice|clean code|solid principle|meaningful name|descriptive variable|proper error handling|well-structured|maintainable|readable code|industry standard|production.ready)' "$SKILL_PATH" 2>/dev/null || true)
GENERIC_COUNT=${GENERIC_COUNT:-0}
if [ "$GENERIC_COUNT" -gt 2 ]; then
  echo "WARNING: Found $GENERIC_COUNT generic programming phrases. Skill may not be codebase-specific enough." >&2
  WARNINGS=$((WARNINGS + 1))
fi

# --- Summary ---

echo ""
echo "=== Results ==="
echo "Errors:   $ERRORS"
echo "Warnings: $WARNINGS"

if [ "$ERRORS" -gt 0 ]; then
  echo "VERDICT: FAIL — fix $ERRORS error(s)" >&2
  exit 1
elif [ "$WARNINGS" -gt 3 ]; then
  echo "VERDICT: NEEDS REVISION — address warnings to improve quality" >&2
  exit 0
else
  echo "VERDICT: PASS"
  exit 0
fi
