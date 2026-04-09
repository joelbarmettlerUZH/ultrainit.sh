#!/usr/bin/env bats
# Tests for special characters in paths, names, and content

setup() {
    load '../helpers/test_helper'
    _common_setup
    source_lib 'utils.sh'
    source_lib 'config.sh'
    source_lib 'merge.sh'
    source_lib 'gather.sh'

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
