#!/usr/bin/env bats

setup() {
    load '../helpers/test_helper'
    _common_setup
    source_lib 'utils.sh'
    source_lib 'config.sh'
    source_lib 'merge.sh'

    # merge.sh functions work in the current directory (the target project)
    cd "$TARGET_DIR"
}

teardown() {
    _common_teardown
}

# ── merge_settings ───────────────────────────────────────────

@test "merge_settings creates settings.json from scratch" {
    local output="$TEST_TMPDIR/output.json"
    jq -n '{settings_hooks: [
        {event: "PostToolUse", command: ".claude/hooks/fmt.sh", matcher: "Write"}
    ]}' > "$output"

    merge_settings "$output"

    [[ -f .claude/settings.json ]]
    run jq '.hooks.PostToolUse | length' .claude/settings.json
    assert_output "1"
    run jq -r '.hooks.PostToolUse[0].hooks[0].command' .claude/settings.json
    assert_output ".claude/hooks/fmt.sh"
}

@test "merge_settings merges into existing settings" {
    mkdir -p .claude
    echo '{"allowedTools": ["Read"], "hooks": {"PreToolUse": [{"hooks": [{"type": "command", "command": "existing.sh"}]}]}}' > .claude/settings.json

    local output="$TEST_TMPDIR/output.json"
    jq -n '{settings_hooks: [
        {event: "PostToolUse", command: ".claude/hooks/new.sh"}
    ]}' > "$output"

    merge_settings "$output"

    # Original keys preserved
    run jq '.allowedTools[0]' .claude/settings.json
    assert_output '"Read"'
    # Original hooks preserved
    run jq '.hooks.PreToolUse | length' .claude/settings.json
    assert_output "1"
    # New hooks added
    run jq '.hooks.PostToolUse | length' .claude/settings.json
    assert_output "1"
}

@test "merge_settings concatenates hook arrays for same event" {
    mkdir -p .claude
    echo '{"hooks": {"PostToolUse": [{"hooks": [{"type": "command", "command": "old.sh"}]}]}}' > .claude/settings.json

    local output="$TEST_TMPDIR/output.json"
    jq -n '{settings_hooks: [
        {event: "PostToolUse", command: ".claude/hooks/new.sh"}
    ]}' > "$output"

    merge_settings "$output"

    # Both old and new hooks present
    run jq '.hooks.PostToolUse | length' .claude/settings.json
    assert_output "2"
}

@test "merge_settings does nothing with empty settings_hooks" {
    local output="$TEST_TMPDIR/output.json"
    jq -n '{settings_hooks: []}' > "$output"

    merge_settings "$output"
    # No settings.json should be created
    [[ ! -f .claude/settings.json ]]
}

# ── write_mcp_config ─────────────────────────────────────────

@test "write_mcp_config creates mcp.json" {
    local output="$TEST_TMPDIR/output.json"
    jq -n '{mcp_servers: [
        {name: "context7", command: "npx", args: ["-y", "@context7/mcp"], env: {}}
    ]}' > "$output"

    write_mcp_config "$output"

    [[ -f .claude/mcp.json ]]
    run jq '.mcpServers.context7.command' .claude/mcp.json
    assert_output '"npx"'
}

@test "write_mcp_config merges into existing" {
    mkdir -p .claude
    echo '{"mcpServers": {"existing": {"command": "node", "args": []}}}' > .claude/mcp.json

    local output="$TEST_TMPDIR/output.json"
    jq -n '{mcp_servers: [
        {name: "new-server", command: "npx", args: ["new"], env: {}}
    ]}' > "$output"

    write_mcp_config "$output"

    # Both servers present
    run jq '.mcpServers | keys | length' .claude/mcp.json
    assert_output "2"
    run jq '.mcpServers.existing.command' .claude/mcp.json
    assert_output '"node"'
}

@test "write_mcp_config does nothing with empty mcp_servers" {
    local output="$TEST_TMPDIR/output.json"
    jq -n '{mcp_servers: []}' > "$output"

    write_mcp_config "$output"
    [[ ! -f .claude/mcp.json ]]
}

# ── backup_existing ──────────────────────────────────────────

@test "backup_existing backs up CLAUDE.md" {
    echo "# Original" > CLAUDE.md

    backup_existing

    local backup_count
    backup_count=$(find "$WORK_DIR/backups" -name "CLAUDE.md" | wc -l)
    [[ "$backup_count" -eq 1 ]]
}

@test "backup_existing handles no existing files" {
    run backup_existing
    assert_success
}

# ── write_artifacts ──────────────────────────────────────────

@test "write_artifacts respects DRY_RUN" {
    cp "$PROJECT_ROOT/tests/fixtures/synthesis/output.json" "$WORK_DIR/synthesis/output.json"
    DRY_RUN="true"

    run write_artifacts
    assert_success
    # CLAUDE.md should NOT be written
    [[ ! -f CLAUDE.md ]]
}

@test "write_artifacts skips existing skills" {
    cp "$PROJECT_ROOT/tests/fixtures/synthesis/output.json" "$WORK_DIR/synthesis/output.json"
    DRY_RUN="false"

    # Pre-create the api-development skill
    mkdir -p ".claude/skills/api-development"
    echo "# Existing" > ".claude/skills/api-development/SKILL.md"

    write_artifacts

    # Should be skipped (original content preserved)
    run cat ".claude/skills/api-development/SKILL.md"
    assert_output "# Existing"
}

@test "write_artifacts writes CLAUDE.md" {
    cp "$PROJECT_ROOT/tests/fixtures/synthesis/output.json" "$WORK_DIR/synthesis/output.json"
    DRY_RUN="false"

    write_artifacts

    [[ -f CLAUDE.md ]]
    run grep "Test Project" CLAUDE.md
    assert_success
}
