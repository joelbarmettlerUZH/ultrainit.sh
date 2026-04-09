#!/usr/bin/env bats
# Tests for non-numeric, empty, and boundary inputs to budget functions

setup() {
    load '../helpers/test_helper'
    _common_setup
    source_lib 'utils.sh'
    source_lib 'config.sh'
}

teardown() {
    _common_teardown
}

# ── set_agent_budget edge cases ──────────────────────────────

@test "set_agent_budget defaults to 1.00 on empty phase_budget" {
    set_agent_budget "" 5
    [[ -n "$AGENT_BUDGET" ]]
    # Should default phase_budget to 1.00, then divide by 5
    [[ "$AGENT_BUDGET" == ".20" || "$AGENT_BUDGET" == "0.20" ]]
}

@test "set_agent_budget with negative agent_count defaults to 1" {
    set_agent_budget "50.00" -1
    [[ "$AGENT_BUDGET" == "50.00" ]]
}

@test "set_agent_budget with non-numeric agent_count" {
    # PREDICTION: [[ "abc" -lt 1 ]] causes bash error because -lt
    # requires integer operands. Under set -e this would abort.
    # But bats catches it with `run`.
    run set_agent_budget "50.00" "abc"
    # Should either handle gracefully or fail cleanly
    # If it fails, that's a BUG (unhandled input)
    # If AGENT_BUDGET is set to something reasonable, that's fine
    assert_success
}

# ── compute_budgets edge cases ───────────────────────────────

@test "compute_budgets defaults to 100.00 on empty TOTAL_BUDGET" {
    TOTAL_BUDGET=""
    compute_budgets
    [[ -n "$GATHER_BUDGET" ]]
    [[ "$GATHER_BUDGET" == "50.00" ]]
}

@test "compute_budgets defaults to 100.00 on non-numeric TOTAL_BUDGET" {
    TOTAL_BUDGET="abc"
    compute_budgets
    [[ -n "$GATHER_BUDGET" ]]
    [[ "$GATHER_BUDGET" == "50.00" ]]
}

@test "check_budget with TOTAL_BUDGET=0 blocks all agents" {
    # PREDICTION: spent=0.0000, bc evaluates "0.0000 >= 0" = true,
    # so check_budget returns failure. ALL agents are blocked even with
    # zero spending. This is arguably a bug.
    TOTAL_BUDGET="0"
    # No cost files at all
    run check_budget
    # With 0 budget and 0 spending: "0.0000 >= 0" = true in bc
    # So this returns failure — every agent gets skipped.
    assert_failure  # DOCUMENTS BEHAVIOR: zero budget blocks everything
}
