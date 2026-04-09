#!/usr/bin/env bash
# tests/helpers/mock_claude.bash — sets up a mock claude binary on PATH
#
# Call setup_mock_claude in your test's setup() to install the mock.
# The mock supports several modes controlled by environment variables:
#
#   MOCK_CLAUDE_RESPONSE    — path to a file whose contents are printed to stdout
#   MOCK_CLAUDE_EXIT_CODE   — exit code (default: 0)
#   MOCK_CLAUDE_LOG         — path to a file where invocation args are appended
#   MOCK_CLAUDE_DISPATCH_DIR — directory of response files keyed by agent name
#
# Dispatch mode:
#   When MOCK_CLAUDE_DISPATCH_DIR is set, the mock extracts the agent name from
#   the prompt (first word after "run_agent") or from the schema filename, and
#   looks for $MOCK_CLAUDE_DISPATCH_DIR/<name>.json. If found, that file is used
#   as the response. If not found, falls back to MOCK_CLAUDE_RESPONSE.

setup_mock_claude() {
    export MOCK_BIN_DIR="$TEST_TMPDIR/mock_bin"
    mkdir -p "$MOCK_BIN_DIR"

    export MOCK_CLAUDE_LOG="$TEST_TMPDIR/claude_calls.log"
    : > "$MOCK_CLAUDE_LOG"

    # Write the mock claude binary
    cat > "$MOCK_BIN_DIR/claude" <<'MOCK_SCRIPT'
#!/usr/bin/env bash
# Mock claude binary for testing

# Log invocation
echo "CALL: $*" >> "${MOCK_CLAUDE_LOG:-/dev/null}"

# Capture stdin if data was actually piped (for large prompt testing).
# Only log when bytes > 0 to distinguish "piped with data" from "no TTY in subshell".
if [[ ! -t 0 ]]; then
    STDIN_CONTENT=$(cat)
    if [[ ${#STDIN_CONTENT} -gt 0 ]]; then
        echo "STDIN: ${#STDIN_CONTENT} bytes" >> "${MOCK_CLAUDE_LOG:-/dev/null}"
    fi
fi

# Handle 'auth status' subcommand
if [[ "$1" == "auth" && "$2" == "status" ]]; then
    echo '{"loggedIn": true}'
    exit 0
fi

# Dispatch mode: look up response by schema name or agent name
if [[ -n "${MOCK_CLAUDE_DISPATCH_DIR:-}" ]]; then
    # Try to find agent name from the prompt args
    # The prompt typically starts with the instruction for run_agent
    # We look for --json-schema to identify which agent this is for
    local schema_file=""
    local prev=""
    for arg in "$@"; do
        if [[ "$prev" == "--json-schema" ]]; then
            schema_file="$arg"
            break
        fi
        prev="$arg"
    done

    if [[ -n "$schema_file" ]]; then
        # Extract the schema content to identify the agent
        # Schema content is passed inline, try to match known patterns
        # Look for response files by iterating dispatch dir
        for response_file in "$MOCK_CLAUDE_DISPATCH_DIR"/*.json; do
            [[ -f "$response_file" ]] || continue
            local name
            name=$(basename "$response_file" .json)
            # Check if this schema content matches (by checking if the schema
            # contains a distinctive key for this agent type)
            if echo "$schema_file" | grep -qi "$name" 2>/dev/null; then
                cat "$response_file"
                exit ${MOCK_CLAUDE_EXIT_CODE:-0}
            fi
        done
    fi

    # Try matching by prompt content (for agents without distinctive schemas)
    local prompt_text="$*"
    for response_file in "$MOCK_CLAUDE_DISPATCH_DIR"/*.json; do
        [[ -f "$response_file" ]] || continue
        local name
        name=$(basename "$response_file" .json)
        if echo "$prompt_text" | grep -qi "$name" 2>/dev/null; then
            cat "$response_file"
            exit ${MOCK_CLAUDE_EXIT_CODE:-0}
        fi
    done
fi

# Default: return configured response
if [[ -n "${MOCK_CLAUDE_RESPONSE:-}" && -f "${MOCK_CLAUDE_RESPONSE}" ]]; then
    cat "${MOCK_CLAUDE_RESPONSE}"
fi
exit ${MOCK_CLAUDE_EXIT_CODE:-0}
MOCK_SCRIPT

    chmod +x "$MOCK_BIN_DIR/claude"

    # Prepend mock to PATH so it intercepts all claude calls
    export PATH="$MOCK_BIN_DIR:$PATH"
}

# Helper: create a response file for dispatch mode
create_dispatch_response() {
    local name="$1"
    local structured_output="$2"
    local cost="${3:-0.10}"

    mkdir -p "${MOCK_CLAUDE_DISPATCH_DIR}"
    jq -n \
        --argjson so "$structured_output" \
        --arg cost "$cost" \
        '{is_error: false, total_cost_usd: ($cost | tonumber), structured_output: $so}' \
        > "${MOCK_CLAUDE_DISPATCH_DIR}/${name}.json"
}

# Helper: create an error response for dispatch mode
create_dispatch_error() {
    local name="$1"
    local error_msg="${2:-Agent failed}"

    mkdir -p "${MOCK_CLAUDE_DISPATCH_DIR}"
    jq -n \
        --arg msg "$error_msg" \
        '{is_error: true, total_cost_usd: 0, result: $msg}' \
        > "${MOCK_CLAUDE_DISPATCH_DIR}/${name}.json"
}
