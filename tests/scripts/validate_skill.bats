#!/usr/bin/env bats

setup() {
    load '../helpers/test_helper'
    _common_setup
}

teardown() {
    _common_teardown
}

@test "valid skill passes" {
    run bash "$PROJECT_ROOT/scripts/validate-skill.sh" "$PROJECT_ROOT/tests/fixtures/skills/valid-skill/SKILL.md"
    assert_success
    assert_output --partial "VERDICT: PASS"
}

@test "missing description field fails" {
    run bash "$PROJECT_ROOT/scripts/validate-skill.sh" "$PROJECT_ROOT/tests/fixtures/skills/invalid-skill-no-desc/SKILL.md"
    assert_failure
    assert_output --partial "ERROR: Missing required 'description' field"
}

@test "angle brackets in description fails" {
    run bash "$PROJECT_ROOT/scripts/validate-skill.sh" "$PROJECT_ROOT/tests/fixtures/skills/invalid-skill-angle-brackets/SKILL.md"
    assert_failure
    assert_output --partial "angle brackets"
}

@test "missing frontmatter fails" {
    local skill_dir="$TEST_TMPDIR/no-frontmatter"
    mkdir -p "$skill_dir"
    cat > "$skill_dir/SKILL.md" <<'EOF'
No frontmatter here, just content.
EOF
    run bash "$PROJECT_ROOT/scripts/validate-skill.sh" "$skill_dir/SKILL.md"
    assert_failure
    assert_output --partial "ERROR"
}

@test "uppercase folder name fails" {
    local skill_dir="$TEST_TMPDIR/MySkill"
    mkdir -p "$skill_dir"
    cat > "$skill_dir/SKILL.md" <<'EOF'
---
name: MySkill
description: A skill with uppercase name. Use when testing. Do NOT use for production.
---

# My Skill

Content here.

- `src/api/routes.ts`
- `src/api/middleware.ts`
- `src/api/controllers/`

## Verification
Check it.
EOF
    run bash "$PROJECT_ROOT/scripts/validate-skill.sh" "$skill_dir/SKILL.md"
    assert_failure
    assert_output --partial "kebab-case"
}

@test "fewer than 3 path refs fails" {
    local skill_dir="$TEST_TMPDIR/sparse-skill"
    mkdir -p "$skill_dir"
    cat > "$skill_dir/SKILL.md" <<'EOF'
---
name: sparse-skill
description: A skill that is too generic. Use when testing. Do NOT use for production.
---

# Sparse Skill

This skill has no codebase-specific references.
Just generic advice about how to write code.

## Verification
Check it.
EOF
    run bash "$PROJECT_ROOT/scripts/validate-skill.sh" "$skill_dir/SKILL.md"
    assert_failure
    assert_output --partial "Fewer than 3"
}

@test "description over 1024 chars fails" {
    local skill_dir="$TEST_TMPDIR/long-desc"
    mkdir -p "$skill_dir"
    local long_desc
    long_desc=$(printf 'x%.0s' $(seq 1 1100))
    cat > "$skill_dir/SKILL.md" <<EOF
---
name: long-desc
description: ${long_desc}
---

# Long Description Skill

- \`src/api/routes.ts\`
- \`src/api/middleware.ts\`
- \`src/api/controllers/\`

## Verification
Check it.
EOF
    run bash "$PROJECT_ROOT/scripts/validate-skill.sh" "$skill_dir/SKILL.md"
    assert_failure
    assert_output --partial "exceeds 1024"
}

@test "generic phrases trigger warning" {
    local skill_dir="$TEST_TMPDIR/generic-skill"
    mkdir -p "$skill_dir"
    cat > "$skill_dir/SKILL.md" <<'EOF'
---
name: generic-skill
description: Use when writing code. Do NOT use for deployment.
---

# Generic Skill

Follow best practices for clean code and SOLID principles.
Use meaningful names and proper error handling.
Write well-structured, maintainable, readable code.

- `src/api/routes.ts`
- `src/api/middleware.ts`
- `src/api/controllers/`

## Verification
Check it works.
EOF
    run bash "$PROJECT_ROOT/scripts/validate-skill.sh" "$skill_dir/SKILL.md"
    # May pass or warn depending on count, but should have warnings
    assert_output --partial "generic programming phrases"
}

@test "missing verification section warns" {
    local skill_dir="$TEST_TMPDIR/missing-section"
    mkdir -p "$skill_dir"
    cat > "$skill_dir/SKILL.md" <<'EOF'
---
name: missing-section
description: Use when building APIs. Do NOT use for frontend.
---

# My Skill

- `src/api/routes.ts`
- `src/api/middleware.ts`
- `src/api/controllers/`

## Workflow

Just do the thing and hope for the best.
EOF
    run bash "$PROJECT_ROOT/scripts/validate-skill.sh" "$skill_dir/SKILL.md"
    assert_output --partial "No verification section"
}

# ── Tests for patterns the synthesis agent actually generates ──

@test "skill with YAML folded scalar description passes" {
    local skill_dir="$TEST_TMPDIR/yaml-folded"
    mkdir -p "$skill_dir"
    cat > "$skill_dir/SKILL.md" <<'EOF'
---
name: yaml-folded
description: >
  Add a new Flask route handler to app.py following the existing CRUD pattern.
  Use when the user says "add an endpoint", "add a route", "create a new API method".
  Do NOT use for creating entirely new Flask application files.
---

## Before You Start

- `app.py` — existing route handlers
- `tests/test_app.py` — test patterns
- `requirements.txt` — pinned dependencies

## Verify

Run `python -m pytest tests/`
EOF
    run bash "$PROJECT_ROOT/scripts/validate-skill.sh" "$skill_dir/SKILL.md"
    assert_success
    assert_output --partial "VERDICT: PASS"
}

@test "skill with YAML literal scalar description passes" {
    local skill_dir="$TEST_TMPDIR/yaml-literal"
    mkdir -p "$skill_dir"
    cat > "$skill_dir/SKILL.md" <<'EOF'
---
name: yaml-literal
description: |
  Debug Flask endpoint issues in this project.
  Use when an API route returns unexpected status codes or data.
  Do NOT use for frontend or database migration issues.
---

## Key Files

- `app.py` — route handlers to inspect
- `tests/test_app.py` — reproduce issues with tests
- `requirements.txt` — check Flask version

## Verify

Run `python -m pytest tests/ -v`
EOF
    run bash "$PROJECT_ROOT/scripts/validate-skill.sh" "$skill_dir/SKILL.md"
    assert_success
    assert_output --partial "VERDICT: PASS"
}

@test "skill referencing only root-level files passes path check" {
    local skill_dir="$TEST_TMPDIR/root-files"
    mkdir -p "$skill_dir"
    cat > "$skill_dir/SKILL.md" <<'EOF'
---
name: root-files
description: Update project configuration files. Use when changing dependencies or settings. Do NOT use for code changes.
---

## Key Files

- `app.py` — main application entry point
- `requirements.txt` — Python dependencies
- `README.md` — project documentation

## Verify

Run `pip install -r requirements.txt`
EOF
    run bash "$PROJECT_ROOT/scripts/validate-skill.sh" "$skill_dir/SKILL.md"
    assert_success
    # Should detect 3 backtick-wrapped file references
    assert_output --partial "Codebase-specific path references: 3"
}

@test "skill with tests/ directory references passes" {
    local skill_dir="$TEST_TMPDIR/test-refs"
    mkdir -p "$skill_dir"
    cat > "$skill_dir/SKILL.md" <<'EOF'
---
name: test-refs
description: Add new test cases for API endpoints. Use when adding tests. Do NOT use for non-test code.
---

## Key Files

- `tests/test_app.py` — existing test patterns
- `tests/` directory for all test files
- `app.py` — the code under test

## Verify

Run `python -m pytest tests/ -v`
EOF
    run bash "$PROJECT_ROOT/scripts/validate-skill.sh" "$skill_dir/SKILL.md"
    assert_success
}

@test "skill with real angle brackets in description still fails" {
    local skill_dir="$TEST_TMPDIR/real-angles"
    mkdir -p "$skill_dir"
    cat > "$skill_dir/SKILL.md" <<'EOF'
---
name: real-angles
description: Use for <component> creation. Do NOT use for <other> things.
---

## Files

- `app.py`
- `tests/test_app.py`
- `requirements.txt`

## Verify

Check it.
EOF
    run bash "$PROJECT_ROOT/scripts/validate-skill.sh" "$skill_dir/SKILL.md"
    assert_failure
    assert_output --partial "angle brackets"
}

@test "nonexistent file fails" {
    run bash "$PROJECT_ROOT/scripts/validate-skill.sh" "$TEST_TMPDIR/nonexistent.md"
    assert_failure
}
