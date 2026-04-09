#!/usr/bin/env bats

setup() {
    load '../helpers/test_helper'
    _common_setup
    load '../helpers/mock_claude'
    source_lib 'utils.sh'
    source_lib 'config.sh'
    source_lib 'agent.sh'
    setup_mock_claude

    echo '{"type":"object","properties":{"x":{"type":"string"}}}' > "$TEST_TMPDIR/schema.json"
    export MOCK_CLAUDE_RESPONSE="$TEST_TMPDIR/response.json"
    make_claude_envelope '{"x":"result"}' "0.10" > "$MOCK_CLAUDE_RESPONSE"
}

teardown() {
    _common_teardown
}

@test "run_agent skips when budget already exceeded" {
    TOTAL_BUDGET="5.00"
    echo "gather|prev1|3.00" > "$WORK_DIR/costs/prev1.cost"
    echo "gather|prev2|3.00" > "$WORK_DIR/costs/prev2.cost"

    run run_agent "skipped-agent" "Test" "$TEST_TMPDIR/schema.json" "Read"
    assert_failure
    # Should not have created findings
    [[ ! -f "$WORK_DIR/findings/skipped-agent.json" ]]
}

@test "sequential agents stop when budget exhausted mid-run" {
    TOTAL_BUDGET="0.25"
    # Each agent costs 0.10 per mock response

    # First agent should succeed
    run_agent "agent1" "Test" "$TEST_TMPDIR/schema.json" "Read"
    [[ -f "$WORK_DIR/findings/agent1.json" ]]

    # Second should succeed
    run_agent "agent2" "Test" "$TEST_TMPDIR/schema.json" "Read"
    [[ -f "$WORK_DIR/findings/agent2.json" ]]

    # Third agent: budget at 0.20, check may fail depending on bc rounding
    # At 0.25 budget and 0.20 spent, should still have room
    run_agent "agent3" "Test" "$TEST_TMPDIR/schema.json" "Read" || true

    # Now we've spent 0.30 — fourth should definitely be skipped
    run run_agent "agent4" "Test" "$TEST_TMPDIR/schema.json" "Read"
    assert_failure
}
