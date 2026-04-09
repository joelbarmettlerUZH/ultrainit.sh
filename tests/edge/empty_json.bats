#!/usr/bin/env bats
# Tests for null/missing JSON keys in synthesis output

setup() {
    load '../helpers/test_helper'
    _common_setup
    source_lib 'utils.sh'
    source_lib 'config.sh'
    source_lib 'validate.sh'
    source_lib 'merge.sh'
    source_lib 'synthesize.sh'

    cd "$TARGET_DIR"
}

teardown() {
    _common_teardown
}

# ── validate_claude_md with null/missing content ─────────────

@test "validate_claude_md handles null .claude_md gracefully" {
    # PREDICTION: jq -r '.claude_md' on {"other":"x"} returns "null" string.
    # wc -l on "null" = 1 line. Validation says "too thin" but doesn't crash.
    # The real issue: "null" isn't empty — it's a 4-char string treated as content.
    jq -n '{other: "x"}' > "$TEST_TMPDIR/output.json"
    local issues="$TEST_TMPDIR/issues.txt"
    : > "$issues"

    run validate_claude_md "$TEST_TMPDIR/output.json" "$issues"

    # Should fail validation (content is "null", not real CLAUDE.md)
    assert_failure
    # Should mention "too thin" not crash with an error
    run cat "$issues"
    assert_output --partial "too thin"
}

@test "validate_claude_md handles explicit null value" {
    jq -n '{claude_md: null}' > "$TEST_TMPDIR/output.json"
    local issues="$TEST_TMPDIR/issues.txt"
    : > "$issues"

    run validate_claude_md "$TEST_TMPDIR/output.json" "$issues"
    assert_failure
}

# ── write_artifacts with null skill names ────────────────────

@test "write_artifacts skips skills with null name" {
    jq -n '{
        claude_md: "# Test\n",
        subdirectory_claude_mds: [],
        skills: [{"name": null, "description": "broken", "content": "---\nname: broken\n---\nBody"}],
        hooks: [],
        subagents: [],
        mcp_servers: [],
        settings_hooks: []
    }' > "$WORK_DIR/synthesis/output.json"
    DRY_RUN="false"

    run write_artifacts
    assert_success

    # A directory literally named "null" should NOT exist
    [[ ! -d ".claude/skills/null" ]]
}

@test "write_artifacts handles empty skills array" {
    jq -n '{
        claude_md: "# Test\n",
        subdirectory_claude_mds: [],
        skills: [],
        hooks: [],
        subagents: [],
        mcp_servers: [],
        settings_hooks: []
    }' > "$WORK_DIR/synthesis/output.json"
    DRY_RUN="false"

    run write_artifacts
    assert_success
    # CLAUDE.md should still be written
    [[ -f "CLAUDE.md" ]]
}

# ── merge_settings with null event ───────────────────────────

@test "merge_settings skips hook entries with null event" {
    jq -n '{settings_hooks: [
        {event: null, command: ".claude/hooks/broken.sh"}
    ]}' > "$TEST_TMPDIR/output.json"

    run merge_settings "$TEST_TMPDIR/output.json"
    assert_success

    # No settings.json should be created (all entries were skipped)
    [[ ! -f .claude/settings.json ]]
}

# ── build_docs_context with empty/invalid findings ───────────

@test "build_docs_context survives 0-byte findings file" {
    touch "$WORK_DIR/findings/identity.json"  # 0 bytes
    cp "$PROJECT_ROOT/tests/fixtures/findings/commands.json" "$WORK_DIR/findings/"

    local ctx="$TEST_TMPDIR/context.txt"
    run build_docs_context "$ctx"
    assert_success
    [[ -f "$ctx" ]]
}

@test "build_docs_context survives invalid JSON in findings file" {
    echo "not valid json {{{" > "$WORK_DIR/findings/identity.json"
    cp "$PROJECT_ROOT/tests/fixtures/findings/commands.json" "$WORK_DIR/findings/"

    local ctx="$TEST_TMPDIR/context.txt"
    run build_docs_context "$ctx"
    assert_success
    # Commands should still be present even though identity was garbage
    run cat "$ctx"
    assert_output --partial "COMMANDS"
}
