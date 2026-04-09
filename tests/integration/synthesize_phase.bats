#!/usr/bin/env bats
# Integration tests for Phase 4: synthesize()

setup() {
    load '../helpers/test_helper'
    _common_setup
    load '../helpers/mock_claude'
    source_lib 'utils.sh'
    source_lib 'config.sh'
    source_lib 'agent.sh'
    source_lib 'synthesize.sh'
    setup_mock_claude

    compute_budgets

    # Disable retries for speed
    export ULTRAINIT_MAX_RETRIES=1

    # Populate findings so context builders work
    for f in identity commands git-forensics patterns tooling docs-scanner security-scan structure-scout; do
        cp "$PROJECT_ROOT/tests/fixtures/findings/${f}.json" "$WORK_DIR/findings/" 2>/dev/null || true
    done
    cp "$PROJECT_ROOT/tests/fixtures/developer-answers.json" "$WORK_DIR/developer-answers.json"

    # Set up dispatch for two synthesis passes
    export MOCK_CLAUDE_DISPATCH_DIR="$TEST_TMPDIR/dispatch"
    mkdir -p "$MOCK_CLAUDE_DISPATCH_DIR"

    # Pass 1 (docs) response — matched by "CLAUDE.md" in prompt
    make_claude_envelope "$(cat "$PROJECT_ROOT/tests/fixtures/synthesis/output-docs.json")" "5.00" \
        > "$MOCK_CLAUDE_DISPATCH_DIR/docs.json"

    # Pass 2 (tooling) response — matched by "skills" in prompt
    make_claude_envelope "$(cat "$PROJECT_ROOT/tests/fixtures/synthesis/output-tooling.json")" "5.00" \
        > "$MOCK_CLAUDE_DISPATCH_DIR/tooling.json"

    # Fallback for any unmatched call
    export MOCK_CLAUDE_RESPONSE="$TEST_TMPDIR/fallback.json"
    make_claude_envelope "$(cat "$PROJECT_ROOT/tests/fixtures/synthesis/output-docs.json")" "2.00" \
        > "$MOCK_CLAUDE_RESPONSE"
}

teardown() {
    _common_teardown
}

@test "synthesize completes two-pass pipeline" {
    run synthesize
    assert_success

    # Both pass outputs should exist
    [[ -f "$WORK_DIR/synthesis/output-docs.json" ]]
    [[ -f "$WORK_DIR/synthesis/output.json" ]]

    # Merged output should have keys from both passes
    run jq -e '.claude_md' "$WORK_DIR/synthesis/output.json"
    assert_success

    # Phase should be marked complete
    run is_phase_complete "synthesize"
    assert_success
}

@test "synthesize skips when already complete" {
    mark_phase_complete "synthesize"
    FORCE="false"

    run synthesize
    assert_success

    # No synthesis output created
    [[ ! -f "$WORK_DIR/synthesis/output-docs.json" ]]
}

@test "synthesize skips completed pass 1" {
    # Pre-create pass 1 output
    cp "$PROJECT_ROOT/tests/fixtures/synthesis/output-docs.json" "$WORK_DIR/synthesis/"

    run synthesize
    assert_success

    # Final output should exist
    [[ -f "$WORK_DIR/synthesis/output.json" ]]
}

@test "synthesize fails when claude returns error" {
    # Make all responses errors
    export MOCK_CLAUDE_EXIT_CODE=1
    export MOCK_CLAUDE_RESPONSE=""
    rm -rf "$MOCK_CLAUDE_DISPATCH_DIR"

    run synthesize
    assert_failure
}
