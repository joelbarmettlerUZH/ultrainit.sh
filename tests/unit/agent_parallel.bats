#!/usr/bin/env bats

setup() {
    load '../helpers/test_helper'
    _common_setup
    load '../helpers/mock_claude'
    setup_mock_claude

    # Create a minimal valid schema file
    echo '{"type":"object","properties":{"name":{"type":"string"}}}' > "$TEST_TMPDIR/schema.json"

    # Create a default successful mock response
    export MOCK_CLAUDE_RESPONSE="$TEST_TMPDIR/response.json"
    make_claude_envelope '{"name":"test-result"}' "0.10" > "$MOCK_CLAUDE_RESPONSE"
}

teardown() {
    _common_teardown
}

# ── Basic parallel execution ────────────────────────────────────

@test "run_agents_parallel succeeds with multiple agents" {
    run_agents_parallel \
        "run_agent agent1 'Prompt one' '$TEST_TMPDIR/schema.json' 'Read'" \
        "run_agent agent2 'Prompt two' '$TEST_TMPDIR/schema.json' 'Read'"

    assert_file_exists "$WORK_DIR/findings/agent1.json"
    assert_file_exists "$WORK_DIR/findings/agent2.json"
}

@test "run_agents_parallel with @file prompts containing special chars" {
    # This is the exact scenario that caused the original bug:
    # developer answers containing apostrophes and parentheses
    cat > "$WORK_DIR/prompts/agent-special1.prompt" <<'PROMPT'
We don't want to extend this project beyond claude (copilot, gemini-cli, etc)
and we don't want to support windows cmd natively.
Check `git log` for $HOME and $(whoami).
PROMPT

    cat > "$WORK_DIR/prompts/agent-special2.prompt" <<'PROMPT'
Shell-native tool that orchestrates multiple claude -p invocations to
analyze any codebase and generate a complete Claude Code configuration
(CLAUDE.md, skills, hooks, subagents, MCP config).
PROMPT

    run_agents_parallel \
        "run_agent special1 '@$WORK_DIR/prompts/agent-special1.prompt' '$TEST_TMPDIR/schema.json' 'Read'" \
        "run_agent special2 '@$WORK_DIR/prompts/agent-special2.prompt' '$TEST_TMPDIR/schema.json' 'Read'"

    assert_file_exists "$WORK_DIR/findings/special1.json"
    assert_file_exists "$WORK_DIR/findings/special2.json"
}

@test "run_agents_parallel returns correct failure count" {
    # Make claude fail for all agents
    export MOCK_CLAUDE_EXIT_CODE=1

    run run_agents_parallel \
        "run_agent fail1 'Prompt' '$TEST_TMPDIR/schema.json' 'Read'" \
        "run_agent fail2 'Prompt' '$TEST_TMPDIR/schema.json' 'Read'" \
        "run_agent fail3 'Prompt' '$TEST_TMPDIR/schema.json' 'Read'"

    # Return code should equal the number of failures
    assert_failure
    [[ "$status" -eq 3 ]]

    assert_file_not_exists "$WORK_DIR/findings/fail1.json"
    assert_file_not_exists "$WORK_DIR/findings/fail2.json"
    assert_file_not_exists "$WORK_DIR/findings/fail3.json"
}

@test "run_agents_parallel cleans up temp directory" {
    # Count ultrainit-agents temp dirs before
    local before
    before=$(find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'ultrainit-agents.*' -type d 2>/dev/null | wc -l)

    run_agents_parallel \
        "run_agent cleanup-test 'Prompt' '$TEST_TMPDIR/schema.json' 'Read'"

    # Count after — should be same as before (temp dir cleaned up)
    local after
    after=$(find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'ultrainit-agents.*' -type d 2>/dev/null | wc -l)
    [[ "$after" -eq "$before" ]]
}

@test "run_agents_parallel propagates env vars to child scripts" {
    # Set a distinctive budget value to verify propagation
    export AGENT_BUDGET="7.77"

    run_agents_parallel \
        "run_agent envtest 'Prompt' '$TEST_TMPDIR/schema.json' 'Read'"

    # Agent should succeed (proves WORK_DIR, SCRIPT_DIR etc. were propagated)
    assert_file_exists "$WORK_DIR/findings/envtest.json"

    # Verify the budget was passed through (check the cost file has the right dir)
    assert_file_exists "$WORK_DIR/costs/envtest.cost"
}
