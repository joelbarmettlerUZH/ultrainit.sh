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

# Helper: create output.json with a hook at given index
_make_hook_output() {
    local content="$1"
    local filename="${2:-test-hook.sh}"
    jq -n \
        --arg c "$content" \
        --arg f "$filename" \
        '{hooks: [{filename: $f, content: $c}]}' > "$TEST_TMPDIR/output.json"
}

@test "validate_hook passes valid hook" {
    _make_hook_output '#!/usr/bin/env bash
set -euo pipefail
INPUT=$(cat)
FILE=$(echo "$INPUT" | jq -r ".tool_input.file_path // empty")
exit 0'
    local issues="$TEST_TMPDIR/issues.txt"
    : > "$issues"
    run validate_hook "$TEST_TMPDIR/output.json" 0 "$issues"
    assert_success
}

@test "validate_hook fails missing shebang" {
    _make_hook_output 'set -euo pipefail
INPUT=$(cat)
exit 0'
    local issues="$TEST_TMPDIR/issues.txt"
    : > "$issues"
    run validate_hook "$TEST_TMPDIR/output.json" 0 "$issues"
    assert_failure
    run cat "$issues"
    assert_output --partial "shebang"
}

@test "validate_hook fails missing pipefail" {
    _make_hook_output '#!/usr/bin/env bash
INPUT=$(cat)
exit 0'
    local issues="$TEST_TMPDIR/issues.txt"
    : > "$issues"
    run validate_hook "$TEST_TMPDIR/output.json" 0 "$issues"
    assert_failure
    run cat "$issues"
    assert_output --partial "pipefail"
}

@test "validate_hook fails no stdin reading" {
    _make_hook_output '#!/usr/bin/env bash
set -euo pipefail
echo "hello world"
exit 0'
    local issues="$TEST_TMPDIR/issues.txt"
    : > "$issues"
    run validate_hook "$TEST_TMPDIR/output.json" 0 "$issues"
    assert_failure
    run cat "$issues"
    assert_output --partial "stdin"
}

@test "validate_hook passes hook using jq for stdin" {
    _make_hook_output '#!/usr/bin/env bash
set -euo pipefail
FILE=$(jq -r ".tool_input.file_path // empty")
exit 0'
    local issues="$TEST_TMPDIR/issues.txt"
    : > "$issues"
    run validate_hook "$TEST_TMPDIR/output.json" 0 "$issues"
    assert_success
}

@test "validate_hook passes hook using read for stdin" {
    _make_hook_output '#!/usr/bin/env bash
set -euo pipefail
read -r line
echo "$line"
exit 0'
    local issues="$TEST_TMPDIR/issues.txt"
    : > "$issues"
    run validate_hook "$TEST_TMPDIR/output.json" 0 "$issues"
    assert_success
}

@test "validate_hook passes hook reading /dev/stdin" {
    _make_hook_output '#!/usr/bin/env bash
set -euo pipefail
INPUT=$(cat < /dev/stdin)
exit 0'
    local issues="$TEST_TMPDIR/issues.txt"
    : > "$issues"
    run validate_hook "$TEST_TMPDIR/output.json" 0 "$issues"
    assert_success
}

@test "validate_hook fails blocking without error message" {
    _make_hook_output '#!/usr/bin/env bash
set -euo pipefail
INPUT=$(cat)
exit 2'
    local issues="$TEST_TMPDIR/issues.txt"
    : > "$issues"
    run validate_hook "$TEST_TMPDIR/output.json" 0 "$issues"
    assert_failure
    run cat "$issues"
    assert_output --partial "blocking"
}

# ── validate_hook_wiring ─────────────────────────────────────

@test "validate_hook_wiring passes with matching counts" {
    jq -n '{hooks: [{filename: "a.sh"}], settings_hooks: [{event: "PostToolUse"}]}' > "$TEST_TMPDIR/output.json"
    local issues="$TEST_TMPDIR/issues.txt"
    : > "$issues"
    run validate_hook_wiring "$TEST_TMPDIR/output.json" "$issues"
    assert_success
}

@test "validate_hook_wiring fails hooks without wiring" {
    jq -n '{hooks: [{filename: "a.sh"}, {filename: "b.sh"}], settings_hooks: []}' > "$TEST_TMPDIR/output.json"
    local issues="$TEST_TMPDIR/issues.txt"
    : > "$issues"
    run validate_hook_wiring "$TEST_TMPDIR/output.json" "$issues"
    assert_failure
    run cat "$issues"
    assert_output --partial "no settings_hooks wiring"
}

@test "validate_hook_wiring passes with no hooks" {
    jq -n '{hooks: [], settings_hooks: []}' > "$TEST_TMPDIR/output.json"
    local issues="$TEST_TMPDIR/issues.txt"
    : > "$issues"
    run validate_hook_wiring "$TEST_TMPDIR/output.json" "$issues"
    assert_success
}
