#!/usr/bin/env bats

setup() {
    load '../helpers/test_helper'
    _common_setup
    source_lib 'utils.sh'
    source_lib 'config.sh'
}

teardown() {
    _common_teardown
}

@test "setup_work_dir creates directory structure" {
    local target="$TEST_TMPDIR/project"
    mkdir -p "$target"
    setup_work_dir "$target"

    [[ -d "$WORK_DIR/findings/modules" ]]
    [[ -d "$WORK_DIR/synthesis/skills" ]]
    [[ -d "$WORK_DIR/synthesis/hooks" ]]
    [[ -d "$WORK_DIR/synthesis/subagents" ]]
    [[ -d "$WORK_DIR/logs" ]]
    [[ -d "$WORK_DIR/backups" ]]
    [[ -d "$WORK_DIR/costs" ]]
}

@test "setup_work_dir creates state.json" {
    local target="$TEST_TMPDIR/project"
    mkdir -p "$target"
    setup_work_dir "$target"

    [[ -f "$WORK_DIR/state.json" ]]
    run jq '.' "$WORK_DIR/state.json"
    assert_success
    assert_output "{}"
}

@test "setup_work_dir adds to existing .gitignore" {
    local target="$TEST_TMPDIR/project"
    mkdir -p "$target"
    echo "node_modules/" > "$target/.gitignore"
    setup_work_dir "$target"

    run grep '.ultrainit/' "$target/.gitignore"
    assert_success
    run grep 'node_modules/' "$target/.gitignore"
    assert_success
}

@test "setup_work_dir creates .gitignore if missing" {
    local target="$TEST_TMPDIR/project"
    mkdir -p "$target"
    setup_work_dir "$target"

    [[ -f "$target/.gitignore" ]]
    run grep '.ultrainit/' "$target/.gitignore"
    assert_success
}

@test "setup_work_dir does not duplicate .gitignore entry" {
    local target="$TEST_TMPDIR/project"
    mkdir -p "$target"
    echo ".ultrainit/" > "$target/.gitignore"
    setup_work_dir "$target"

    local count
    count=$(grep -c '.ultrainit' "$target/.gitignore")
    [[ "$count" -eq 1 ]]
}

@test "setup_work_dir appends to .gitignore missing trailing newline" {
    local target="$TEST_TMPDIR/project"
    mkdir -p "$target"
    # Write a .gitignore without trailing newline (printf, not echo)
    printf '*.pyc' > "$target/.gitignore"
    setup_work_dir "$target"

    # .ultrainit/ should be on its own line, not merged with *.pyc
    run grep -c '^\.ultrainit/$' "$target/.gitignore"
    assert_output "1"
    run grep -c '^\*\.pyc$' "$target/.gitignore"
    assert_output "1"
}

@test "setup_work_dir does not overwrite existing state.json" {
    local target="$TEST_TMPDIR/project"
    mkdir -p "$target/.ultrainit"
    echo '{"gather":"2024-01-01T00:00:00"}' > "$target/.ultrainit/state.json"
    setup_work_dir "$target"

    run jq -r '.gather' "$WORK_DIR/state.json"
    assert_output "2024-01-01T00:00:00"
}
