#!/usr/bin/env bash
# lib/validate.sh — Phase 5a: Validate generated artifacts

validate_artifacts() {
    log_phase "Phase 5a: Validating artifacts"

    local output="$WORK_DIR/synthesis/output.json"
    local issues_file="$WORK_DIR/logs/validation-issues.txt"
    : > "$issues_file"
    local errors=0

    # ── Validate CLAUDE.md ──────────────────────────────────────

    validate_claude_md "$output" "$issues_file"
    errors=$((errors + $?))

    # ── Validate skills (write to temp files, run validator) ────

    local skill_count
    skill_count=$(jq '.skills // [] | length' "$output")
    log_info "Skills generated: $skill_count"

    if [[ $skill_count -lt 5 ]]; then
        echo "Only $skill_count skills generated (expected 10+). Major workflows likely missing." >> "$issues_file"
        log_warn "Only $skill_count skills generated (expected 10+)"
        errors=$((errors + 1))
    fi

    for i in $(seq 0 $((skill_count - 1))); do
        local skill_name
        skill_name=$(jq -r ".skills[$i].name" "$output")

        # Write skill to temp dir for validation
        local tmp_skill_dir="$WORK_DIR/validation/skills/$skill_name"
        mkdir -p "$tmp_skill_dir"
        jq -r ".skills[$i].content" "$output" > "$tmp_skill_dir/SKILL.md"

        # Run structural validator
        local skill_result
        if skill_result=$(bash "$SCRIPT_DIR/scripts/validate-skill.sh" "$tmp_skill_dir/SKILL.md" 2>&1); then
            log_success "Skill $skill_name: PASS"
        else
            local skill_errors
            skill_errors=$(echo "$skill_result" | grep -c '^ERROR:' || true)
            local skill_warnings
            skill_warnings=$(echo "$skill_result" | grep -c '^WARNING:' || true)

            if [[ $skill_errors -gt 0 ]]; then
                echo "Skill $skill_name: $skill_errors error(s)" >> "$issues_file"
                echo "$skill_result" | grep '^ERROR:' >> "$issues_file"
                log_warn "Skill $skill_name: FAIL ($skill_errors errors, $skill_warnings warnings)"
                errors=$((errors + skill_errors))
            else
                log_info "Skill $skill_name: $skill_warnings warning(s)"
            fi
        fi
    done

    # ── Validate hooks ──────────────────────────────────────────

    local hook_count
    hook_count=$(jq '.hooks // [] | length' "$output")
    log_info "Hooks generated: $hook_count"

    for i in $(seq 0 $((hook_count - 1))); do
        validate_hook "$output" "$i" "$issues_file"
        errors=$((errors + $?))
    done

    # ── Validate subagents ──────────────────────────────────────

    local agent_count
    agent_count=$(jq '.subagents // [] | length' "$output")
    if [[ $agent_count -gt 0 ]]; then
        log_info "Subagents generated: $agent_count"

        for i in $(seq 0 $((agent_count - 1))); do
            local agent_name
            agent_name=$(jq -r ".subagents[$i].name" "$output")

            # Write agent to temp file for validation
            mkdir -p "$WORK_DIR/validation/agents"
            jq -r ".subagents[$i].content" "$output" > "$WORK_DIR/validation/agents/${agent_name}.md"

            local agent_result
            if agent_result=$(bash "$SCRIPT_DIR/scripts/validate-subagent.sh" "$WORK_DIR/validation/agents/${agent_name}.md" 2>&1); then
                log_success "Subagent $agent_name: PASS"
            else
                local agent_errors
                agent_errors=$(echo "$agent_result" | grep -c '^ERROR:' || true)
                if [[ $agent_errors -gt 0 ]]; then
                    echo "Subagent $agent_name: $agent_errors error(s)" >> "$issues_file"
                    echo "$agent_result" | grep '^ERROR:' >> "$issues_file"
                    log_warn "Subagent $agent_name: FAIL ($agent_errors errors)"
                    errors=$((errors + agent_errors))
                else
                    local agent_warnings
                    agent_warnings=$(echo "$agent_result" | grep -c '^WARNING:' || true)
                    log_info "Subagent $agent_name: $agent_warnings warning(s)"
                fi
            fi
        done
    fi

    # ── Validate hook wiring ────────────────────────────────────

    validate_hook_wiring "$output" "$issues_file"
    errors=$((errors + $?))

    # ── Summary ─────────────────────────────────────────────────

    if [[ $errors -gt 0 ]]; then
        log_warn "$errors validation issue(s) found"
        run_revision_agent "$issues_file"
        return $?
    fi

    log_success "All artifacts passed validation"
    return 0
}

# ── CLAUDE.md validation ────────────────────────────────────────

validate_claude_md() {
    local output="$1"
    local issues_file="$2"
    local err=0

    local claude_md
    claude_md=$(jq -r '.claude_md' "$output")

    # Line count (informational, no hard limit)
    local lines
    lines=$(echo "$claude_md" | wc -l)
    if [[ $lines -lt 50 ]]; then
        echo "CLAUDE.md is only $lines lines — likely too thin. Should be 100+ lines for a real project." >> "$issues_file"
        log_warn "CLAUDE.md is only $lines lines (expected 100+)"
        err=$((err + 1))
    else
        log_success "CLAUDE.md: $lines lines"
    fi

    # Generic phrases
    local generic_count
    generic_count=$(echo "$claude_md" | grep -ciE '(best practice|clean code|solid principle|maintainable|readable|scalable|well-structured|production.ready|industry standard)' || true)
    if [[ $generic_count -gt 3 ]]; then
        echo "CLAUDE.md contains $generic_count generic phrases (max 3)" >> "$issues_file"
        log_warn "CLAUDE.md contains $generic_count generic phrase(s)"
        err=$((err + 1))
    elif [[ $generic_count -gt 0 ]]; then
        log_info "CLAUDE.md contains $generic_count generic phrase(s) (acceptable)"
    fi

    # Command blocks or tables (must have at least one)
    local has_commands
    has_commands=$(echo "$claude_md" | grep -cE '(```|^\|.*\|.*\|)' || true)
    if [[ $has_commands -lt 1 ]]; then
        echo "CLAUDE.md has no code blocks or command tables" >> "$issues_file"
        log_warn "CLAUDE.md has no code blocks or command tables"
        err=$((err + 1))
    fi

    # Prohibitions without alternatives
    local prohibitions
    prohibitions=$(echo "$claude_md" | grep -ciE '(never |don.t |do not )' || true)
    local alternatives
    alternatives=$(echo "$claude_md" | grep -ciE '(instead|use .* instead|prefer |create new)' || true)
    if [[ $prohibitions -gt 0 ]] && [[ $alternatives -eq 0 ]]; then
        echo "CLAUDE.md has $prohibitions prohibitions but no alternatives" >> "$issues_file"
        log_warn "CLAUDE.md has prohibitions without alternatives"
        err=$((err + 1))
    fi

    return $err
}

# ── Hook validation ─────────────────────────────────────────────

validate_hook() {
    local output="$1"
    local index="$2"
    local issues_file="$3"
    local err=0

    local hook_name
    hook_name=$(jq -r ".hooks[$index].filename" "$output")
    local hook_content
    hook_content=$(jq -r ".hooks[$index].content" "$output")

    # Shebang
    if ! echo "$hook_content" | head -1 | grep -q '^#!/'; then
        echo "Hook $hook_name: missing shebang" >> "$issues_file"
        log_warn "Hook $hook_name: missing shebang"
        err=$((err + 1))
    fi

    # set -euo pipefail
    if ! echo "$hook_content" | grep -q 'set -euo pipefail'; then
        echo "Hook $hook_name: missing 'set -euo pipefail'" >> "$issues_file"
        log_warn "Hook $hook_name: missing set -euo pipefail"
        err=$((err + 1))
    fi

    # Reads from stdin
    if ! echo "$hook_content" | grep -qE '(cat$|cat\)|read |stdin)'; then
        echo "Hook $hook_name: doesn't appear to read JSON from stdin" >> "$issues_file"
        log_warn "Hook $hook_name: may not read stdin"
        err=$((err + 1))
    fi

    # Blocking hooks must have actionable error messages
    if echo "$hook_content" | grep -q 'exit 2'; then
        if ! echo "$hook_content" | grep -qE '(echo|>&2)'; then
            echo "Hook $hook_name: exit 2 (blocking) without error message" >> "$issues_file"
            log_warn "Hook $hook_name: blocks without error message"
            err=$((err + 1))
        fi
    fi

    if [[ $err -eq 0 ]]; then
        log_success "Hook $hook_name: PASS"
    fi

    return $err
}

# ── Hook wiring validation ──────────────────────────────────────

validate_hook_wiring() {
    local output="$1"
    local issues_file="$2"
    local err=0

    local hook_count
    hook_count=$(jq '.hooks // [] | length' "$output")
    local wiring_count
    wiring_count=$(jq '.settings_hooks // [] | length' "$output")

    if [[ $hook_count -gt 0 ]] && [[ $wiring_count -eq 0 ]]; then
        echo "Generated $hook_count hook(s) but no settings_hooks wiring" >> "$issues_file"
        log_warn "$hook_count hook(s) generated but no settings_hooks wiring"
        err=$((err + 1))
    fi

    return $err
}

# ── Revision agent ──────────────────────────────────────────────

run_revision_agent() {
    local issues_file="$1"
    local issues
    issues=$(cat "$issues_file")

    log_progress "Running revision agent to fix issues..."

    local schema
    schema=$(cat "$SCRIPT_DIR/schemas/synthesis-output.json")

    local stderr_file="$WORK_DIR/logs/revision.stderr"

    # Build revision prompt as a file (output.json can be very large)
    local revision_prompt_file="$WORK_DIR/revision-prompt.txt"
    cat > "$revision_prompt_file" <<REVISION_HEADER
These generated Claude Code artifacts have validation issues. Fix ONLY the issues listed below. Do NOT change anything that passed validation.

ISSUES:
$issues

CURRENT ARTIFACTS:
REVISION_HEADER
    cat "$WORK_DIR/synthesis/output.json" >> "$revision_prompt_file"
    cat >> "$revision_prompt_file" <<'REVISION_FOOTER'

Fix all issues and return the corrected artifacts. Key rules:
- CLAUDE.md must contain ZERO generic phrases (best practice, clean code, SOLID, maintainable, readable, scalable, well-structured, production-ready, industry standard)
- Every prohibition must include an alternative
- Skill descriptions must NOT contain XML angle brackets (< or >) — use quotes or parentheses instead
- Skills must have ≥3 codebase-specific file references, kebab-case name, description with trigger phrases + negative scope
- Hooks must have shebang + set -euo pipefail, read stdin, and print actionable errors on exit 2
- Every hook script must have a matching settings_hooks entry
REVISION_FOOTER

    local raw_output
    raw_output=$(cat "$revision_prompt_file" | claude -p - \
        --model sonnet \
        --output-format json \
        --json-schema "$schema" \
        --allowedTools "Read" \
        --max-budget-usd "$VALIDATION_BUDGET" \
        2>>"$stderr_file")

    local exit_code=$?

    if [[ $exit_code -ne 0 ]]; then
        log_warn "Revision agent failed (exit $exit_code). Proceeding with original artifacts."
        return 0
    fi

    # Track cost
    local rev_cost
    rev_cost=$(echo "$raw_output" | jq -r '.total_cost_usd // 0' 2>/dev/null)
    record_cost "validate" "revision" "$rev_cost"

    local is_error
    is_error=$(echo "$raw_output" | jq -r '.is_error // false' 2>/dev/null)
    if [[ "$is_error" == "true" ]]; then
        log_warn "Revision agent returned an error. Proceeding with original artifacts."
        return 0
    fi

    # Extract and validate revised output
    local revised
    revised=$(echo "$raw_output" | jq '.structured_output // .result // .')

    if echo "$revised" | jq -e 'type == "object" and .claude_md' >/dev/null 2>&1; then
        echo "$revised" > "$WORK_DIR/synthesis/output.json"
        log_success "Artifacts revised successfully"
    else
        log_warn "Revision produced invalid output. Proceeding with original artifacts."
    fi

    return 0
}
