#!/usr/bin/env bats

setup() {
    load '../helpers/test_helper'
    _common_setup
    load '../helpers/mock_claude'
    source_lib 'utils.sh'
    source_lib 'config.sh'
    source_lib 'agent.sh'
    setup_mock_claude

    # Create a minimal valid schema file
    echo '{"type":"object","properties":{"name":{"type":"string"}}}' > "$TEST_TMPDIR/schema.json"

    # Create a default successful mock response
    export MOCK_CLAUDE_RESPONSE="$TEST_TMPDIR/response.json"
    make_claude_envelope '{"name":"test-result"}' "0.42" > "$MOCK_CLAUDE_RESPONSE"
}

teardown() {
    _common_teardown
}

# ── Success path ─────────────────────────────────────────────

@test "run_agent writes structured output to findings file" {
    run_agent "test-agent" "Analyze this" "$TEST_TMPDIR/schema.json" "Read"
    assert_file_exists "$WORK_DIR/findings/test-agent.json"
    run jq -r '.name' "$WORK_DIR/findings/test-agent.json"
    assert_output "test-result"
}

@test "run_agent extracts cost from response envelope" {
    # Use a DIFFERENT cost than the setup default to prove extraction works
    make_claude_envelope '{"name":"x"}' "1.99" > "$MOCK_CLAUDE_RESPONSE"
    run_agent "cost-test" "Analyze" "$TEST_TMPDIR/schema.json" "Read"

    assert_file_exists "$WORK_DIR/costs/cost-test.cost"
    run cat "$WORK_DIR/costs/cost-test.cost"
    assert_output --partial "1.99"
    # Also verify with the default setup cost to make sure we're not hardcoded
    refute_output --partial "0.42"
}

@test "run_agent records correct phase in cost file" {
    export AGENT_PHASE="research"
    run_agent "phase-test" "Analyze" "$TEST_TMPDIR/schema.json" "Read"

    run cat "$WORK_DIR/costs/phase-test.cost"
    assert_output --partial "research|phase-test|"
    refute_output --partial "gather|"
}

@test "run_agent phase defaults to gather when AGENT_PHASE unset" {
    unset AGENT_PHASE
    run_agent "default-phase" "Analyze" "$TEST_TMPDIR/schema.json" "Read"

    run cat "$WORK_DIR/costs/default-phase.cost"
    assert_output --partial "gather|default-phase|"
}

@test "run_agent passes model to claude" {
    run_agent "test-agent" "Analyze this" "$TEST_TMPDIR/schema.json" "Read" "haiku"
    run cat "$MOCK_CLAUDE_LOG"
    assert_output --partial "--model haiku"
}

@test "run_agent passes allowed tools to claude" {
    run_agent "test-agent" "Analyze this" "$TEST_TMPDIR/schema.json" "Read,Bash(git:*)"
    run cat "$MOCK_CLAUDE_LOG"
    assert_output --partial '--allowedTools Read,Bash(git:*)'
}

# ── Resumability ─────────────────────────────────────────────

@test "run_agent skips when findings exist and FORCE is false" {
    echo '{"cached":true}' > "$WORK_DIR/findings/test-agent.json"
    FORCE="false"
    run run_agent "test-agent" "Analyze this" "$TEST_TMPDIR/schema.json" "Read"
    assert_success
    # Mock should not have been called
    run cat "$MOCK_CLAUDE_LOG"
    refute_output --partial "CALL:"
    # Original findings should be preserved
    run jq -r '.cached' "$WORK_DIR/findings/test-agent.json"
    assert_output "true"
}

@test "run_agent re-runs with FORCE=true" {
    echo '{"cached":true}' > "$WORK_DIR/findings/test-agent.json"
    FORCE="true"
    run_agent "test-agent" "Analyze this" "$TEST_TMPDIR/schema.json" "Read"
    # Findings should be overwritten
    run jq -r '.name' "$WORK_DIR/findings/test-agent.json"
    assert_output "test-result"
}

# ── Failure paths ────────────────────────────────────────────

@test "run_agent fails on exit code != 0" {
    export MOCK_CLAUDE_EXIT_CODE=1
    run run_agent "test-agent" "Analyze this" "$TEST_TMPDIR/schema.json" "Read"
    assert_failure
    # No findings file should be created
    assert_file_not_exists "$WORK_DIR/findings/test-agent.json"
}

@test "run_agent fails on is_error=true and logs error to stderr file" {
    make_claude_envelope '{}' "0" "true" > "$MOCK_CLAUDE_RESPONSE"
    run run_agent "test-agent" "Analyze this" "$TEST_TMPDIR/schema.json" "Read"
    assert_failure
    # Error should be written to the stderr log file
    [[ -s "$WORK_DIR/logs/test-agent.stderr" ]]
}

@test "run_agent surfaces error message from errors array" {
    # Simulate Claude's real budget-exceeded response format
    jq -n '{
        is_error: true,
        total_cost_usd: 0.05,
        errors: ["Reached maximum budget ($0.05)"],
        subtype: "error_max_budget_usd"
    }' > "$MOCK_CLAUDE_RESPONSE"
    run run_agent "budget-fail" "Analyze" "$TEST_TMPDIR/schema.json" "Read"
    assert_failure
    # The error message should include the actual reason, not "unknown"
    assert_output --partial "Reached maximum budget"
    refute_output --partial "unknown"
}

@test "run_agent surfaces error from .result when no errors array" {
    jq -n '{
        is_error: true,
        total_cost_usd: 0,
        result: "Rate limit exceeded"
    }' > "$MOCK_CLAUDE_RESPONSE"
    run run_agent "rate-limit" "Analyze" "$TEST_TMPDIR/schema.json" "Read"
    assert_failure
    assert_output --partial "Rate limit exceeded"
}

@test "run_agent fails on non-object output" {
    # Return a string instead of an object
    jq -n '{is_error: false, total_cost_usd: 0.1, structured_output: "just a string"}' > "$MOCK_CLAUDE_RESPONSE"
    run run_agent "test-agent" "Analyze this" "$TEST_TMPDIR/schema.json" "Read"
    assert_failure
    assert_file_not_exists "$WORK_DIR/findings/test-agent.json"
}

@test "run_agent fails on missing schema file" {
    run run_agent "test-agent" "Analyze this" "$TEST_TMPDIR/nonexistent.json" "Read"
    assert_failure
}

# ── Budget enforcement ───────────────────────────────────────

@test "run_agent skips when budget exhausted" {
    TOTAL_BUDGET="1.00"
    echo "gather|prev|1.50" > "$WORK_DIR/costs/prev.cost"
    run run_agent "test-agent" "Analyze this" "$TEST_TMPDIR/schema.json" "Read"
    assert_failure
    # Mock should not have been called
    run cat "$MOCK_CLAUDE_LOG"
    refute_output --partial "CALL:"
}

# ── Large prompt (stdin pipe) ────────────────────────────────

@test "run_agent uses stdin for prompts over 100KB" {
    # Create a prompt > 100KB
    local large_prompt
    large_prompt=$(dd if=/dev/zero bs=1 count=110000 2>/dev/null | tr '\0' 'x')
    run_agent "large-test" "$large_prompt" "$TEST_TMPDIR/schema.json" "Read"

    # The mock should have received stdin AND the "-p -" flag
    run cat "$MOCK_CLAUDE_LOG"
    assert_output --partial "STDIN:"
    assert_output --partial " -p -"
}

@test "run_agent uses CLI arg for prompts under 100KB" {
    run_agent "small-test" "Short prompt" "$TEST_TMPDIR/schema.json" "Read"

    run cat "$MOCK_CLAUDE_LOG"
    # Should NOT have received stdin
    refute_output --partial "STDIN:"
    # Should have the prompt directly in args
    assert_output --partial "Short prompt"
}
