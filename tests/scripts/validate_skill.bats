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

@test "nonexistent file fails" {
    run bash "$PROJECT_ROOT/scripts/validate-skill.sh" "$TEST_TMPDIR/nonexistent.md"
    assert_failure
}
