#!/usr/bin/env bash
# lib/ask.sh — Phase 2: Interactive developer questions

ask_developer() {
    log_phase "Phase 2: Developer interview"

    if is_phase_complete "ask" && [[ "$FORCE" != "true" ]]; then
        log_info "Phase 2 already complete. Use --force to rerun."
        return 0
    fi

    local answers_file="$WORK_DIR/developer-answers.json"

    if [[ "$NON_INTERACTIVE" == "true" ]]; then
        log_info "Non-interactive mode. Skipping developer questions."
        echo '{}' > "$answers_file"
        mark_phase_complete "ask"
        return 0
    fi

    # When piped from curl, stdin is the pipe — we must read from /dev/tty
    if [[ ! -t 0 ]]; then
        if [[ -e /dev/tty ]]; then
            exec 3</dev/tty  # open fd 3 from tty
        else
            log_warn "No terminal available for interactive questions. Skipping."
            echo '{}' > "$answers_file"
            mark_phase_complete "ask"
            return 0
        fi
    else
        exec 3<&0  # fd 3 = stdin (already a terminal)
    fi

    local answers="{}"

    echo ""
    echo "━━━ I have a few questions that code analysis can't answer ━━━"
    echo ""

    # Question 1: Project purpose
    local identity_desc=""
    if [[ -f "$WORK_DIR/findings/identity.json" ]]; then
        identity_desc=$(jq -r '.description // empty' "$WORK_DIR/findings/identity.json" 2>/dev/null)
    fi

    if [[ -n "$identity_desc" ]]; then
        echo "What is the primary purpose of this project?"
        read -rp "  [${identity_desc}]: " purpose <&3
        purpose="${purpose:-$identity_desc}"
    else
        read -rp "What is the primary purpose of this project? " purpose <&3
    fi
    answers=$(echo "$answers" | jq --arg v "$purpose" '.project_purpose = $v')

    # Question 2: Deployment target
    echo ""
    read -rp "Where is this deployed? (e.g., Vercel, AWS, self-hosted Docker, or Enter to skip): " deploy <&3
    answers=$(echo "$answers" | jq --arg v "$deploy" '.deployment_target = $v')

    # Question 3: External services
    echo ""
    read -rp "External services/APIs this integrates with? (comma-separated, or Enter to skip): " services <&3
    answers=$(echo "$answers" | jq --arg v "$services" '.external_services = $v')

    # Question 4: What Claude should NEVER do
    echo ""
    echo "What should Claude NEVER do in this codebase?"
    echo "(e.g., 'never modify migrations directly', 'never bypass auth')"
    read -rp "> " never_do <&3
    answers=$(echo "$answers" | jq --arg v "$never_do" '.never_do = $v')

    # Question 5: Common mistakes
    echo ""
    read -rp "Common mistakes new developers make? (or Enter to skip): " mistakes <&3
    answers=$(echo "$answers" | jq --arg v "$mistakes" '.common_mistakes = $v')

    # Question 6: Anything else
    echo ""
    read -rp "Anything else Claude should know about this project? (or Enter to skip): " extra <&3
    answers=$(echo "$answers" | jq --arg v "$extra" '.additional_context = $v')

    exec 3<&-  # close fd 3

    echo ""
    echo "$answers" > "$answers_file"
    log_success "Developer answers saved"
    mark_phase_complete "ask"
}
