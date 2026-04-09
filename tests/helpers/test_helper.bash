#!/usr/bin/env bash
# tests/helpers/test_helper.bash — shared setup for all bats tests

# Load bats helper libraries (installed from git in Docker)
load '/usr/local/lib/bats-support/load'
load '/usr/local/lib/bats-assert/load'
load '/usr/local/lib/bats-file/load'

# Project root (the mounted workspace)
export PROJECT_ROOT="/workspace"
export SCRIPT_DIR="$PROJECT_ROOT"

# Common setup — call this from each .bats file's setup() function
_common_setup() {
    export TEST_TMPDIR="$(mktemp -d)"
    export WORK_DIR="$TEST_TMPDIR/workdir"
    export TARGET_DIR="$TEST_TMPDIR/target"
    mkdir -p "$WORK_DIR"/{findings/modules,synthesis/skills,synthesis/hooks,synthesis/subagents,logs,backups,costs}
    mkdir -p "$TARGET_DIR"
    echo '{}' > "$WORK_DIR/state.json"

    # Set defaults that lib/config.sh would normally set
    export FORCE="false"
    export NON_INTERACTIVE="true"
    export VERBOSE="false"
    export DRY_RUN="false"
    export SKIP_RESEARCH="false"
    export SKIP_MCP="false"
    export OVERWRITE="false"
    export AGENT_MODEL="sonnet"
    export SYNTH_MODEL="sonnet[1m]"
    export TOTAL_BUDGET="100.00"
    export GATHER_BUDGET="50.00"
    export RESEARCH_BUDGET="10.00"
    export SYNTH_BUDGET="30.00"
    export VALIDATION_BUDGET="10.00"
    export AGENT_BUDGET="1.00"

    # Disable color codes in test output
    export RED='' GREEN='' YELLOW='' BLUE='' CYAN='' BOLD='' RESET=''
}

_common_teardown() {
    rm -rf "$TEST_TMPDIR"
}

# Source a specific lib file (relative to project root)
source_lib() {
    source "$PROJECT_ROOT/lib/$1"
}

# Copy a fixture file into the test work dir
use_fixture() {
    local fixture="$1"
    local dest="$2"
    cp "$PROJECT_ROOT/tests/fixtures/$fixture" "$dest"
}

# Create a minimal valid claude response envelope wrapping a JSON object
# Usage: make_claude_envelope '{"key":"val"}' [cost] [is_error]
# Outputs to stdout — redirect to a file as needed
make_claude_envelope() {
    local structured_output="${1:-\{\}}"
    local cost="${2:-0.15}"
    local is_error="${3:-false}"
    echo "$structured_output" | jq \
        --arg cost "$cost" \
        --arg err "$is_error" \
        '{is_error: ($err == "true"), total_cost_usd: ($cost | tonumber), structured_output: .}'
}
