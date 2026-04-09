#!/usr/bin/env bats

setup() {
    load '../helpers/test_helper'
    _common_setup
    source_lib 'utils.sh'
    source_lib 'config.sh'
    source_lib 'validate.sh'
}

teardown() {
    _common_teardown
}

# Helper: create an output.json with given CLAUDE.md content
_make_output() {
    local content="$1"
    jq -n --arg md "$content" '{claude_md: $md}' > "$TEST_TMPDIR/output.json"
}

@test "validate_claude_md passes good content" {
    local good_md
    good_md=$(printf '%s\n' \
        "# Project Name" \
        "" \
        "## Overview" \
        "A task management app." \
        "" \
        "## Commands" \
        "" \
        '```bash' \
        "npm test" \
        '```' \
        "" \
        "## Architecture" \
        "Uses repository pattern." \
        "" \
        "## Rules" \
        "- Never edit migrations directly. Instead, create a new migration." \
        "" \
        $(for i in $(seq 1 40); do echo "Line $i of real content about the codebase."; done))
    _make_output "$good_md"
    local issues="$TEST_TMPDIR/issues.txt"
    : > "$issues"
    run validate_claude_md "$TEST_TMPDIR/output.json" "$issues"
    assert_success
}

@test "validate_claude_md fails on short content" {
    _make_output "# Short\n\nToo few lines."
    local issues="$TEST_TMPDIR/issues.txt"
    : > "$issues"
    run validate_claude_md "$TEST_TMPDIR/output.json" "$issues"
    assert_failure
    run cat "$issues"
    assert_output --partial "too thin"
}

@test "validate_claude_md detects generic phrases" {
    local generic_md
    generic_md=$(printf '%s\n' \
        "# Project" \
        "Follow best practices for clean code." \
        "Ensure SOLID principles are followed." \
        '```bash' \
        "npm test" \
        '```' \
        "Never do X. Instead, do Y." \
        $(for i in $(seq 1 50); do echo "Content line $i."; done))
    _make_output "$generic_md"
    local issues="$TEST_TMPDIR/issues.txt"
    : > "$issues"
    run validate_claude_md "$TEST_TMPDIR/output.json" "$issues"
    assert_failure
    run cat "$issues"
    assert_output --partial "generic phrases"
}

@test "validate_claude_md detects missing code blocks" {
    local plain_md
    plain_md=$(printf '%s\n' \
        "# Project" \
        "" \
        "No code blocks or tables anywhere in this document." \
        "Never edit migrations. Instead, create new ones." \
        $(for i in $(seq 1 50); do echo "More content for line count $i."; done))
    _make_output "$plain_md"
    local issues="$TEST_TMPDIR/issues.txt"
    : > "$issues"
    run validate_claude_md "$TEST_TMPDIR/output.json" "$issues"
    assert_failure
    run cat "$issues"
    assert_output --partial "no code blocks"
}

@test "validate_claude_md accepts markdown tables as code blocks" {
    local table_md
    table_md=$(printf '%s\n' \
        "# Project" \
        "" \
        "## Commands" \
        "" \
        "| Command | Purpose |" \
        "|---------|---------|" \
        "| npm test | Run tests |" \
        "| npm build | Build |" \
        "" \
        "Never edit migrations. Instead, create new ones." \
        $(for i in $(seq 1 40); do echo "Content line $i about real things."; done))
    _make_output "$table_md"
    local issues="$TEST_TMPDIR/issues.txt"
    : > "$issues"
    run validate_claude_md "$TEST_TMPDIR/output.json" "$issues"
    assert_success
}

@test "validate_claude_md accepts triple backtick code blocks" {
    local code_md
    code_md=$(printf '%s\n' \
        "# Project" \
        "" \
        '```' \
        "npm test" \
        '```' \
        "" \
        "Never edit migrations. Instead, create new ones." \
        $(for i in $(seq 1 45); do echo "Real content line $i."; done))
    _make_output "$code_md"
    local issues="$TEST_TMPDIR/issues.txt"
    : > "$issues"
    run validate_claude_md "$TEST_TMPDIR/output.json" "$issues"
    assert_success
}

@test "validate_claude_md detects prohibitions without alternatives" {
    local no_alt_md
    no_alt_md=$(printf '%s\n' \
        "# Project" \
        "" \
        '```bash' \
        "npm test" \
        '```' \
        "" \
        "Never edit migration files directly." \
        "Don't modify the auth module." \
        "Do not touch the CI config." \
        $(for i in $(seq 1 50); do echo "Padding line $i."; done))
    _make_output "$no_alt_md"
    local issues="$TEST_TMPDIR/issues.txt"
    : > "$issues"
    run validate_claude_md "$TEST_TMPDIR/output.json" "$issues"
    assert_failure
    run cat "$issues"
    assert_output --partial "prohibitions"
}
