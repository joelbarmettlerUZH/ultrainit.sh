#!/usr/bin/env bash
# lib/synthesize.sh — Phase 4: Two-pass synthesis

# Ensure unmatched globs expand to nothing (not the literal pattern)
shopt -s nullglob

# Approximate tokens from byte count (chars/4 is a rough estimate)
estimate_tokens() {
    local bytes="$1"
    echo "$(( bytes / 4 ))"
}

synthesize() {
    log_phase "Phase 4: Synthesis"

    if is_phase_complete "synthesize" && [[ "$FORCE" != "true" ]]; then
        log_info "Phase 4 already complete. Use --force to rerun."
        return 0
    fi

    # ── Pass 1: CLAUDE.md files ─────────────────────────────────
    # Gets core findings + condensed module info (architecture, patterns,
    # conventions, gotchas — NOT full key_files, domain_terms, skill_opportunities)

    if [[ -f "$WORK_DIR/synthesis/output-docs.json" ]] && [[ "$FORCE" != "true" ]]; then
        log_info "Pass 1 already complete (output-docs.json exists). Skipping."
    else
        log_progress "Building docs context..."

        local docs_context="$WORK_DIR/synthesis-context-docs.txt"
        build_docs_context "$docs_context"

        local docs_size docs_tokens
        docs_size=$(wc -c < "$docs_context" | tr -d ' ')
        docs_tokens=$(estimate_tokens "$docs_size")
        log_info "Docs context: ${docs_size} bytes (~${docs_tokens} tokens)"

        log_progress "Pass 1/2: Generating CLAUDE.md files (model: $SYNTH_MODEL)..."

        run_synthesis_pass \
            "docs" \
            "$SCRIPT_DIR/schemas/synthesis-docs.json" \
            "$SCRIPT_DIR/prompts/synthesizer-docs.md" \
            "$docs_context" \
            "Generate comprehensive CLAUDE.md files for this codebase." \
            || return 1
    fi

    # ── Pass 2: Skills, hooks, subagents ────────────────────────
    # Gets the generated CLAUDE.md (already distilled) plus only the
    # findings relevant to tooling generation.

    log_progress "Building tooling context..."

    local tooling_context="$WORK_DIR/synthesis-context-tooling.txt"
    build_tooling_context "$tooling_context"

    local tooling_size tooling_tokens
    tooling_size=$(wc -c < "$tooling_context" | tr -d ' ')
    tooling_tokens=$(estimate_tokens "$tooling_size")
    log_info "Tooling context: ${tooling_size} bytes (~${tooling_tokens} tokens)"

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

# ── Build docs context (for Pass 1: CLAUDE.md) ──────────────────
#
# Includes all core findings in full, plus CONDENSED module analyses.
# Condensed = purpose, architecture overview, patterns, conventions,
# gotchas. Excludes: full key_files lists, domain_terms, skill_opportunities,
# detailed dependency lists — those are for Pass 2.

build_docs_context() {
    local context_file="$1"
    : > "$context_file"

    # Core findings (full — these are already compact)
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

    # Module analyses — extract only CLAUDE.md-relevant fields
    echo "=== MODULE ANALYSES ===" >> "$context_file"
    echo "(Condensed: architecture, patterns, conventions, gotchas per module)" >> "$context_file"
    echo "" >> "$context_file"

    for f in "$WORK_DIR/findings/module-"*.json; do
        if [[ -f "$f" ]]; then
            local mod_name
            mod_name=$(basename "$f" .json | sed 's/^module-//')
            echo "--- MODULE: $mod_name ---" >> "$context_file"
            # Extract only what the CLAUDE.md needs
            jq '{
                module_path,
                purpose,
                architecture: {
                    overview: .architecture.overview,
                    subdirectories: .architecture.subdirectories,
                    data_flow: .architecture.data_flow
                },
                patterns,
                conventions,
                gotchas
            }' "$f" 2>/dev/null >> "$context_file"
            echo -e "\n" >> "$context_file"
        fi
    done

    # Developer answers
    if [[ -f "$WORK_DIR/developer-answers.json" ]]; then
        echo "=== DEVELOPER ANSWERS ===" >> "$context_file"
        cat "$WORK_DIR/developer-answers.json" >> "$context_file"
        echo -e "\n" >> "$context_file"
    fi

    # Domain research
    if [[ -f "$WORK_DIR/findings/domain-research.json" ]]; then
        echo "=== DOMAIN RESEARCH ===" >> "$context_file"
        cat "$WORK_DIR/findings/domain-research.json" >> "$context_file"
        echo -e "\n" >> "$context_file"
    fi
}

# ── Build tooling context (for Pass 2: skills/hooks/agents) ─────
#
# Gets the generated CLAUDE.md (already distilled architecture),
# plus focused findings for tooling generation.

build_tooling_context() {
    local context_file="$1"
    : > "$context_file"

    # 1. The generated CLAUDE.md — the distilled source of truth
    local docs_output="$WORK_DIR/synthesis/output-docs.json"
    if [[ -f "$docs_output" ]]; then
        echo "=== GENERATED ROOT CLAUDE.MD (source of truth for architecture and conventions) ===" >> "$context_file"
        jq -r '.claude_md' "$docs_output" >> "$context_file"
        echo -e "\n" >> "$context_file"

        local sub_count
        sub_count=$(jq '.subdirectory_claude_mds // [] | length' "$docs_output")
        if [[ $sub_count -gt 0 ]]; then
            echo "=== GENERATED SUBDIRECTORY CLAUDE.MD FILES ===" >> "$context_file"
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

    # 3. Key files and patterns per module (condensed)
    echo "=== KEY FILES AND PATTERNS PER MODULE ===" >> "$context_file"
    for f in "$WORK_DIR/findings/module-"*.json; do
        if [[ -f "$f" ]]; then
            local mod_name
            mod_name=$(basename "$f" .json | sed 's/^module-//')
            echo "Module $mod_name:" >> "$context_file"
            jq -r '
                "  Key files: " + ([.key_files[]? | .path + " (" + .importance + ")"] | join(", ")),
                "  Patterns: " + ([.patterns[]? | .name] | join(", ")),
                "  Gotchas: " + ([.gotchas[]? | .issue] | join("; "))
            ' "$f" 2>/dev/null >> "$context_file"
            echo "" >> "$context_file"
        fi
    done
    echo "" >> "$context_file"

    # 4. Tooling (for hooks)
    if [[ -f "$WORK_DIR/findings/tooling.json" ]]; then
        echo "=== TOOLING (use for deciding which hooks to generate) ===" >> "$context_file"
        cat "$WORK_DIR/findings/tooling.json" >> "$context_file"
        echo -e "\n" >> "$context_file"
    fi

    # 5. Security (for file protection hooks)
    if [[ -f "$WORK_DIR/findings/security-scan.json" ]]; then
        echo "=== SECURITY (use for file protection hooks) ===" >> "$context_file"
        cat "$WORK_DIR/findings/security-scan.json" >> "$context_file"
        echo -e "\n" >> "$context_file"
    fi

    # 6. Commands (for workflow skills)
    if [[ -f "$WORK_DIR/findings/commands.json" ]]; then
        echo "=== COMMANDS (use for workflow and verification skills) ===" >> "$context_file"
        cat "$WORK_DIR/findings/commands.json" >> "$context_file"
        echo -e "\n" >> "$context_file"
    fi

    # 7. Patterns (for reference skills)
    if [[ -f "$WORK_DIR/findings/patterns.json" ]]; then
        echo "=== PATTERNS (use for reference and scaffolding skills) ===" >> "$context_file"
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

    local prompt_size prompt_tokens
    prompt_size=$(wc -c < "$prompt_file" | tr -d ' ')
    prompt_tokens=$(estimate_tokens "$prompt_size")
    log_info "Prompt for '$pass_name': ${prompt_size} bytes (~${prompt_tokens} tokens)"

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
    local max_retries="${ULTRAINIT_MAX_RETRIES:-3}"
    local attempt=0
    local raw_output=""

    local output_tmpfile="$WORK_DIR/logs/synthesis-${pass_name}.stdout"

    while [[ $attempt -lt $max_retries ]]; do
        attempt=$((attempt + 1))
        : > "$stderr_file"
        : > "$output_tmpfile"

        run_with_spinner \
            "Synthesis pass '$pass_name' running (attempt $attempt)..." \
            "$output_tmpfile" \
            "$stderr_file" \
            bash -c "cat '$prompt_file' | claude -p - \
                --model '$SYNTH_MODEL' \
                --output-format json \
                --json-schema '$schema' \
                --allowedTools 'Read' \
                --append-system-prompt-file '$prompt_file_path' \
                --max-budget-usd '$pass_budget'" \
            || true

        raw_output=$(cat "$output_tmpfile")

        # claude --output-format json returns a JSON array; extract the last element
        local result_envelope
        result_envelope=$(echo "$raw_output" | jq 'if type == "array" then .[-1] else . end' 2>/dev/null)

        # Check for API-level errors
        local is_error
        is_error=$(echo "$result_envelope" | jq -r '.is_error // false' 2>/dev/null)
        local error_msg
        error_msg=$(echo "$result_envelope" | jq -r '
            (if (.errors // [] | length) > 0 then (.errors | join("; "))
             elif .result then .result
             else "" end)
        ' 2>/dev/null)

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
    mkdir -p "$WORK_DIR/synthesis"
    echo "$result_envelope" | jq '.structured_output // .result // .' \
        > "$WORK_DIR/synthesis/output-${pass_name}.json" 2>/dev/null

    if ! jq -e 'type == "object"' "$WORK_DIR/synthesis/output-${pass_name}.json" >/dev/null 2>&1; then
        log_error "Synthesis pass '$pass_name' did not produce structured output"
        echo "Raw: $raw_output" >> "$stderr_file"
        return 1
    fi

    # Track cost
    local cost
    cost=$(echo "$result_envelope" | jq -r '.total_cost_usd // 0' 2>/dev/null)
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

postprocess_descriptions() {
    local output_file="$1"
    local tmp_file="${output_file}.tmp"
    local fixed=0

    local skill_count
    skill_count=$(jq '.skills // [] | length' "$output_file")

    for i in $(seq 0 $((skill_count - 1))); do
        local content
        content=$(jq -r ".skills[$i].content" "$output_file")

        if echo "$content" | awk '/^description:/,/^([a-z]|---)/' | grep -q '[<>]'; then
            local new_content
            new_content=$(echo "$content" | awk '
                /^description:/ { in_desc=1 }
                in_desc && (/^[a-z]/ || /^---/) && !/^description:/ { in_desc=0 }
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

        if echo "$content" | awk '/^description:/,/^([a-z]|---)/' | grep -q '[<>]'; then
            local new_content
            new_content=$(echo "$content" | awk '
                /^description:/ { in_desc=1 }
                in_desc && (/^[a-z]/ || /^---/) && !/^description:/ { in_desc=0 }
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
