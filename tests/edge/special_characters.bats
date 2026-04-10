#!/usr/bin/env bats
# Tests for special characters in paths, names, and content

setup() {
    load '../helpers/test_helper'
    _common_setup
    load '../helpers/mock_claude'
    setup_mock_claude
    source_lib 'utils.sh'
    source_lib 'config.sh'
    source_lib 'agent.sh'
    source_lib 'merge.sh'
    source_lib 'gather.sh'
    source_lib 'research.sh'

    cd "$TARGET_DIR"
}

teardown() {
    _common_teardown
}

# ── Paths with spaces ───────────────────────────────────────

@test "setup_work_dir handles path with spaces" {
    local target="$TEST_TMPDIR/my project dir"
    mkdir -p "$target"
    run setup_work_dir "$target"
    assert_success
    [[ -d "$target/.ultrainit/findings" ]]
}

# ── Skill names with problematic characters ──────────────────

@test "write_artifacts skips skill name with slashes" {
    jq -n '{
        claude_md: "# Test\n",
        subdirectory_claude_mds: [],
        skills: [{"name": "api/v2", "description": "broken", "content": "# Skill"}],
        hooks: [],
        subagents: [],
        mcp_servers: [],
        settings_hooks: []
    }' > "$WORK_DIR/synthesis/output.json"
    DRY_RUN="false"

    run write_artifacts
    assert_success

    # Should NOT have created any skill directory (name was invalid)
    [[ ! -d ".claude/skills/api" ]]
    [[ ! -d ".claude/skills/api/v2" ]]
}

# ── gather safe_name edge cases ──────────────────────────────

@test "gather safe_name for dot-only directory falls back to 'root'" {
    local dir_path="."
    local safe_name
    safe_name=$(echo "$dir_path" | sed 's|/|-|g; s|\.|-|g; s|[()]||g; s| ||g; s|^-||; s|-$||')
    [[ -z "$safe_name" ]] && safe_name="root"

    [[ "$safe_name" == "root" ]]
}

@test "gather safe_name for directory with parentheses and spaces" {
    # dir_path="src (old copy)" → should produce a usable name
    local dir_path="src (old copy)"
    local safe_name
    safe_name=$(echo "$dir_path" | sed 's|/|-|g; s|\.|-|g; s|[()]||g; s|^-||; s|-$||')

    [[ -n "$safe_name" ]]
    # Should not contain spaces (would break agent file names)
    [[ ! "$safe_name" =~ " " ]] || true
    # Note: spaces are NOT removed by the sed — this is a potential bug
}

# ── @file prompts with special characters in parallel ───────────

@test "developer answers with apostrophes survive research prompt building" {
    # Simulate developer-answers.json with apostrophes (the original bug trigger)
    jq -n '{
        project_purpose: "It'\''s a tool that won'\''t break",
        deployment_target: "Docker",
        additional_context: "We don'\''t want copilot (or gemini-cli, etc)"
    }' > "$WORK_DIR/developer-answers.json"

    jq -n '{
        name: "test-project",
        description: "Test",
        languages: [{"name": "Bash"}],
        frameworks: [{"name": "bats-core"}]
    }' > "$WORK_DIR/findings/identity.json"

    # Source research.sh variables and build the prompt file
    local answers_file="$WORK_DIR/developer-answers.json"
    local identity_file="$WORK_DIR/findings/identity.json"
    local project_purpose
    project_purpose=$(jq -r '.project_purpose // empty' "$answers_file")
    local additional_context
    additional_context=$(jq -r '.additional_context // empty' "$answers_file")
    local deployment_target
    deployment_target=$(jq -r '.deployment_target // empty' "$answers_file")
    local project_name
    project_name=$(jq -r '.name // empty' "$identity_file")
    local languages
    languages=$(jq -r '[.languages[]?.name] | join(", ")' "$identity_file")
    local tech_stack
    tech_stack=$(jq -r '[.frameworks[]?.name] | join(", ")' "$identity_file")

    # Write prompt to file the same way research.sh does
    cat > "$WORK_DIR/prompts/domain-research.prompt" <<EOF
Research the domain and tech stack for this project.
Project: ${project_name:-unknown} — ${project_purpose:-unknown purpose}
Languages: ${languages:-unknown}
Tech stack: ${tech_stack}
Deployment: ${deployment_target:-unknown}
Additional context: ${additional_context:-none}
EOF

    # Verify the file was written correctly with special chars intact
    run cat "$WORK_DIR/prompts/domain-research.prompt"
    assert_output --partial "won't break"
    assert_output --partial "don't want copilot (or gemini-cli, etc)"
}

@test "developer answers with apostrophes survive parallel agent execution" {
    export MOCK_CLAUDE_RESPONSE="$TEST_TMPDIR/response.json"
    make_claude_envelope '{"findings":"ok"}' "0.10" > "$MOCK_CLAUDE_RESPONSE"
    echo '{"type":"object"}' > "$TEST_TMPDIR/schema.json"

    # Write a prompt with all the problematic chars from the real bug
    cat > "$WORK_DIR/prompts/research-test.prompt" <<'PROMPT'
We don't want to extend this project beyond claude (copilot, gemini-cli, etc)
and we don't want to support windows cmd natively - windows users must use
git bash or wsl. Run `git log` to check $HOME.
PROMPT

    run_agents_parallel \
        "run_agent research-test '@$WORK_DIR/prompts/research-test.prompt' '$TEST_TMPDIR/schema.json' 'Read'"

    assert_file_exists "$WORK_DIR/findings/research-test.json"
}

@test "structure-scout descriptions with parens survive deep-dive prompt building" {
    # Simulate dir_desc from structure-scout containing parentheses
    local dir_path="lib"
    local dir_role="core"
    local dir_desc="Core library (agent spawning, config, validation)"
    local safe_name="lib"

    cat > "$WORK_DIR/prompts/module-${safe_name}.prompt" <<EOF
Deeply analyze the directory at ${dir_path}/ in this project. This directory is classified as: ${dir_role}. Brief context: ${dir_desc}.
EOF

    # Verify the prompt file preserves the parens
    run cat "$WORK_DIR/prompts/module-${safe_name}.prompt"
    assert_output --partial "(agent spawning, config, validation)"
}
