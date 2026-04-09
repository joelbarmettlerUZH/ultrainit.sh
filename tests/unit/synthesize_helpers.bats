#!/usr/bin/env bats

setup() {
    load '../helpers/test_helper'
    _common_setup
    source_lib 'utils.sh'
    source_lib 'config.sh'
    source_lib 'synthesize.sh'
}

teardown() {
    _common_teardown
}

# ── estimate_tokens ──────────────────────────────────────────

@test "estimate_tokens divides by 4" {
    run estimate_tokens 1000
    assert_output "250"
}

@test "estimate_tokens handles zero" {
    run estimate_tokens 0
    assert_output "0"
}

# ── build_docs_context ───────────────────────────────────────

@test "build_docs_context includes all core findings" {
    # Copy fixture findings into work dir
    for f in identity commands git-forensics patterns tooling docs-scanner security-scan structure-scout; do
        cp "$PROJECT_ROOT/tests/fixtures/findings/$f.json" "$WORK_DIR/findings/" 2>/dev/null || true
    done
    cp "$PROJECT_ROOT/tests/fixtures/developer-answers.json" "$WORK_DIR/developer-answers.json"

    local ctx="$TEST_TMPDIR/context.txt"
    build_docs_context "$ctx"

    [[ -f "$ctx" ]]
    run cat "$ctx"
    assert_output --partial "PROJECT IDENTITY"
    assert_output --partial "COMMANDS"
    assert_output --partial "GIT FORENSICS"
    assert_output --partial "PATTERNS"
    assert_output --partial "TOOLING"
    assert_output --partial "DOCUMENTATION"
    assert_output --partial "SECURITY"
    assert_output --partial "DIRECTORY STRUCTURE"
    assert_output --partial "DEVELOPER ANSWERS"
}

@test "build_docs_context includes module analyses" {
    cp "$PROJECT_ROOT/tests/fixtures/findings/identity.json" "$WORK_DIR/findings/"
    # Create a module findings file
    jq -n '{module_path: "src", purpose: "Main source", architecture: {overview: "MVC", subdirectories: [], data_flow: ""}, patterns: [], conventions: [], gotchas: []}' \
        > "$WORK_DIR/findings/module-src.json"

    local ctx="$TEST_TMPDIR/context.txt"
    build_docs_context "$ctx"

    run cat "$ctx"
    assert_output --partial "MODULE: src"
}

@test "build_docs_context handles missing files gracefully" {
    # Only identity exists
    cp "$PROJECT_ROOT/tests/fixtures/findings/identity.json" "$WORK_DIR/findings/"

    local ctx="$TEST_TMPDIR/context.txt"
    build_docs_context "$ctx"

    [[ -f "$ctx" ]]
    run cat "$ctx"
    assert_output --partial "PROJECT IDENTITY"
}

# ── build_tooling_context ────────────────────────────────────

@test "build_tooling_context includes generated CLAUDE.md" {
    cp "$PROJECT_ROOT/tests/fixtures/synthesis/output-docs.json" "$WORK_DIR/synthesis/"
    cp "$PROJECT_ROOT/tests/fixtures/findings/tooling.json" "$WORK_DIR/findings/"

    local ctx="$TEST_TMPDIR/context.txt"
    build_tooling_context "$ctx"

    [[ -f "$ctx" ]]
    run cat "$ctx"
    assert_output --partial "GENERATED ROOT CLAUDE.MD"
}

# ── merge_synthesis_passes ───────────────────────────────────

@test "merge_synthesis_passes combines docs and tooling" {
    cp "$PROJECT_ROOT/tests/fixtures/synthesis/output-docs.json" "$WORK_DIR/synthesis/"
    cp "$PROJECT_ROOT/tests/fixtures/synthesis/output-tooling.json" "$WORK_DIR/synthesis/"

    merge_synthesis_passes

    [[ -f "$WORK_DIR/synthesis/output.json" ]]
    # Has keys from docs pass
    run jq -e '.claude_md' "$WORK_DIR/synthesis/output.json"
    assert_success
    # Has keys from tooling pass
    run jq -e '.skills' "$WORK_DIR/synthesis/output.json"
    assert_success
}

# ── postprocess_descriptions ─────────────────────────────────

@test "postprocess_descriptions replaces angle brackets with quotes" {
    jq -n '{skills: [{
        name: "test",
        content: "---\nname: test\ndescription: Use for <something> tasks.\n---\nBody"
    }], subagents: []}' > "$TEST_TMPDIR/output.json"

    postprocess_descriptions "$TEST_TMPDIR/output.json"

    local desc
    desc=$(jq -r '.skills[0].content' "$TEST_TMPDIR/output.json")
    # Angle brackets should be replaced with quotes
    [[ ! "$desc" =~ "<" ]]
    [[ "$desc" =~ '"something"' ]]
}

@test "postprocess_descriptions leaves body content untouched" {
    jq -n '{skills: [{
        name: "test",
        content: "---\nname: test\ndescription: Use for <something> tasks.\n---\nBody with <html> tags"
    }], subagents: []}' > "$TEST_TMPDIR/output.json"

    postprocess_descriptions "$TEST_TMPDIR/output.json"

    local content
    content=$(jq -r '.skills[0].content' "$TEST_TMPDIR/output.json")
    # Description should have brackets replaced
    echo "$content" | grep -q 'description: Use for "something" tasks'
    # Body should be untouched (angle brackets only removed from description block)
    echo "$content" | grep -q '<html>'
}

@test "postprocess_descriptions no-ops clean content" {
    jq -n '{skills: [{
        name: "test",
        content: "---\nname: test\ndescription: Use for tasks.\n---\nBody"
    }], subagents: []}' > "$TEST_TMPDIR/output.json"

    local before
    before=$(jq -r '.skills[0].content' "$TEST_TMPDIR/output.json")

    postprocess_descriptions "$TEST_TMPDIR/output.json"

    local after
    after=$(jq -r '.skills[0].content' "$TEST_TMPDIR/output.json")
    [[ "$before" == "$after" ]]
}

@test "postprocess_descriptions also processes subagents" {
    jq -n '{skills: [], subagents: [{
        name: "reviewer",
        content: "---\nname: reviewer\ndescription: Review <components> carefully.\n---\nBody"
    }]}' > "$TEST_TMPDIR/output.json"

    postprocess_descriptions "$TEST_TMPDIR/output.json"

    local desc
    desc=$(jq -r '.subagents[0].content' "$TEST_TMPDIR/output.json")
    [[ ! "$desc" =~ "<components>" ]]
    [[ "$desc" =~ '"components"' ]]
}
