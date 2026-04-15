#!/usr/bin/env bash
# tests/helpers/test_helper.bash — shared setup for all bats tests

# Load bats helper libraries (installed from git in Docker)
load '/usr/local/lib/bats-support/load'
load '/usr/local/lib/bats-assert/load'
load '/usr/local/lib/bats-file/load'

# Project root — detect from test_helper.bash location (tests/helpers/)
export PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export SCRIPT_DIR="$PROJECT_ROOT"

# Common setup — call this from each .bats file's setup() function.
#
# Sources ALL libs to match the real runtime environment (ultrainit.sh
# sources everything at startup). This is critical — bugs caused by
# interaction between libs (e.g., synthesize.sh setting nullglob that
# breaks config.sh's glob patterns) are only visible when all libs are
# loaded together.
_common_setup() {
    export TEST_TMPDIR="$(mktemp -d)"
    export WORK_DIR="$TEST_TMPDIR/workdir"
    export TARGET_DIR="$TEST_TMPDIR/target"
    mkdir -p "$WORK_DIR"/{findings/modules,synthesis/skills,synthesis/hooks,synthesis/subagents,logs,backups,costs,prompts}
    mkdir -p "$TARGET_DIR"
    echo '{}' > "$WORK_DIR/state.json"

    # Set defaults BEFORE sourcing libs (config.sh uses ${VAR:-default})
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

    # Source ALL libs together, matching ultrainit.sh's startup.
    # This ensures shell options (nullglob, etc.) and function
    # definitions match the real runtime.
    source "$PROJECT_ROOT/lib/utils.sh"
    source "$PROJECT_ROOT/lib/config.sh"
    source "$PROJECT_ROOT/lib/agent.sh"
    source "$PROJECT_ROOT/lib/gather.sh"
    source "$PROJECT_ROOT/lib/ask.sh"
    source "$PROJECT_ROOT/lib/research.sh"
    source "$PROJECT_ROOT/lib/synthesize.sh"
    source "$PROJECT_ROOT/lib/validate.sh"
    source "$PROJECT_ROOT/lib/merge.sh"
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

# Create a response in the real `claude --output-format json` format: a JSON
# array of conversation messages where the last element is the result envelope.
# Usage: make_claude_array_envelope '{"key":"val"}' [cost] [is_error]
make_claude_array_envelope() {
    local structured_output="${1:-\{\}}"
    local cost="${2:-0.15}"
    local is_error="${3:-false}"
    local envelope
    envelope=$(make_claude_envelope "$structured_output" "$cost" "$is_error")
    jq -n --argjson env "$envelope" \
        '[{"type":"system","subtype":"init","cwd":"/tmp/test","session_id":"test-session"}, {"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"analyzing..."}]}}, ($env + {type:"result","terminal_reason":"completed"})]'
}
