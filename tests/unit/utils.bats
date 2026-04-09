#!/usr/bin/env bats

setup() {
    load '../helpers/test_helper'
    _common_setup
    source_lib 'utils.sh'
}

teardown() {
    _common_teardown
}

# ── json_get ─────────────────────────────────────────────────

@test "json_get reads existing key" {
    echo '{"name":"foo","version":"1.0"}' > "$TEST_TMPDIR/test.json"
    run json_get "$TEST_TMPDIR/test.json" ".name"
    assert_success
    assert_output "foo"
}

@test "json_get returns empty for missing key" {
    echo '{"name":"foo"}' > "$TEST_TMPDIR/test.json"
    run json_get "$TEST_TMPDIR/test.json" ".missing"
    assert_success
    assert_output ""
}

@test "json_get returns empty for nonexistent file" {
    run json_get "$TEST_TMPDIR/nonexistent.json" ".name"
    assert_success
    assert_output ""
}

@test "json_get reads nested key" {
    echo '{"a":{"b":"deep"}}' > "$TEST_TMPDIR/test.json"
    run json_get "$TEST_TMPDIR/test.json" ".a.b"
    assert_success
    assert_output "deep"
}

# ── json_merge ───────────────────────────────────────────────

@test "json_merge combines two objects" {
    echo '{"b":2}' > "$TEST_TMPDIR/file.json"
    local result
    result=$(echo '{"a":1}' | json_merge "$TEST_TMPDIR/file.json")
    echo "$result" | jq -e '.a == 1' >/dev/null
    echo "$result" | jq -e '.b == 2' >/dev/null
}

@test "json_merge file overrides stdin on conflict" {
    echo '{"a":2}' > "$TEST_TMPDIR/file.json"
    local result
    result=$(echo '{"a":1}' | json_merge "$TEST_TMPDIR/file.json")
    [[ "$(echo "$result" | jq '.a')" == "2" ]]
}

# ── mark_phase_complete / is_phase_complete ──────────────────

@test "mark_phase_complete creates entry in state file" {
    mark_phase_complete "gather"
    run jq -e '.gather' "$WORK_DIR/state.json"
    assert_success
}

@test "mark_phase_complete adds multiple phases" {
    mark_phase_complete "gather"
    mark_phase_complete "ask"
    run jq -e '.gather and .ask' "$WORK_DIR/state.json"
    assert_success
}

@test "is_phase_complete returns 0 for completed phase" {
    mark_phase_complete "gather"
    run is_phase_complete "gather"
    assert_success
}

@test "is_phase_complete returns 1 for incomplete phase" {
    # state.json exists but has no "gather" key
    echo '{}' > "$WORK_DIR/state.json"
    run is_phase_complete "gather"
    assert_failure
}

@test "is_phase_complete returns 1 without state file" {
    rm -f "$WORK_DIR/state.json"
    run is_phase_complete "gather"
    assert_failure
}

@test "mark_phase_complete creates state file if missing" {
    rm -f "$WORK_DIR/state.json"
    mark_phase_complete "gather"
    [[ -f "$WORK_DIR/state.json" ]]
    run is_phase_complete "gather"
    assert_success
}

# ── print_cost_summary ───────────────────────────────────────

@test "print_cost_summary sums costs correctly" {
    echo "gather|identity|1.50" > "$WORK_DIR/costs/identity.cost"
    echo "gather|commands|0.50" > "$WORK_DIR/costs/commands.cost"
    echo "synthesize|pass-docs|3.00" > "$WORK_DIR/costs/pass-docs.cost"
    run print_cost_summary
    assert_success
    assert_output --partial "5.0000"
}

@test "print_cost_summary handles no cost files" {
    rm -rf "$WORK_DIR/costs"
    mkdir -p "$WORK_DIR/costs"
    run print_cost_summary
    assert_success
}

@test "print_cost_summary skips zero and null costs" {
    echo "gather|identity|0" > "$WORK_DIR/costs/identity.cost"
    echo "gather|commands|null" > "$WORK_DIR/costs/commands.cost"
    echo "synthesize|docs|2.00" > "$WORK_DIR/costs/docs.cost"
    run print_cost_summary
    assert_success
    assert_output --partial "2.0000"
}
