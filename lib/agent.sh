#!/usr/bin/env bash
# lib/agent.sh — Agent spawning helpers

# ── Cost tracking ───────────────────────────────────────────────

# Append a cost entry to the cost log
record_cost() {
    local phase="$1"
    local agent="$2"
    local cost="$3"
    local cost_file="$WORK_DIR/cost.log"
    echo "$phase|$agent|$cost" >> "$cost_file"
}

# ── Agent runner ────────────────────────────────────────────────

# Run a single claude -p agent with structured JSON output.
#
# Usage: run_agent <name> <prompt> <schema_file> <allowed_tools> [model]
#
# - Writes JSON output to $WORK_DIR/findings/<name>.json
# - Skips if findings already exist (unless FORCE=true)
# - Logs stderr to $WORK_DIR/logs/<name>.stderr
run_agent() {
    local name="$1"
    local prompt="$2"
    local schema_file="$3"
    local allowed_tools="$4"
    local model="${5:-$AGENT_MODEL}"
    local output_file="$WORK_DIR/findings/${name}.json"

    # Resumability: skip if findings exist
    if [[ -f "$output_file" ]] && [[ "$FORCE" != "true" ]]; then
        log_info "Skipping $name (findings exist). Use --force to rerun."
        return 0
    fi

    # Budget enforcement: skip if total budget exhausted
    if ! check_budget 2>/dev/null; then
        log_warn "Skipping $name (budget exhausted)"
        return 1
    fi

    if [[ ! -f "$schema_file" ]]; then
        log_error "Schema file not found: $schema_file"
        return 1
    fi

    local schema
    schema=$(cat "$schema_file")

    # Build system prompt flag if a prompt file exists
    local system_prompt_flag=""
    local system_prompt_file="$SCRIPT_DIR/prompts/${name}.md"
    if [[ -f "$system_prompt_file" ]]; then
        system_prompt_flag="--append-system-prompt-file $system_prompt_file"
    fi

    log_progress "Running agent: $name (model: $model)"

    local stderr_file="$WORK_DIR/logs/${name}.stderr"

    # For large prompts, pipe via stdin to avoid "argument list too long"
    local raw_output
    local prompt_len=${#prompt}

    if [[ $prompt_len -gt 100000 ]]; then
        raw_output=$(echo "$prompt" | claude -p - \
            --model "$model" \
            --output-format json \
            --json-schema "$schema" \
            --allowedTools "$allowed_tools" \
            $system_prompt_flag \
            --max-budget-usd "$AGENT_BUDGET" \
            2>>"$stderr_file")
    else
        raw_output=$(claude -p "$prompt" \
            --model "$model" \
            --output-format json \
            --json-schema "$schema" \
            --allowedTools "$allowed_tools" \
            $system_prompt_flag \
            --max-budget-usd "$AGENT_BUDGET" \
            2>>"$stderr_file")
    fi

    local exit_code=$?

    if [[ $exit_code -ne 0 ]]; then
        # claude often writes errors to stdout, not stderr; capture both
        if [[ -n "$raw_output" ]]; then
            echo "stdout: $raw_output" >> "$stderr_file"
        fi
        log_error "Agent $name failed (exit $exit_code). See $stderr_file"
        if [[ "$VERBOSE" == "true" ]]; then
            cat "$stderr_file" >&2
        fi
        return 1
    fi

    # Check for API-level errors in the response envelope
    local is_error
    is_error=$(echo "$raw_output" | jq -r '.is_error // false' 2>/dev/null)
    if [[ "$is_error" == "true" ]]; then
        log_error "Agent $name returned an error: $(echo "$raw_output" | jq -r '.result // "unknown"')"
        echo "$raw_output" >> "$stderr_file"
        return 1
    fi

    # Track cost
    local cost
    cost=$(echo "$raw_output" | jq -r '.total_cost_usd // 0' 2>/dev/null)
    record_cost "gather" "$name" "$cost"

    # Extract structured output from claude response
    # With --json-schema, output is in .structured_output; without, in .result
    echo "$raw_output" | jq '.structured_output // .result // .' > "$output_file" 2>/dev/null

    # Validate we got valid JSON (structured_output should be an object, not a string)
    if ! jq -e 'type == "object" or type == "array"' "$output_file" >/dev/null 2>&1; then
        log_error "Agent $name did not produce structured JSON output. See $stderr_file"
        echo "Raw output: $raw_output" >> "$stderr_file"
        rm -f "$output_file"
        return 1
    fi

    log_success "Agent $name completed -> $output_file"
    return 0
}

# ── Parallel execution ──────────────────────────────────────────

# Run multiple agent calls in parallel.
#
# Each argument is a string containing a full run_agent invocation.
# We write each to a temp script to avoid eval quoting issues with
# special characters (parentheses, spaces, etc.) in paths or descriptions.
#
# Returns the number of failures (0 = all succeeded).
run_agents_parallel() {
    local pids=()
    local names=()
    local tmp_dir
    tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/ultrainit-agents.XXXXXX")

    local idx=0
    for agent_call in "$@"; do
        # Extract agent name (first arg after run_agent)
        local agent_name
        agent_name=$(echo "$agent_call" | sed -E "s/run_agent ([^ ]+).*/\1/")
        names+=("$agent_name")

        # Write the call to a temp script that sources the necessary libs.
        # We explicitly set all parent variables BEFORE sourcing libs so that
        # re-sourcing config.sh cannot overwrite computed values (e.g. AGENT_BUDGET).
        local script="$tmp_dir/agent-${idx}.sh"
        cat > "$script" <<AGENT_SCRIPT
#!/usr/bin/env bash
set -euo pipefail

# Propagate parent state explicitly; these literal values are baked in
# by the parent shell so they survive re-sourcing of config.sh
export WORK_DIR="$WORK_DIR"
export SCRIPT_DIR="$SCRIPT_DIR"
export TARGET_DIR="$TARGET_DIR"
export FORCE="$FORCE"
export VERBOSE="$VERBOSE"
export AGENT_MODEL="$AGENT_MODEL"
export AGENT_BUDGET="$AGENT_BUDGET"
export TOTAL_BUDGET="$TOTAL_BUDGET"

source "$SCRIPT_DIR/lib/utils.sh"
source "$SCRIPT_DIR/lib/config.sh"
source "$SCRIPT_DIR/lib/agent.sh"
$agent_call
AGENT_SCRIPT

        bash "$script" &
        pids+=($!)
        idx=$((idx + 1))
    done

    local failures=0
    local i=0
    for pid in "${pids[@]}"; do
        if ! wait "$pid"; then
            failures=$((failures + 1))
            log_warn "Agent ${names[$i]} failed"
        fi
        i=$((i + 1))
    done

    rm -rf "$tmp_dir"

    if [[ $failures -gt 0 ]]; then
        log_warn "$failures agent(s) failed. Check logs in $WORK_DIR/logs/"
    fi
    return $failures
}
