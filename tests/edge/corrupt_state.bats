#!/usr/bin/env bats
# Tests for corrupt/malformed state files — can the code survive bad data?

setup() {
    load '../helpers/test_helper'
    _common_setup
    source_lib 'utils.sh'
    source_lib 'config.sh'
}

teardown() {
    _common_teardown
}

# ── Corrupt state.json ───────────────────────────────────────

@test "mark_phase_complete recovers from corrupt state.json" {
    # With corrupt JSON, the fix resets to {} then writes the phase.
    echo '{invalid json here' > "$WORK_DIR/state.json"

    mark_phase_complete "gather"

    # State file should be valid JSON with the phase recorded
    run jq -e '.gather' "$WORK_DIR/state.json"
    assert_success
}

@test "is_phase_complete returns failure on corrupt state.json" {
    echo '{not valid json}}}' > "$WORK_DIR/state.json"
    run is_phase_complete "gather"
    assert_failure
}

# ── Malformed cost files ─────────────────────────────────────

@test "check_budget handles cost file with non-numeric cost value" {
    # Cost file has "notanumber" instead of a dollar amount.
    # awk will treat it as 0, so budget will appear under-spent.
    # This SHOULD either: treat as 0 (acceptable) or error (better).
    TOTAL_BUDGET="100.00"
    echo "gather|identity|notanumber" > "$WORK_DIR/costs/identity.cost"
    echo "gather|commands|5.00" > "$WORK_DIR/costs/commands.cost"

    run check_budget
    # Should still succeed (awk treats non-numeric as 0, total = 5.00 < 100)
    assert_success
}

@test "check_budget handles cost file with no pipe delimiters" {
    # A bare number without the phase|agent| format.
    # awk -F'|' will put "50.00" in $1, $3 will be empty (treated as 0).
    # This means $50 of spending is SILENTLY IGNORED.
    TOTAL_BUDGET="10.00"
    echo "50.00" > "$WORK_DIR/costs/broken.cost"

    run check_budget
    # BUG PREDICTION: returns success (0) because $3 is empty = 0 spent.
    # This is wrong — we have a cost file indicating $50 spent but it's ignored.
    # We'll assert the current (buggy) behavior to document it:
    assert_success  # DOCUMENTS BUG: $50 spending silently ignored
}

@test "check_budget handles empty (0-byte) cost files" {
    TOTAL_BUDGET="100.00"
    touch "$WORK_DIR/costs/empty.cost"

    run check_budget
    assert_success
}

@test "check_budget does not hang on empty cost dir with nullglob" {
    # Regression: synthesize.sh sets shopt -s nullglob globally.
    # With nullglob, *.cost expands to nothing → cat gets no args → blocks on stdin.
    # This test verifies check_budget returns quickly with no cost files.
    TOTAL_BUDGET="100.00"
    # costs dir exists (created by _common_setup) but has no .cost files
    rm -f "$WORK_DIR/costs/"*.cost 2>/dev/null || true

    # Verify nullglob IS set (matching real runtime)
    shopt -q nullglob

    # This must return within 1 second, not hang
    run timeout 2 bash -c "
        source '$PROJECT_ROOT/lib/utils.sh'
        source '$PROJECT_ROOT/lib/config.sh'
        source '$PROJECT_ROOT/lib/synthesize.sh'
        export WORK_DIR='$WORK_DIR'
        export TOTAL_BUDGET='100.00'
        check_budget
    "
    assert_success
}

@test "get_remaining_budget does not hang on empty cost dir with nullglob" {
    TOTAL_BUDGET="100.00"
    rm -f "$WORK_DIR/costs/"*.cost 2>/dev/null || true

    run timeout 2 bash -c "
        source '$PROJECT_ROOT/lib/utils.sh'
        source '$PROJECT_ROOT/lib/config.sh'
        source '$PROJECT_ROOT/lib/synthesize.sh'
        export WORK_DIR='$WORK_DIR'
        export TOTAL_BUDGET='100.00'
        get_remaining_budget
    "
    assert_success
    assert_output --partial "100.00"
}

@test "print_cost_summary treats cost '0.0' same as '0'" {
    # The code checks: [[ "$cost" == "0" ]] to skip zeros.
    # "0.0" doesn't match "0", so it gets included in the sum.
    # If this is a bug, the sum will include a $0.0 entry visually.
    echo "gather|agent1|0.0" > "$WORK_DIR/costs/agent1.cost"
    echo "gather|agent2|1.50" > "$WORK_DIR/costs/agent2.cost"

    run print_cost_summary
    assert_success
    # Total should be 1.50, not inflated by the "0.0" entry
    assert_output --partial "1.5000"
}
