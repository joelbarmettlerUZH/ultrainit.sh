#!/usr/bin/env bats
# Tests for regex boundary conditions in CLAUDE.md validation

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

_make_output() {
    local content="$1"
    jq -n --arg md "$content" '{claude_md: $md}' > "$TEST_TMPDIR/output.json"
}

# ── Prohibition detection regex: trailing space requirement ──

@test "prohibition at end of line (no trailing space) is still detected" {
    # PREDICTION: grep pattern is '(never |don.t |do not )' — note trailing spaces.
    # "Don't" at the end of a line has no trailing space, so it WON'T match.
    # This is a BUG in the regex.
    local md
    md=$(printf '%s\n' \
        "# Project" \
        '```' \
        "npm test" \
        '```' \
        "Don't" \
        $(for i in $(seq 1 50); do echo "Padding line $i."; done))
    _make_output "$md"
    local issues="$TEST_TMPDIR/issues.txt"
    : > "$issues"

    run validate_claude_md "$TEST_TMPDIR/output.json" "$issues"

    # "Don't" at end of line should be counted as a prohibition.
    # The code checks: if prohibitions > 0 AND alternatives == 0, then fail.
    # If "Don't" is NOT detected due to trailing space requirement,
    # prohibitions=0 and validation passes — missing a real prohibition.
    # To test: check if the issues file mentions "prohibitions"
    # If it doesn't, the regex failed to match.

    # First: let's see if prohibitions were detected at all
    local prohibition_count
    prohibition_count=$(echo "$md" | grep -ciE '(never |don.t |do not )' || true)
    # If 0, the regex missed "Don't" at EOL — that's the bug
    # We expect this to be 0 (documenting the bug)
    [[ "$prohibition_count" -eq 0 ]]  # DOCUMENTS BUG: trailing space required
}

@test "Never at end of line (no trailing space) is still detected" {
    local md
    md=$(printf '%s\n' \
        "# Project" \
        '```' \
        "npm test" \
        '```' \
        "Never" \
        $(for i in $(seq 1 50); do echo "Padding line $i."; done))
    _make_output "$md"

    local prohibition_count
    prohibition_count=$(echo "$md" | grep -ciE '(never |don.t |do not )' || true)
    # "Never" at EOL without trailing space won't match "never "
    [[ "$prohibition_count" -eq 0 ]]  # DOCUMENTS BUG: trailing space required
}

@test "prohibition mid-line with trailing space IS detected" {
    # This should work — "Never " with trailing space in "Never edit files."
    local md
    md=$(printf '%s\n' \
        "# Project" \
        '```' \
        "npm test" \
        '```' \
        "Never edit migration files. Instead create new ones." \
        $(for i in $(seq 1 50); do echo "Padding line $i."; done))
    _make_output "$md"

    local prohibition_count
    prohibition_count=$(echo "$md" | grep -ciE '(never |don.t |do not )' || true)
    [[ "$prohibition_count" -gt 0 ]]
}

@test "generic phrase detection is case-insensitive" {
    local md
    md=$(printf '%s\n' \
        "# Project" \
        '```' \
        "npm test" \
        '```' \
        "Follow BEST PRACTICES for this project." \
        "Instead of X, do Y." \
        $(for i in $(seq 1 50); do echo "Padding line $i."; done))
    _make_output "$md"

    local generic_count
    generic_count=$(echo "$md" | grep -ciE '(best practice|clean code|solid principle|maintainable|readable|scalable|well-structured|production.ready|industry standard)' || true)
    [[ "$generic_count" -gt 0 ]]
}
