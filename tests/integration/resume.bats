#!/usr/bin/env bats
# Integration tests for resumability

setup() {
    load '../helpers/test_helper'
    _common_setup
    load '../helpers/mock_claude'
    source_lib 'utils.sh'
    source_lib 'config.sh'
    source_lib 'agent.sh'
    source_lib 'gather.sh'
    setup_mock_claude

    export TARGET_DIR="$TEST_TMPDIR/target"
    mkdir -p "$TARGET_DIR"

    compute_budgets
    set_agent_budget "$GATHER_BUDGET" 50

    export MOCK_CLAUDE_RESPONSE="$TEST_TMPDIR/response.json"
    make_claude_envelope '{"resumed": true}' "0.05" > "$MOCK_CLAUDE_RESPONSE"
}

teardown() {
    _common_teardown
}

@test "run_agent skips agents with existing findings" {
    # Pre-create findings for identity
    echo '{"name": "cached-project"}' > "$WORK_DIR/findings/identity.json"
    FORCE="false"

    echo '{"type":"object"}' > "$TEST_TMPDIR/schema.json"
    run_agent "identity" "Analyze this" "$TEST_TMPDIR/schema.json" "Read"

    # Should have kept original, not overwritten
    run jq -r '.name' "$WORK_DIR/findings/identity.json"
    assert_output "cached-project"

    # Mock should not have been called
    run cat "$MOCK_CLAUDE_LOG"
    refute_output --partial "CALL:"
}

@test "completed phases are skipped entirely" {
    mark_phase_complete "gather"
    FORCE="false"

    run gather_evidence
    assert_success

    # No findings should have been created
    [[ ! -f "$WORK_DIR/findings/identity.json" ]]

    # Mock should not have been called
    run cat "$MOCK_CLAUDE_LOG"
    refute_output --partial "CALL:"
}

@test "FORCE=true reruns completed phases" {
    mark_phase_complete "gather"
    FORCE="true"

    # Need dispatch for all agents
    export MOCK_CLAUDE_DISPATCH_DIR="$TEST_TMPDIR/dispatch"
    mkdir -p "$MOCK_CLAUDE_DISPATCH_DIR"
    for agent in identity commands git-forensics patterns tooling docs-scanner security-scan structure-scout; do
        local fixture="$PROJECT_ROOT/tests/fixtures/findings/${agent}.json"
        if [[ -f "$fixture" ]]; then
            make_claude_envelope "$(cat "$fixture")" "0.05" > "$MOCK_CLAUDE_DISPATCH_DIR/${agent}.json"
        else
            make_claude_envelope '{"placeholder": true}' "0.05" > "$MOCK_CLAUDE_DISPATCH_DIR/${agent}.json"
        fi
    done

    run gather_evidence
    assert_success

    # Findings should now exist
    [[ -f "$WORK_DIR/findings/identity.json" ]]
}
