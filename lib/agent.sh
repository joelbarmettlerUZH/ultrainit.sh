#!/usr/bin/env bash
# lib/agent.sh — Agent spawning helpers

# ── Cost tracking ───────────────────────────────────────────────

# Record cost for an agent. Each agent writes its own file to avoid
# race conditions when agents run in parallel. Files are aggregated
# by check_budget and print_cost_summary.
record_cost() {
    local phase="$1"
    local agent="$2"
    local cost="$3"
    local cost_dir="$WORK_DIR/costs"
    mkdir -p "$cost_dir"
    echo "$phase|$agent|$cost" > "$cost_dir/${agent}.cost"
}

# ── Agent runner ────────────────────────────────────────────────

# Run a single claude -p agent with structured JSON output.
#
# Usage: run_agent <name> <prompt> <schema_file> <allowed_tools> [model] [phase]
#
# - Writes JSON output to $WORK_DIR/findings/<name>.json
# - Skips if findings already exist (unless FORCE=true)
# - Logs stderr to $WORK_DIR/logs/<name>.stderr
# - phase defaults to AGENT_PHASE (if set) or "gather"
run_agent() {
    local name="$1"
    local prompt="$2"
    local schema_file="$3"
    local allowed_tools="$4"
    local model="${5:-$AGENT_MODEL}"
    local phase="${6:-${AGENT_PHASE:-gather}}"
    local output_file="$WORK_DIR/findings/${name}.json"

    # Support @file syntax: read prompt from file to avoid shell quoting
    # issues when prompts contain apostrophes, parentheses, backticks, etc.
    if [[ "$prompt" == @* ]]; then
        local prompt_file="${prompt#@}"
        if [[ ! -f "$prompt_file" ]]; then
            log_error "Prompt file not found: $prompt_file"
            return 1
        fi
        prompt=$(cat "$prompt_file")
    fi

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
    local output_tmpfile="$WORK_DIR/logs/${name}.stdout"

    if [[ $prompt_len -gt 100000 ]]; then
        run_with_spinner \
            "Agent $name running..." \
            "$output_tmpfile" \
            "$stderr_file" \
            bash -c "echo \"\$1\" | claude -p - \
                --model '$model' \
                --output-format json \
                --json-schema '$schema' \
                --allowedTools '$allowed_tools' \
                $system_prompt_flag \
                --max-budget-usd '$AGENT_BUDGET'" _ "$prompt"
    else
        run_with_spinner \
            "Agent $name running..." \
            "$output_tmpfile" \
            "$stderr_file" \
            claude -p "$prompt" \
                --model "$model" \
                --output-format json \
                --json-schema "$schema" \
                --allowedTools "$allowed_tools" \
                $system_prompt_flag \
                --max-budget-usd "$AGENT_BUDGET"
    fi

    local exit_code=$?
    raw_output=$(cat "$output_tmpfile" 2>/dev/null)

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

    # claude --output-format json returns a JSON array of conversation messages.
    # The final element contains the result envelope with cost, structured_output, etc.
    # Extract it once so downstream jq expressions can use simple dot-access.
    local result_envelope
    result_envelope=$(echo "$raw_output" | jq 'if type == "array" then .[-1] else . end' 2>/dev/null)

    # Check for API-level errors in the response envelope
    local is_error
    is_error=$(echo "$result_envelope" | jq -r '.is_error // false' 2>/dev/null)
    if [[ "$is_error" == "true" ]]; then
        # Extract the most useful error message from the response
        local error_msg
        error_msg=$(echo "$result_envelope" | jq -r '
            (if (.errors // [] | length) > 0 then (.errors | join("; "))
             elif .result then .result
             else "unknown error" end)
        ' 2>/dev/null)
        log_error "Agent $name failed: $error_msg"
        echo "$raw_output" >> "$stderr_file"
        if [[ "$VERBOSE" == "true" ]]; then
            cat "$stderr_file" >&2
        fi
        return 1
    fi

    # Track cost
    local cost
    cost=$(echo "$result_envelope" | jq -r '.total_cost_usd // 0' 2>/dev/null)
    record_cost "$phase" "$name" "$cost"

    # Extract structured output from claude response
    # With --json-schema, output is in .structured_output; without, in .result
    echo "$result_envelope" | jq '.structured_output // .result // .' > "$output_file" 2>/dev/null

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
export AGENT_PHASE="${AGENT_PHASE:-gather}"
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

# ── Failure diagnostics ────────────────────────────────────────

# Collect error logs from failed agents and ask Claude to diagnose.
# Usage: diagnose_phase_failure <phase_name> <agent_names...>
#
# Looks at stderr log files for each named agent. If any contain errors,
# sends them to a lightweight Claude call that produces a human-readable
# diagnosis with actionable steps.
diagnose_phase_failure() {
    local phase="$1"
    shift
    local failed_agents=("$@")

    if [[ ${#failed_agents[@]} -eq 0 ]]; then
        return 0
    fi

    # Collect error context from log files
    local error_context=""
    for agent_name in "${failed_agents[@]}"; do
        local log_file="$WORK_DIR/logs/${agent_name}.stderr"
        if [[ -f "$log_file" ]] && [[ -s "$log_file" ]]; then
            # Truncate to last 50 lines per agent to keep context manageable
            local log_content
            log_content=$(tail -50 "$log_file")
            error_context+="=== Agent: ${agent_name} ===
${log_content}

"
        else
            error_context+="=== Agent: ${agent_name} ===
(no error output captured)

"
        fi
    done

    echo ""
    log_error "${#failed_agents[@]} step(s) failed in phase '$phase': ${failed_agents[*]}"
    echo ""

    # Try to get Claude to diagnose — but if Claude itself is the problem,
    # fall back to just showing the raw logs
    local diagnosis=""
    if command -v claude &>/dev/null; then
        diagnosis=$(claude -p "You are a diagnostic assistant for ultrainit, a bash tool that uses Claude Code to analyze codebases.

The following agents failed during the '$phase' phase. Analyze the error logs below and provide:
1. A one-line root cause (e.g. 'Authentication expired', 'Rate limit hit', 'Missing dependency: bc')
2. What the user should do to fix it (concrete shell commands when possible)
3. Whether this is likely transient (retry may work) or persistent (needs user action)

Keep your response under 10 lines. Be direct and actionable.

Failed agents: ${failed_agents[*]}

Error logs:
${error_context}" \
            --model haiku \
            --output-format text \
            --max-turns 1 \
            --allowedTools "" \
            --bare \
            --max-budget-usd 0.05 \
            2>/dev/null) || true
    fi

    if [[ -n "$diagnosis" ]]; then
        echo -e "${BOLD}Diagnosis:${RESET}"
        echo "$diagnosis"
    else
        # Claude couldn't diagnose (maybe it's the thing that's broken) — show raw logs
        echo -e "${BOLD}Error logs from failed agents:${RESET}"
        echo "$error_context"
    fi
    echo ""
}

# Check which agents from a list have findings files and which don't.
# Usage: get_failed_agents <agent_name1> <agent_name2> ...
# Prints the names of agents whose findings files are missing.
get_failed_agents() {
    local failed=()
    for agent_name in "$@"; do
        if [[ ! -f "$WORK_DIR/findings/${agent_name}.json" ]]; then
            failed+=("$agent_name")
        fi
    done
    echo "${failed[@]}"
}
