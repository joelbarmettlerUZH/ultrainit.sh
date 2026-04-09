#!/usr/bin/env bats
# Integration tests for Phase 1: gather_evidence()

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
}

teardown() {
    _common_teardown
}

# Helper: pre-populate findings for given agents (so run_agent skips them)
_precreate_findings() {
    for agent in "$@"; do
        local fixture="$PROJECT_ROOT/tests/fixtures/findings/${agent}.json"
        if [[ -f "$fixture" ]]; then
            cp "$fixture" "$WORK_DIR/findings/${agent}.json"
        else
            echo '{"placeholder": true}' > "$WORK_DIR/findings/${agent}.json"
        fi
    done
}

# Helper: set mock to return a valid response for any agent
_mock_success() {
    export MOCK_CLAUDE_RESPONSE="$TEST_TMPDIR/response.json"
    make_claude_envelope '{"directories":[], "total_files": 0, "total_directories": 0}' "0.05" \
        > "$MOCK_CLAUDE_RESPONSE"
}

# Helper: set mock to return an error response
_mock_error() {
    export MOCK_CLAUDE_RESPONSE="$TEST_TMPDIR/response.json"
    make_claude_envelope '{}' "0" "true" > "$MOCK_CLAUDE_RESPONSE"
}

@test "gather_evidence completes with all agents succeeding" {
    _mock_success

    run gather_evidence
    assert_success

    # All core findings should exist
    for agent in identity commands git-forensics patterns tooling docs-scanner security-scan structure-scout; do
        [[ -f "$WORK_DIR/findings/${agent}.json" ]]
    done

    # Phase should be marked complete
    run is_phase_complete "gather"
    assert_success
}

@test "gather_evidence skips when already complete" {
    mark_phase_complete "gather"
    FORCE="false"

    run gather_evidence
    assert_success

    # Mock should not have been called (no findings created)
    [[ ! -f "$WORK_DIR/findings/identity.json" ]]
}

@test "gather_evidence re-runs with FORCE=true" {
    mark_phase_complete "gather"
    FORCE="true"
    _mock_success

    run gather_evidence
    assert_success

    [[ -f "$WORK_DIR/findings/identity.json" ]]
}

@test "gather_evidence fails on identity agent failure" {
    # Pre-create findings for all agents EXCEPT identity
    _precreate_findings commands git-forensics patterns tooling docs-scanner security-scan structure-scout
    # Mock returns error — only identity will hit it
    _mock_error

    run gather_evidence
    assert_failure
    assert_output --partial "Critical"
}

@test "gather_evidence fails on structure-scout failure" {
    # Pre-create findings for all agents EXCEPT structure-scout
    _precreate_findings identity commands git-forensics patterns tooling docs-scanner security-scan
    _mock_error

    run gather_evidence
    assert_failure
    assert_output --partial "Critical"
}

@test "gather_evidence tolerates 1-2 non-critical failures" {
    # Pre-create findings for all except tooling and docs-scanner (non-critical)
    _precreate_findings identity commands git-forensics patterns security-scan structure-scout
    _mock_error

    run gather_evidence
    assert_success

    # Critical findings should still exist
    [[ -f "$WORK_DIR/findings/identity.json" ]]
    [[ -f "$WORK_DIR/findings/structure-scout.json" ]]
}

@test "gather_evidence fails on 3+ agent failures" {
    # Pre-create findings only for identity and structure-scout (critical)
    # and 2 others — leaving 4 agents to fail (>3)
    _precreate_findings identity structure-scout commands patterns
    _mock_error

    run gather_evidence
    assert_failure
    assert_output --partial "systemic"
}
