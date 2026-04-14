#!/usr/bin/env bats
# Regression tests for array-wrapped JSON response handling.
#
# Some claude versions wrap the result object in a JSON array of conversation
# messages. These tests verify that run_agent correctly normalizes both
# array-wrapped and plain object responses.

setup() {
    load '../helpers/test_helper'
    _common_setup
    load '../helpers/mock_claude'
    source_lib 'utils.sh'
    source_lib 'config.sh'
    source_lib 'agent.sh'
    setup_mock_claude

    echo '{"type":"object","properties":{"name":{"type":"string"}}}' > "$TEST_TMPDIR/schema.json"
}

teardown() {
    _common_teardown
}

# ── Array format (real claude output) ───────────────────────────

@test "run_agent extracts structured output from JSON array response" {
    export MOCK_CLAUDE_RESPONSE="$TEST_TMPDIR/response.json"
    make_claude_array_envelope '{"name":"from-array"}' "0.50" > "$MOCK_CLAUDE_RESPONSE"

    run_agent "array-test" "Analyze this" "$TEST_TMPDIR/schema.json" "Read"
    assert_file_exists "$WORK_DIR/findings/array-test.json"
    run jq -r '.name' "$WORK_DIR/findings/array-test.json"
    assert_output "from-array"
}

@test "run_agent extracts cost from JSON array response" {
    export MOCK_CLAUDE_RESPONSE="$TEST_TMPDIR/response.json"
    make_claude_array_envelope '{"name":"x"}' "2.75" > "$MOCK_CLAUDE_RESPONSE"

    run_agent "array-cost" "Analyze" "$TEST_TMPDIR/schema.json" "Read"
    assert_file_exists "$WORK_DIR/costs/array-cost.cost"
    run cat "$WORK_DIR/costs/array-cost.cost"
    assert_output --partial "2.75"
}

@test "run_agent detects is_error=true in JSON array response" {
    export MOCK_CLAUDE_RESPONSE="$TEST_TMPDIR/response.json"
    make_claude_array_envelope '{}' "0" "true" > "$MOCK_CLAUDE_RESPONSE"

    run run_agent "array-error" "Analyze" "$TEST_TMPDIR/schema.json" "Read"
    assert_failure
    assert_file_not_exists "$WORK_DIR/findings/array-error.json"
}

@test "run_agent extracts error message from errors array in JSON array response" {
    export MOCK_CLAUDE_RESPONSE="$TEST_TMPDIR/response.json"
    # Build an array response with errors field
    jq -n '[
        {"type":"system","subtype":"init"},
        {"type":"result","is_error":true,"total_cost_usd":0.05,"errors":["Budget exceeded ($0.05)"],"subtype":"error_max_budget_usd"}
    ]' > "$MOCK_CLAUDE_RESPONSE"

    run run_agent "array-budget" "Analyze" "$TEST_TMPDIR/schema.json" "Read"
    assert_failure
    assert_output --partial "Budget exceeded"
}

# ── Single object format (test mock backward compat) ────────────

@test "run_agent still works with single-object envelope (backward compat)" {
    export MOCK_CLAUDE_RESPONSE="$TEST_TMPDIR/response.json"
    make_claude_envelope '{"name":"from-object"}' "0.30" > "$MOCK_CLAUDE_RESPONSE"

    run_agent "object-test" "Analyze this" "$TEST_TMPDIR/schema.json" "Read"
    assert_file_exists "$WORK_DIR/findings/object-test.json"
    run jq -r '.name' "$WORK_DIR/findings/object-test.json"
    assert_output "from-object"
}

# ── Parallel execution with array format ────────────────────────

@test "run_agents_parallel succeeds with JSON array responses" {
    export MOCK_CLAUDE_RESPONSE="$TEST_TMPDIR/response.json"
    make_claude_array_envelope '{"name":"parallel-result"}' "0.20" > "$MOCK_CLAUDE_RESPONSE"

    run_agents_parallel \
        "run_agent agent-a 'Analyze A' '$TEST_TMPDIR/schema.json' 'Read' $AGENT_MODEL" \
        "run_agent agent-b 'Analyze B' '$TEST_TMPDIR/schema.json' 'Read' $AGENT_MODEL"

    assert_file_exists "$WORK_DIR/findings/agent-a.json"
    assert_file_exists "$WORK_DIR/findings/agent-b.json"
    run jq -r '.name' "$WORK_DIR/findings/agent-a.json"
    assert_output "parallel-result"
}
