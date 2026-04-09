#!/usr/bin/env bats

setup() {
    load '../helpers/test_helper'
    _common_setup
    source_lib 'utils.sh'
    source_lib 'config.sh'
}

teardown() {
    _common_teardown
}

# ── compute_budgets ──────────────────────────────────────────

@test "compute_budgets splits default 100 into correct percentages" {
    TOTAL_BUDGET="100.00"
    compute_budgets
    [[ "$GATHER_BUDGET" == "50.00" ]]
    [[ "$RESEARCH_BUDGET" == "10.00" ]]
    [[ "$SYNTH_BUDGET" == "30.00" ]]
    [[ "$VALIDATION_BUDGET" == "10.00" ]]
}

@test "compute_budgets handles custom budget of 50" {
    TOTAL_BUDGET="50.00"
    compute_budgets
    [[ "$GATHER_BUDGET" == "25.00" ]]
    [[ "$RESEARCH_BUDGET" == "5.00" ]]
    [[ "$SYNTH_BUDGET" == "15.00" ]]
    [[ "$VALIDATION_BUDGET" == "5.00" ]]
}

@test "compute_budgets handles fractional budget" {
    TOTAL_BUDGET="7.50"
    compute_budgets
    [[ "$GATHER_BUDGET" == "3.75" ]]
}

# ── set_agent_budget ─────────────────────────────────────────

@test "set_agent_budget divides evenly" {
    set_agent_budget "50.00" 10
    [[ "$AGENT_BUDGET" == "5.00" ]]
}

@test "set_agent_budget with 1 agent gives full budget" {
    set_agent_budget "50.00" 1
    [[ "$AGENT_BUDGET" == "50.00" ]]
}

@test "set_agent_budget with 0 agents defaults to 1" {
    set_agent_budget "50.00" 0
    [[ "$AGENT_BUDGET" == "50.00" ]]
}

@test "set_agent_budget handles fractional result" {
    set_agent_budget "10.00" 3
    # bc gives 3.33
    [[ "$AGENT_BUDGET" == "3.33" ]]
}

# ── check_budget ─────────────────────────────────────────────

@test "check_budget returns 0 when under budget" {
    TOTAL_BUDGET="100.00"
    echo "gather|identity|5.00" > "$WORK_DIR/costs/identity.cost"
    echo "gather|commands|3.00" > "$WORK_DIR/costs/commands.cost"
    run check_budget
    assert_success
}

@test "check_budget returns 1 when over budget" {
    TOTAL_BUDGET="10.00"
    echo "gather|identity|5.00" > "$WORK_DIR/costs/identity.cost"
    echo "gather|commands|6.00" > "$WORK_DIR/costs/commands.cost"
    run check_budget
    assert_failure
}

@test "check_budget returns 1 at exact budget" {
    TOTAL_BUDGET="10.00"
    echo "gather|identity|5.00" > "$WORK_DIR/costs/identity.cost"
    echo "gather|commands|5.00" > "$WORK_DIR/costs/commands.cost"
    run check_budget
    assert_failure
}

@test "check_budget returns 0 with no cost directory" {
    rm -rf "$WORK_DIR/costs"
    TOTAL_BUDGET="100.00"
    run check_budget
    assert_success
}

@test "check_budget returns 0 with empty cost directory" {
    TOTAL_BUDGET="100.00"
    run check_budget
    assert_success
}

# ── get_remaining_budget ─────────────────────────────────────

@test "get_remaining_budget computes correctly" {
    TOTAL_BUDGET="100.00"
    echo "gather|identity|37.50" > "$WORK_DIR/costs/identity.cost"
    run get_remaining_budget
    assert_success
    assert_output --partial "62.50"
}

@test "get_remaining_budget with no spending returns total" {
    TOTAL_BUDGET="100.00"
    run get_remaining_budget
    assert_success
    assert_output --partial "100.00"
}

# ── check_budget_sanity ──────────────────────────────────────

@test "check_budget_sanity warns for low opus budget" {
    SYNTH_MODEL="opus[1m]"
    TOTAL_BUDGET="10.00"
    run check_budget_sanity
    assert_output --partial "may be too low"
}

@test "check_budget_sanity quiet for adequate sonnet budget" {
    SYNTH_MODEL="sonnet[1m]"
    TOTAL_BUDGET="50.00"
    run check_budget_sanity
    # Should not contain warning
    refute_output --partial "may be too low"
}

@test "check_budget_sanity warns for very low haiku budget" {
    SYNTH_MODEL="haiku"
    TOTAL_BUDGET="2.00"
    run check_budget_sanity
    assert_output --partial "may be too low"
}
