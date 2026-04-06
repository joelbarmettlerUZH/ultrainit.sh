#!/usr/bin/env bash
# lib/config.sh — Dependency checks, defaults, platform detection

# ── Defaults (overridable via env or CLI flags) ─────────────────

export FORCE="${FORCE:-false}"
export NON_INTERACTIVE="${NON_INTERACTIVE:-false}"
export VERBOSE="${VERBOSE:-false}"
export DRY_RUN="${DRY_RUN:-false}"
export SKIP_RESEARCH="${SKIP_RESEARCH:-false}"
export SKIP_MCP="${SKIP_MCP:-false}"
export OVERWRITE="${OVERWRITE:-false}"

export AGENT_MODEL="${ULTRAINIT_MODEL:-sonnet}"
export AGENT_BUDGET="${ULTRAINIT_BUDGET:-5.00}"
export SYNTH_MODEL="${SYNTH_MODEL:-sonnet[1m]}"
export SYNTH_BUDGET="${SYNTH_BUDGET:-20.00}"

# ── Platform detection ──────────────────────────────────────────

detect_platform() {
    case "$(uname -s)" in
        Darwin)  PLATFORM="macos" ;;
        Linux)   PLATFORM="linux" ;;
        MINGW*|MSYS*|CYGWIN*)  PLATFORM="windows" ;;
        *)       PLATFORM="unknown" ;;
    esac
    export PLATFORM
}

# ── Dependency checks ──────────────────────────────────────────

check_dependencies() {
    local missing=0

    if ! command -v claude &>/dev/null; then
        log_error "claude CLI not found. Install: https://docs.anthropic.com/en/docs/claude-code/overview"
        missing=1
    fi

    if ! command -v jq &>/dev/null; then
        log_error "jq not found."
        case "$PLATFORM" in
            macos)   log_error "  Install: brew install jq" ;;
            linux)   log_error "  Install: sudo apt install jq  (or your package manager)" ;;
            windows) log_error "  Install: choco install jq  (in Git Bash)" ;;
        esac
        missing=1
    fi

    if [[ $missing -ne 0 ]]; then
        exit 1
    fi
}

# ── Working directory setup ─────────────────────────────────────

setup_work_dir() {
    local target_dir="$1"
    WORK_DIR="${target_dir}/.ultrainit"
    export WORK_DIR

    mkdir -p "$WORK_DIR"/{findings/modules,synthesis/skills,synthesis/hooks,synthesis/subagents,logs,backups}

    # Add .ultrainit/ to .gitignore if not present
    if [[ -f "${target_dir}/.gitignore" ]]; then
        if ! grep -q '\.ultrainit' "${target_dir}/.gitignore" 2>/dev/null; then
            echo '.ultrainit/' >> "${target_dir}/.gitignore"
        fi
    else
        echo '.ultrainit/' > "${target_dir}/.gitignore"
    fi

    # Initialize state file if missing
    if [[ ! -f "$WORK_DIR/state.json" ]]; then
        echo '{}' > "$WORK_DIR/state.json"
    fi
}
