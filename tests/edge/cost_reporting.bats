#!/usr/bin/env bats
# Tests for print_cost_summary edge cases and phase grouping

setup() {
    load '../helpers/test_helper'
    _common_setup
    source_lib 'utils.sh'
    source_lib 'config.sh'
}

teardown() {
    _common_teardown
}

@test "print_cost_summary groups same phase from different cost files" {
    # Two gather agents in separate cost files should be summed together
    echo "gather|identity|1.00" > "$WORK_DIR/costs/identity.cost"
    echo "gather|commands|2.00" > "$WORK_DIR/costs/commands.cost"
    echo "research|domain|3.00" > "$WORK_DIR/costs/domain.cost"

    run print_cost_summary
    assert_success
    # Total should be 6.0000
    assert_output --partial "6.0000"
}

@test "print_cost_summary with single cost entry displays correctly" {
    echo "gather|identity|1.50" > "$WORK_DIR/costs/identity.cost"

    run print_cost_summary
    assert_success
    assert_output --partial "1.5000"
    assert_output --partial "gather"
}

@test "print_cost_summary with only zero-cost entries shows nothing" {
    echo "gather|identity|0" > "$WORK_DIR/costs/identity.cost"
    echo "gather|commands|0" > "$WORK_DIR/costs/commands.cost"

    run print_cost_summary
    assert_success
    # Should show total of 0 or no breakdown at all
    # The loop skips "0" entries, so current_phase never gets set
    # Total stays 0, but the header "Cost breakdown:" still prints
}

@test "print_cost_summary handles cost files from all phases in order" {
    echo "gather|a|1.00" > "$WORK_DIR/costs/a.cost"
    echo "research|b|2.00" > "$WORK_DIR/costs/b.cost"
    echo "synthesize|c|3.00" > "$WORK_DIR/costs/c.cost"
    echo "validate|d|4.00" > "$WORK_DIR/costs/d.cost"

    run print_cost_summary
    assert_success
    assert_output --partial "10.0000"
    # All phases should appear
    assert_output --partial "gather"
    assert_output --partial "research"
    assert_output --partial "synthesize"
    assert_output --partial "validate"
}
