#!/usr/bin/env bash
# lib/synthesize.sh — Phase 4: Two-pass synthesis

synthesize() {
    log_phase "Phase 4: Synthesis"

    if is_phase_complete "synthesize" && [[ "$FORCE" != "true" ]]; then
        log_info "Phase 4 already complete. Use --force to rerun."
        return 0
    fi

    # ── Pass 1: CLAUDE.md files (full context) ──────────────────

    log_progress "Building full context from all findings..."

    local full_context="$WORK_DIR/synthesis-context-full.txt"
    build_full_context "$full_context"

    local context_size
    context_size=$(wc -c < "$full_context" | tr -d ' ')
    log_info "Full context assembled: ${context_size} bytes"

    log_progress "Pass 1/2: Generating CLAUDE.md files (model: $SYNTH_MODEL)..."

    run_synthesis_pass \
        "docs" \
        "$SCRIPT_DIR/schemas/synthesis-docs.json" \
        "$SCRIPT_DIR/prompts/synthesizer-docs.md" \
        "$full_context" \
        "Generate comprehensive CLAUDE.md files for this codebase." \
        || return 1

    # ── Pass 2: Skills, hooks, subagents (focused context) ──────
    #
    # Pass 2 gets the generated CLAUDE.md (already distilled) plus
    # only the findings relevant to tooling: skill opportunities,
    # tooling config, security rules, MCP recommendations, and
    # developer answers. Much smaller than the full context.

    log_progress "Building focused context for tooling pass..."

    local tooling_context="$WORK_DIR/synthesis-context-tooling.txt"
    build_tooling_context "$tooling_context"

    local tooling_size
    tooling_size=$(wc -c < "$tooling_context" | tr -d ' ')
    log_info "Tooling context assembled: ${tooling_size} bytes (vs ${context_size} full)"

    log_progress "Pass 2/2: Generating skills, hooks, and subagents (model: $SYNTH_MODEL)..."

    run_synthesis_pass \
        "tooling" \
        "$SCRIPT_DIR/schemas/synthesis-tooling.json" \
        "$SCRIPT_DIR/prompts/synthesizer-tooling.md" \
        "$tooling_context" \
        "Generate skills, hooks, subagents, and MCP server recommendations for this codebase." \
        || return 1

    # ── Merge both passes into final output ─────────────────────

    merge_synthesis_passes

    mark_phase_complete "synthesize"
}

# ── Build full context (for Pass 1: docs) ───────────────────────

build_full_context() {
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

    # Module analyses (full)
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

# ── Build focused context (for Pass 2: tooling) ────────────────
#
# Instead of the full 1MB+ of raw findings, Pass 2 gets:
#   1. The generated CLAUDE.md from Pass 1 (distilled architecture + conventions)
#   2. Skill opportunities extracted from each module analysis
#   3. Tooling findings (for hooks)
#   4. Security findings (for file protection hooks)
#   5. MCP discovery results
#   6. Developer answers (never-do rules)
#   7. Commands (for workflow skills)
#   8. Patterns (for reference skills)

build_tooling_context() {
    local context_file="$1"
    : > "$context_file"

    # 1. The generated CLAUDE.md — the distilled source of truth
    local docs_output="$WORK_DIR/synthesis/output-docs.json"
    if [[ -f "$docs_output" ]]; then
        echo "=== GENERATED CLAUDE.MD (from Pass 1 — use this as the source of truth for architecture and conventions) ===" >> "$context_file"
        jq -r '.claude_md' "$docs_output" >> "$context_file"
        echo -e "\n" >> "$context_file"

        # Also include subdirectory CLAUDE.md paths so skills can reference them
        local sub_count
        sub_count=$(jq '.subdirectory_claude_mds // [] | length' "$docs_output")
        if [[ $sub_count -gt 0 ]]; then
            echo "=== SUBDIRECTORY CLAUDE.MD FILES ===" >> "$context_file"
            for i in $(seq 0 $((sub_count - 1))); do
                local path
                path=$(jq -r ".subdirectory_claude_mds[$i].path" "$docs_output")
                echo "--- $path/CLAUDE.md ---" >> "$context_file"
                jq -r ".subdirectory_claude_mds[$i].content" "$docs_output" >> "$context_file"
                echo -e "\n" >> "$context_file"
            done
        fi
    fi

    # 2. Skill opportunities from module analyses
    echo "=== SKILL OPPORTUNITIES (from deep-dive analysis) ===" >> "$context_file"
    for f in "$WORK_DIR/findings/module-"*.json; do
        if [[ -f "$f" ]]; then
            local mod_name
            mod_name=$(basename "$f" .json | sed 's/^module-//')
            local opportunities
            opportunities=$(jq -r '.skill_opportunities // [] | .[] | "- \(.name): \(.description) [\(.workflow_steps | join(" → "))]"' "$f" 2>/dev/null)
            if [[ -n "$opportunities" ]]; then
                echo "Module $mod_name:" >> "$context_file"
                echo "$opportunities" >> "$context_file"
                echo "" >> "$context_file"
            fi
        fi
    done
    echo "" >> "$context_file"

    # 3. Key files and patterns from module analyses (condensed)
    echo "=== KEY FILES AND PATTERNS PER MODULE ===" >> "$context_file"
    for f in "$WORK_DIR/findings/module-"*.json; do
        if [[ -f "$f" ]]; then
            local mod_name
            mod_name=$(basename "$f" .json | sed 's/^module-//')
            echo "Module $mod_name:" >> "$context_file"
            # Extract just key_files and patterns (skip full architecture/conventions)
            jq -r '
                "  Key files: " + ([.key_files[]? | .path + " (" + .importance + ")"] | join(", ")),
                "  Patterns: " + ([.patterns[]? | .name] | join(", ")),
                "  Gotchas: " + ([.gotchas[]? | .issue] | join("; "))
            ' "$f" 2>/dev/null >> "$context_file"
            echo "" >> "$context_file"
        fi
    done
    echo "" >> "$context_file"

    # 4. Tooling findings (for hooks)
    if [[ -f "$WORK_DIR/findings/tooling.json" ]]; then
        echo "=== TOOLING (use this to decide which hooks to generate) ===" >> "$context_file"
        cat "$WORK_DIR/findings/tooling.json" >> "$context_file"
        echo -e "\n" >> "$context_file"
    fi

    # 5. Security findings (for file protection hooks)
    if [[ -f "$WORK_DIR/findings/security-scan.json" ]]; then
        echo "=== SECURITY (use this for file protection hooks) ===" >> "$context_file"
        cat "$WORK_DIR/findings/security-scan.json" >> "$context_file"
        echo -e "\n" >> "$context_file"
    fi

    # 6. Commands (for workflow skills)
    if [[ -f "$WORK_DIR/findings/commands.json" ]]; then
        echo "=== COMMANDS (use this for workflow and verification skills) ===" >> "$context_file"
        cat "$WORK_DIR/findings/commands.json" >> "$context_file"
        echo -e "\n" >> "$context_file"
    fi

    # 7. Patterns (for reference skills)
    if [[ -f "$WORK_DIR/findings/patterns.json" ]]; then
        echo "=== PATTERNS (use this for reference and scaffolding skills) ===" >> "$context_file"
        cat "$WORK_DIR/findings/patterns.json" >> "$context_file"
        echo -e "\n" >> "$context_file"
    fi

    # 8. MCP discovery
    if [[ -f "$WORK_DIR/findings/mcp-discovery.json" ]]; then
        echo "=== MCP SERVER RECOMMENDATIONS ===" >> "$context_file"
        cat "$WORK_DIR/findings/mcp-discovery.json" >> "$context_file"
        echo -e "\n" >> "$context_file"
    fi

    # 9. Developer answers
    if [[ -f "$WORK_DIR/developer-answers.json" ]]; then
        echo "=== DEVELOPER ANSWERS ===" >> "$context_file"
        cat "$WORK_DIR/developer-answers.json" >> "$context_file"
        echo -e "\n" >> "$context_file"
    fi

    # 10. Project identity
    if [[ -f "$WORK_DIR/findings/identity.json" ]]; then
        echo "=== PROJECT IDENTITY ===" >> "$context_file"
        cat "$WORK_DIR/findings/identity.json" >> "$context_file"
        echo -e "\n" >> "$context_file"
    fi
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

    # Budget: each synthesis pass gets half the synthesis phase budget
    local pass_budget
    pass_budget=$(echo "scale=2; $SYNTH_BUDGET / 2" | bc)

    # Check total budget before starting
    if ! check_budget 2>/dev/null; then
        log_warn "Skipping synthesis pass '$pass_name' (budget exhausted)"
        return 1
    fi

    # Run with up to 3 retries (transient API errors on large-context calls)
    local max_retries=3
    local attempt=0
    local raw_output=""

    while [[ $attempt -lt $max_retries ]]; do
        attempt=$((attempt + 1))
        : > "$stderr_file"

        raw_output=$(cat "$prompt_file" | claude -p - \
            --model "$SYNTH_MODEL" \
            --output-format json \
            --json-schema "$schema" \
            --allowedTools "Read" \
            --append-system-prompt-file "$prompt_file_path" \
            --max-budget-usd "$pass_budget" \
            2>>"$stderr_file") || true

        # Check for API-level errors
        local is_error
        is_error=$(echo "$raw_output" | jq -r '.is_error // false' 2>/dev/null)
        local error_msg
        error_msg=$(echo "$raw_output" | jq -r '.result // ""' 2>/dev/null)

        if [[ "$is_error" != "true" ]] && [[ -n "$raw_output" ]]; then
            break  # success
        fi

        if [[ $attempt -lt $max_retries ]]; then
            log_warn "Synthesis pass '$pass_name' failed (attempt $attempt/$max_retries): ${error_msg:-unknown error}"
            log_progress "Retrying in 10 seconds..."
            sleep 10
        else
            log_error "Synthesis pass '$pass_name' failed after $max_retries attempts: ${error_msg:-unknown error}"
            return 1
        fi
    done

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

    mkdir -p "$WORK_DIR/synthesis"

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
