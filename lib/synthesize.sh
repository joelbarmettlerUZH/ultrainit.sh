#!/usr/bin/env bash
# lib/synthesize.sh — Phase 4: Two-pass synthesis

synthesize() {
    log_phase "Phase 4: Synthesis"

    if is_phase_complete "synthesize" && [[ "$FORCE" != "true" ]]; then
        log_info "Phase 4 already complete. Use --force to rerun."
        return 0
    fi

    log_progress "Building context from all findings..."

    # ── Collect all findings into one context document ──────────

    local context_file="$WORK_DIR/synthesis-context.txt"
    build_context "$context_file"

    local context_size
    context_size=$(wc -c < "$context_file" | tr -d ' ')
    log_info "Context assembled: ${context_size} bytes"

    # ── Pass 1: CLAUDE.md files ─────────────────────────────────

    log_progress "Pass 1/2: Generating CLAUDE.md files (model: $SYNTH_MODEL)..."

    run_synthesis_pass \
        "docs" \
        "$SCRIPT_DIR/schemas/synthesis-docs.json" \
        "$SCRIPT_DIR/prompts/synthesizer-docs.md" \
        "$context_file" \
        "Generate comprehensive CLAUDE.md files for this codebase." \
        || return 1

    # ── Pass 2: Skills, hooks, subagents ────────────────────────

    log_progress "Pass 2/2: Generating skills, hooks, and subagents (model: $SYNTH_MODEL)..."

    run_synthesis_pass \
        "tooling" \
        "$SCRIPT_DIR/schemas/synthesis-tooling.json" \
        "$SCRIPT_DIR/prompts/synthesizer-tooling.md" \
        "$context_file" \
        "Generate skills, hooks, subagents, and MCP server recommendations for this codebase." \
        || return 1

    # ── Merge both passes into final output ─────────────────────

    merge_synthesis_passes

    mark_phase_complete "synthesize"
}

# ── Build context from all findings ─────────────────────────────

build_context() {
    local context_file="$1"
    : > "$context_file"

    # Core findings
    local -A finding_labels=(
        [identity]="PROJECT IDENTITY"
        [commands]="COMMANDS"
        [git-forensics]="GIT FORENSICS"
        [patterns]="PATTERNS"
        [tooling]="TOOLING"
        [docs-scanner]="DOCUMENTATION"
        [security-scan]="SECURITY"
        [structure-scout]="DIRECTORY STRUCTURE"
    )

    for key in identity commands git-forensics patterns tooling docs-scanner security-scan structure-scout; do
        local f="$WORK_DIR/findings/${key}.json"
        if [[ -f "$f" ]]; then
            echo "=== ${finding_labels[$key]} ===" >> "$context_file"
            cat "$f" >> "$context_file"
            echo -e "\n" >> "$context_file"
        fi
    done

    # Module analyses
    for f in "$WORK_DIR/findings/module-"*.json; do
        if [[ -f "$f" ]]; then
            local mod_name
            mod_name=$(basename "$f" .json | sed 's/^module-//')
            echo "=== MODULE: $mod_name ===" >> "$context_file"
            cat "$f" >> "$context_file"
            echo -e "\n" >> "$context_file"
        fi
    done

    # Developer answers
    if [[ -f "$WORK_DIR/developer-answers.json" ]]; then
        echo "=== DEVELOPER ANSWERS ===" >> "$context_file"
        cat "$WORK_DIR/developer-answers.json" >> "$context_file"
        echo -e "\n" >> "$context_file"
    fi

    # Research findings
    for key in domain-research mcp-discovery; do
        local f="$WORK_DIR/findings/${key}.json"
        if [[ -f "$f" ]]; then
            echo "=== $(echo "$key" | tr '[:lower:]-' '[:upper:] ') ===" >> "$context_file"
            cat "$f" >> "$context_file"
            echo -e "\n" >> "$context_file"
        fi
    done
}

# ── Run a single synthesis pass ─────────────────────────────────

run_synthesis_pass() {
    local pass_name="$1"
    local schema_file="$2"
    local prompt_file_path="$3"
    local context_file="$4"
    local instruction="$5"

    local schema
    schema=$(cat "$schema_file")

    # Build the prompt file
    local prompt_file="$WORK_DIR/synthesis-prompt-${pass_name}.txt"
    cat > "$prompt_file" <<PROMPT_HEADER
${instruction}

Analyze the following codebase findings:

PROMPT_HEADER
    cat "$context_file" >> "$prompt_file"
    cat >> "$prompt_file" <<'PROMPT_FOOTER'

Based on ALL of the above findings, generate the requested artifacts.
Every rule must trace to evidence above. No generic advice. No duplication of linter rules. Be comprehensive and thorough.
PROMPT_FOOTER

    local stderr_file="$WORK_DIR/logs/synthesis-${pass_name}.stderr"
    : > "$stderr_file"

    # Budget: each synthesis pass gets half the synthesis phase budget
    local pass_budget
    pass_budget=$(echo "scale=2; $SYNTH_BUDGET / 2" | bc)

    # Check total budget before starting
    if ! check_budget 2>/dev/null; then
        log_warn "Skipping synthesis pass '$pass_name' (budget exhausted)"
        return 1
    fi

    local raw_output
    raw_output=$(cat "$prompt_file" | claude -p - \
        --model "$SYNTH_MODEL" \
        --output-format json \
        --json-schema "$schema" \
        --allowedTools "Read" \
        --append-system-prompt-file "$prompt_file_path" \
        --max-budget-usd "$pass_budget" \
        2>>"$stderr_file")

    local exit_code=$?

    if [[ $exit_code -ne 0 ]]; then
        log_error "Synthesis pass '$pass_name' failed (exit $exit_code). See $stderr_file"
        return 1
    fi

    local is_error
    is_error=$(echo "$raw_output" | jq -r '.is_error // false' 2>/dev/null)
    if [[ "$is_error" == "true" ]]; then
        log_error "Synthesis pass '$pass_name' returned an error"
        return 1
    fi

    # Extract structured output
    echo "$raw_output" | jq '.structured_output // .result // .' \
        > "$WORK_DIR/synthesis/output-${pass_name}.json" 2>/dev/null

    if ! jq -e 'type == "object"' "$WORK_DIR/synthesis/output-${pass_name}.json" >/dev/null 2>&1; then
        log_error "Synthesis pass '$pass_name' did not produce structured output"
        echo "Raw: $raw_output" >> "$stderr_file"
        return 1
    fi

    # Track cost
    local cost
    cost=$(echo "$raw_output" | jq -r '.total_cost_usd // 0' 2>/dev/null)
    record_cost "synthesize" "pass-${pass_name}" "$cost"

    log_success "Pass '$pass_name' complete (cost: \$$cost)"
    return 0
}

# ── Merge both passes into unified output.json ──────────────────

merge_synthesis_passes() {
    local docs="$WORK_DIR/synthesis/output-docs.json"
    local tooling="$WORK_DIR/synthesis/output-tooling.json"

    # Merge into the format expected by validate + write phases
    jq -s '.[0] * .[1]' "$docs" "$tooling" > "$WORK_DIR/synthesis/output.json"

    # Post-process: strip angle brackets from descriptions
    postprocess_descriptions "$WORK_DIR/synthesis/output.json"

    log_success "Synthesis passes merged"
}

# ── Post-processing ─────────────────────────────────────────────

# Strip angle brackets from skill and subagent YAML description fields.
postprocess_descriptions() {
    local output_file="$1"
    local tmp_file="${output_file}.tmp"
    local fixed=0

    local skill_count
    skill_count=$(jq '.skills // [] | length' "$output_file")

    for i in $(seq 0 $((skill_count - 1))); do
        local content
        content=$(jq -r ".skills[$i].content" "$output_file")

        if echo "$content" | awk '/^description:/,/^[a-z]/' | grep -q '[<>]'; then
            local new_content
            new_content=$(echo "$content" | awk '
                /^description:/ { in_desc=1 }
                in_desc && /^[a-z]/ && !/^description:/ { in_desc=0 }
                in_desc { gsub(/</, "\""); gsub(/>/, "\"") }
                { print }
            ')
            jq --arg idx "$i" --arg val "$new_content" \
                '.skills[$idx | tonumber].content = $val' "$output_file" > "$tmp_file" \
                && mv "$tmp_file" "$output_file"
            fixed=$((fixed + 1))
        fi
    done

    local agent_count
    agent_count=$(jq '.subagents // [] | length' "$output_file")

    for i in $(seq 0 $((agent_count - 1))); do
        local content
        content=$(jq -r ".subagents[$i].content" "$output_file")

        if echo "$content" | awk '/^description:/,/^[a-z]/' | grep -q '[<>]'; then
            local new_content
            new_content=$(echo "$content" | awk '
                /^description:/ { in_desc=1 }
                in_desc && /^[a-z]/ && !/^description:/ { in_desc=0 }
                in_desc { gsub(/</, "\""); gsub(/>/, "\"") }
                { print }
            ')
            jq --arg idx "$i" --arg val "$new_content" \
                '.subagents[$idx | tonumber].content = $val' "$output_file" > "$tmp_file" \
                && mv "$tmp_file" "$output_file"
            fixed=$((fixed + 1))
        fi
    done

    if [[ $fixed -gt 0 ]]; then
        log_info "Post-processed $fixed description(s) to remove angle brackets"
    fi
}
