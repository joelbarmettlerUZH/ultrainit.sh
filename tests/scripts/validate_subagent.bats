#!/usr/bin/env bats

setup() {
    load '../helpers/test_helper'
    _common_setup
}

teardown() {
    _common_teardown
}

@test "valid subagent passes" {
    run bash "$PROJECT_ROOT/scripts/validate-subagent.sh" "$PROJECT_ROOT/tests/fixtures/subagents/valid-subagent.md"
    assert_success
    assert_output --partial "VERDICT: PASS"
}

@test "missing frontmatter fails" {
    run bash "$PROJECT_ROOT/scripts/validate-subagent.sh" "$PROJECT_ROOT/tests/fixtures/subagents/invalid-subagent.md"
    assert_failure
    assert_output --partial "ERROR"
}

@test "nonexistent file fails" {
    run bash "$PROJECT_ROOT/scripts/validate-subagent.sh" "$TEST_TMPDIR/nonexistent.md"
    assert_failure
}

@test "missing name field fails" {
    cat > "$TEST_TMPDIR/no-name.md" <<'EOF'
---
description: A subagent without a name. Use when reviewing. Do NOT use for writing.
---

Agent body here with enough words to pass length check.
References to `src/api/routes.ts` and `src/api/middleware.ts`
and also `src/repos/` for good measure.
EOF
    run bash "$PROJECT_ROOT/scripts/validate-subagent.sh" "$TEST_TMPDIR/no-name.md"
    assert_failure
    assert_output --partial "name"
}

@test "uppercase filename warns" {
    cat > "$TEST_TMPDIR/MyAgent.md" <<'EOF'
---
name: my-agent
description: Use when reviewing code. Do NOT use for writing new code.
---

Agent that reviews code for quality.
Check `src/api/routes.ts` and `src/api/middleware.ts`
and also `src/repos/` for data access patterns.
EOF
    run bash "$PROJECT_ROOT/scripts/validate-subagent.sh" "$TEST_TMPDIR/MyAgent.md"
    assert_output --partial "lowercase"
}
