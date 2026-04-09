#!/usr/bin/env bats

setup() {
    load '../helpers/test_helper'
    _common_setup
    source_lib 'utils.sh'
    source_lib 'config.sh'
    source_lib 'agent.sh'
}

teardown() {
    _common_teardown
}

# ── record_cost ──────────────────────────────────────────────

@test "record_cost creates cost file" {
    record_cost "gather" "identity" "0.42"
    assert_file_exists "$WORK_DIR/costs/identity.cost"
    run cat "$WORK_DIR/costs/identity.cost"
    assert_output "gather|identity|0.42"
}

@test "record_cost overwrites on re-run" {
    record_cost "gather" "identity" "0.30"
    record_cost "gather" "identity" "0.50"
    run cat "$WORK_DIR/costs/identity.cost"
    assert_output "gather|identity|0.50"
}

@test "record_cost creates cost directory if missing" {
    rm -rf "$WORK_DIR/costs"
    record_cost "gather" "identity" "0.10"
    assert_file_exists "$WORK_DIR/costs/identity.cost"
}

# ── get_failed_agents ────────────────────────────────────────

@test "get_failed_agents returns missing agents" {
    echo '{}' > "$WORK_DIR/findings/identity.json"
    echo '{}' > "$WORK_DIR/findings/commands.json"
    # patterns.json is missing
    run get_failed_agents identity commands patterns
    assert_success
    assert_output "patterns"
}

@test "get_failed_agents returns empty when all present" {
    echo '{}' > "$WORK_DIR/findings/identity.json"
    echo '{}' > "$WORK_DIR/findings/commands.json"
    run get_failed_agents identity commands
    assert_success
    assert_output ""
}

@test "get_failed_agents returns all when none present" {
    run get_failed_agents identity commands patterns
    assert_success
    assert_output "identity commands patterns"
}

@test "get_failed_agents handles single agent" {
    run get_failed_agents identity
    assert_success
    assert_output "identity"
}

@test "get_failed_agents handles single present agent" {
    echo '{}' > "$WORK_DIR/findings/identity.json"
    run get_failed_agents identity
    assert_success
    assert_output ""
}
