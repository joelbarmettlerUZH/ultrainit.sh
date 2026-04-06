#!/usr/bin/env bash
# lib/ask.sh — Phase 2: Interactive developer questions

# Ask a question with an optional proposed answer.
# Usage: ask_question <variable_name> <question> [proposed_answer]
# Reads from fd 3 (set up in ask_developer).
ask_question() {
    local var_name="$1"
    local question="$2"
    local proposed="${3:-}"

    echo ""
    echo -e "${BOLD}$question${RESET}"
    if [[ -n "$proposed" ]]; then
        echo -e "  ${CYAN}Proposed:${RESET} $proposed"
        read -rp "  Your answer (Enter to accept, or type your own): " answer <&3
        answer="${answer:-$proposed}"
    else
        read -rp "  Your answer (Enter to skip): " answer <&3
    fi

    eval "$var_name=\$answer"
}

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
            exec 3</dev/tty
        else
            log_warn "No terminal available for interactive questions. Skipping."
            echo '{}' > "$answers_file"
            mark_phase_complete "ask"
            return 0
        fi
    else
        exec 3<&0
    fi

    local answers="{}"

    echo ""
    echo "━━━ I have a few questions that code analysis can't answer ━━━"
    echo "    (These help generate better configuration. Enter to skip any.)"

    # Detect project description from Phase 1
    local identity_desc=""
    if [[ -f "$WORK_DIR/findings/identity.json" ]]; then
        identity_desc=$(jq -r '.description // empty' "$WORK_DIR/findings/identity.json" 2>/dev/null)
    fi

    local purpose deploy services never_do mistakes extra

    ask_question purpose \
        "In one sentence, what does this project do?" \
        "$identity_desc"
    answers=$(echo "$answers" | jq --arg v "$purpose" '.project_purpose = $v')

    ask_question deploy \
        "How is this deployed? (e.g., Docker, Vercel, AWS ECS, Kubernetes, bare metal)"
    answers=$(echo "$answers" | jq --arg v "$deploy" '.deployment_target = $v')

    ask_question never_do \
        "What should Claude NEVER do? (e.g., edit migrations, bypass auth, delete user data)"
    answers=$(echo "$answers" | jq --arg v "$never_do" '.never_do = $v')

    ask_question mistakes \
        "What trips up new developers on this project?"
    answers=$(echo "$answers" | jq --arg v "$mistakes" '.common_mistakes = $v')

    ask_question extra \
        "Anything else important? (team conventions, quirks, things the code won't tell you)"
    answers=$(echo "$answers" | jq --arg v "$extra" '.additional_context = $v')

    exec 3<&-

    echo ""
    echo "$answers" > "$answers_file"
    log_success "Developer answers saved"
    mark_phase_complete "ask"
}
