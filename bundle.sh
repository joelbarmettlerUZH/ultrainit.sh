#!/usr/bin/env bash
set -euo pipefail
#
# bundle.sh — Bundles all ultrainit source files into a single self-contained script.
#
# Usage: ./bundle.sh > dist/ultrainit.sh
#
# The bundled script extracts everything to a temp dir, then execs ultrainit.sh from there.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Header: the self-extracting bootstrap ────────��──────────────

cat <<'BOOTSTRAP'
#!/usr/bin/env bash
set -euo pipefail
#
# ultrainit — Deep codebase analysis for Claude Code configuration
# This is a bundled, self-contained version.
#
# Usage:
#   curl -sL https://raw.githubusercontent.com/joelbarmettlerUZH/ultrainit/main/ultrainit.sh | bash
#   # or with options:
#   bash <(curl -sL https://raw.githubusercontent.com/joelbarmettlerUZH/ultrainit/main/ultrainit.sh) --non-interactive /path/to/project
#

BUNDLE_DIR=$(mktemp -d "${TMPDIR:-/tmp}/ultrainit.XXXXXX")
trap 'rm -rf "$BUNDLE_DIR"' EXIT

mkdir -p "$BUNDLE_DIR"/{lib,prompts,schemas,scripts}

# ── Extract embedded files ──────────────────────────────────────
BOOTSTRAP

# ── Embed lib/*.sh ──────────────────────────────────────────────

for f in "$SCRIPT_DIR"/lib/*.sh; do
    name=$(basename "$f")
    # Use a unique delimiter per file to avoid collisions
    delim="__EOF_LIB_${name%.*}__"
    echo "cat > \"\$BUNDLE_DIR/lib/$name\" <<'$delim'"
    cat "$f"
    echo ""
    echo "$delim"
    echo ""
done

# ── Embed prompts/*.md ──────────────────────────────────────────

for f in "$SCRIPT_DIR"/prompts/*.md; do
    name=$(basename "$f")
    delim="__EOF_PROMPT_${name%.md}__"
    echo "cat > \"\$BUNDLE_DIR/prompts/$name\" <<'$delim'"
    cat "$f"
    echo ""
    echo "$delim"
    echo ""
done

# ── Embed schemas/*.json ───────────────────────────────────────

for f in "$SCRIPT_DIR"/schemas/*.json; do
    name=$(basename "$f")
    delim="__EOF_SCHEMA_${name%.json}__"
    echo "cat > \"\$BUNDLE_DIR/schemas/$name\" <<'$delim'"
    cat "$f"
    echo ""
    echo "$delim"
    echo ""
done

# ── Embed scripts/*.sh ─────────────────────────────────────────

for f in "$SCRIPT_DIR"/scripts/*.sh; do
    [[ -f "$f" ]] || continue
    name=$(basename "$f")
    delim="__EOF_SCRIPT_${name%.*}__"
    echo "cat > \"\$BUNDLE_DIR/scripts/$name\" <<'$delim'"
    cat "$f"
    echo ""
    echo "$delim"
    echo "chmod +x \"\$BUNDLE_DIR/scripts/$name\""
    echo ""
done

# ── Embed ultrainit.sh itself ──────────────────────────────────

echo 'cat > "$BUNDLE_DIR/ultrainit.sh" <<'"'"'__EOF_MAIN__'"'"''
cat "$SCRIPT_DIR/ultrainit.sh"
echo ""
echo '__EOF_MAIN__'
echo 'chmod +x "$BUNDLE_DIR/ultrainit.sh"'
echo ''

# ── Launch ──────────────────────────────────────────────────────

cat <<'LAUNCH'
# Pass through all arguments to the extracted script
exec bash "$BUNDLE_DIR/ultrainit.sh" "$@"
LAUNCH
