#!/usr/bin/env bats

setup() {
    load '../helpers/test_helper'
    _common_setup
    load '../helpers/mock_claude'
    setup_mock_claude

    # Create a minimal valid schema file
    echo '{"type":"object","properties":{"name":{"type":"string"}}}' > "$TEST_TMPDIR/schema.json"

    # Create a default successful mock response
    export MOCK_CLAUDE_RESPONSE="$TEST_TMPDIR/response.json"
    make_claude_envelope '{"name":"test-result"}' "0.42" > "$MOCK_CLAUDE_RESPONSE"
}

teardown() {
    _common_teardown
}

# ── @file prompt support ────────────────────────────────────────

@test "run_agent reads prompt from @file" {
    echo "Analyze this codebase thoroughly" > "$TEST_TMPDIR/prompt.txt"
    run_agent "file-prompt" "@$TEST_TMPDIR/prompt.txt" "$TEST_TMPDIR/schema.json" "Read"
    assert_file_exists "$WORK_DIR/findings/file-prompt.json"
    run jq -r '.name' "$WORK_DIR/findings/file-prompt.json"
    assert_output "test-result"
    # Verify the prompt content reached claude
    run cat "$MOCK_CLAUDE_LOG"
    assert_output --partial "Analyze this codebase thoroughly"
}

@test "run_agent fails gracefully on missing prompt file" {
    run run_agent "missing-file" "@/nonexistent/path/prompt.txt" "$TEST_TMPDIR/schema.json" "Read"
    assert_failure
    assert_output --partial "Prompt file not found"
    assert_file_not_exists "$WORK_DIR/findings/missing-file.json"
}

@test "run_agent @file with apostrophes in prompt" {
    cat > "$TEST_TMPDIR/prompt.txt" <<'PROMPT'
Analyze this project. It's important that you don't skip the auth module.
The team won't accept changes that aren't tested.
PROMPT
    run_agent "apostrophe-test" "@$TEST_TMPDIR/prompt.txt" "$TEST_TMPDIR/schema.json" "Read"
    assert_file_exists "$WORK_DIR/findings/apostrophe-test.json"
    # Verify the apostrophes survived
    run cat "$MOCK_CLAUDE_LOG"
    assert_output --partial "don't skip"
    assert_output --partial "won't accept"
}

@test "run_agent @file with parentheses in prompt" {
    cat > "$TEST_TMPDIR/prompt.txt" <<'PROMPT'
Analyze this tool (CLAUDE.md, skills, hooks, subagents, MCP config) and
check the deployment target (Docker, Kubernetes).
PROMPT
    run_agent "parens-test" "@$TEST_TMPDIR/prompt.txt" "$TEST_TMPDIR/schema.json" "Read"
    assert_file_exists "$WORK_DIR/findings/parens-test.json"
    run cat "$MOCK_CLAUDE_LOG"
    assert_output --partial "(CLAUDE.md, skills, hooks, subagents, MCP config)"
}

@test "run_agent @file with backticks in prompt" {
    cat > "$TEST_TMPDIR/prompt.txt" <<'PROMPT'
Run `git log` and check `npm test` output.
PROMPT
    run_agent "backtick-test" "@$TEST_TMPDIR/prompt.txt" "$TEST_TMPDIR/schema.json" "Read"
    assert_file_exists "$WORK_DIR/findings/backtick-test.json"
    run cat "$MOCK_CLAUDE_LOG"
    assert_output --partial '`git log`'
}

@test "run_agent @file with dollar signs in prompt" {
    cat > "$TEST_TMPDIR/prompt.txt" <<'PROMPT'
Check $HOME and $(whoami) and ${PATH} variables.
PROMPT
    run_agent "dollar-test" "@$TEST_TMPDIR/prompt.txt" "$TEST_TMPDIR/schema.json" "Read"
    assert_file_exists "$WORK_DIR/findings/dollar-test.json"
    # Dollar signs must be literal, not expanded
    run cat "$MOCK_CLAUDE_LOG"
    assert_output --partial '$HOME'
    assert_output --partial '$(whoami)'
}

@test "run_agent @file with mixed special characters" {
    cat > "$TEST_TMPDIR/prompt.txt" <<'PROMPT'
Don't run $(rm -rf /) or check `git log` for files (a, b).
Also watch for $HOME and "quoted strings" with 'single quotes'.
PROMPT
    run_agent "mixed-test" "@$TEST_TMPDIR/prompt.txt" "$TEST_TMPDIR/schema.json" "Read"
    assert_file_exists "$WORK_DIR/findings/mixed-test.json"
    run cat "$MOCK_CLAUDE_LOG"
    assert_output --partial "Don't run"
    assert_output --partial "(a, b)"
}

@test "run_agent @file with newlines in prompt" {
    printf 'Line 1\nLine 2\nLine 3\n' > "$TEST_TMPDIR/prompt.txt"
    run_agent "newline-test" "@$TEST_TMPDIR/prompt.txt" "$TEST_TMPDIR/schema.json" "Read"
    assert_file_exists "$WORK_DIR/findings/newline-test.json"
}

@test "run_agent @file works with large prompts (stdin path)" {
    # Create a prompt file > 100KB
    dd if=/dev/zero bs=1 count=110000 2>/dev/null | tr '\0' 'x' > "$TEST_TMPDIR/large_prompt.txt"
    run_agent "large-file-test" "@$TEST_TMPDIR/large_prompt.txt" "$TEST_TMPDIR/schema.json" "Read"
    assert_file_exists "$WORK_DIR/findings/large-file-test.json"
    # Should have used stdin for the large prompt
    run cat "$MOCK_CLAUDE_LOG"
    assert_output --partial "STDIN:"
    assert_output --partial " -p -"
}

@test "run_agent still works with inline prompts (backward compat)" {
    run_agent "inline-test" "Analyze this project" "$TEST_TMPDIR/schema.json" "Read"
    assert_file_exists "$WORK_DIR/findings/inline-test.json"
    run cat "$MOCK_CLAUDE_LOG"
    assert_output --partial "Analyze this project"
}
