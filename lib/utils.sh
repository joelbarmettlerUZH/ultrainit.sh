#!/usr/bin/env bash
# lib/utils.sh — Logging, JSON helpers, phase tracking

# Colors (disabled if not a terminal)
if [[ -t 1 ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    CYAN='\033[0;36m'
    BOLD='\033[1m'
    RESET='\033[0m'
else
    RED='' GREEN='' YELLOW='' BLUE='' CYAN='' BOLD='' RESET=''
fi

log_info()     { echo -e "${BLUE}[info]${RESET}    $*"; }
log_success()  { echo -e "${GREEN}[ok]${RESET}      $*"; }
log_warn()     { echo -e "${YELLOW}[warn]${RESET}    $*"; }
log_error()    { echo -e "${RED}[error]${RESET}   $*" >&2; }
log_phase()    { echo -e "\n${BOLD}${CYAN}━━━ $* ━━━${RESET}\n"; }
log_progress() { echo -e "${CYAN}[...]${RESET}    $*"; }

# ── Phase tracking ──────────────────────────────────────────────

mark_phase_complete() {
    local phase="$1"
    local state_file="$WORK_DIR/state.json"

    if [[ ! -f "$state_file" ]] || ! jq empty "$state_file" 2>/dev/null; then
        echo '{}' > "$state_file"
    fi

    local tmp
    tmp=$(jq --arg p "$phase" --arg t "$(date -Iseconds 2>/dev/null || date +%Y-%m-%dT%H:%M:%S)" \
        '.[$p] = $t' "$state_file")

    # Only write if jq produced valid output (prevents destroying state on failure)
    if [[ -n "$tmp" ]] && echo "$tmp" | jq empty 2>/dev/null; then
        echo "$tmp" > "$state_file"
    fi
}

is_phase_complete() {
    local phase="$1"
    local state_file="$WORK_DIR/state.json"

    [[ -f "$state_file" ]] && jq -e --arg p "$phase" '.[$p] // empty' "$state_file" >/dev/null 2>&1
}

# ── JSON helpers ────────────────────────────────────────────────

# Read a key from a JSON file, returning empty string on failure
json_get() {
    local file="$1"
    local key="$2"
    jq -r "$key // empty" "$file" 2>/dev/null || echo ""
}

# Merge two JSON objects (stdin + file), stdout
json_merge() {
    local file="$1"
    jq -s '.[0] * .[1]' - "$file"
}

# ── Progress display ────────────────────────────────────────────

# Show a spinner while a PID is running
spin() {
    local pid="$1"
    local label="${2:-Working}"
    local chars='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
    local i=0

    # Only show spinner in interactive terminals
    if [[ ! -t 1 ]]; then
        wait "$pid" 2>/dev/null
        return $?
    fi

    while kill -0 "$pid" 2>/dev/null; do
        printf "\r${CYAN}%s${RESET} %s " "${chars:i%${#chars}:1}" "$label"
        i=$((i + 1))
        sleep 0.1
    done
    printf "\r"

    wait "$pid" 2>/dev/null
    return $?
}

# ── Misc ────────────────────────────────────────────────────────

# Portable date -Iseconds (works on macOS with coreutils or fallback)
iso_date() {
    date -Iseconds 2>/dev/null || date +%Y-%m-%dT%H:%M:%S%z
}

# ── Cost reporting ──────────────────────────────────────────────

print_cost_summary() {
    local cost_dir="$WORK_DIR/costs"
    [[ ! -d "$cost_dir" ]] && return 0

    # Guard against nullglob: *.cost expands to nothing if no files exist,
    # which would make cat block on stdin.
    local cost_files=("$cost_dir"/*.cost)
    [[ ${#cost_files[@]} -eq 0 || ! -f "${cost_files[0]}" ]] && return 0

    echo -e "\n${BOLD}Cost breakdown:${RESET}"

    local total=0
    local current_phase=""
    local phase_sum=0

    while IFS='|' read -r phase agent cost; do
        [[ -z "$cost" || "$cost" == "0" || "$cost" == "null" ]] && continue

        if [[ "$phase" != "$current_phase" ]]; then
            if [[ -n "$current_phase" ]]; then
                printf "  %-12s \$%.4f\n" "$current_phase:" "$phase_sum"
            fi
            current_phase="$phase"
            phase_sum=0
        fi
        phase_sum=$(echo "$phase_sum + $cost" | bc 2>/dev/null || echo "$phase_sum")
        total=$(echo "$total + $cost" | bc 2>/dev/null || echo "$total")
    done < <(cat "${cost_files[@]}" 2>/dev/null | sort)

    # Print last phase
    if [[ -n "$current_phase" ]]; then
        printf "  %-12s \$%.4f\n" "$current_phase:" "$phase_sum"
    fi

    echo -e "  ${BOLD}────────────────────${RESET}"
    printf "  ${BOLD}%-12s \$%.4f${RESET}\n" "Total:" "$total"
}
