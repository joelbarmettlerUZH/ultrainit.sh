---
name: bundle-and-verify
description: "
  Build the single-file distributable ultrainit.sh bundle and verify it is
  correct before release. Use when build the bundle, create the release
  artifact, verify bundle.sh works, check the bundle size, or test the
  self-extracting script. Do NOT push a release tag after this — use
  release-ultrainit for the full release flow including user confirmation.
---

## Before You Start

- `bundle.sh` — the bundler; embeds all `lib/`, `prompts/`, `schemas/`, `scripts/` as heredocs
- `Makefile` — `bundle` and `clean` targets
- `dist/ultrainit.sh` — the output artifact (gitignored)
- `.github/workflows/release.yml` — runs `bash bundle.sh > dist/ultrainit.sh` at release time

## Steps

### 1. Run quality checks first

```bash
make check
```

Do not build a bundle from code that fails syntax checks.

### 2. Check for delimiter conflicts

`bundle.sh` embeds files as heredocs with `__EOF_LIB_<name>__` delimiters. If any embedded file contains this exact pattern on a line, the heredoc terminates early:

```bash
grep -rn '__EOF_LIB_' lib/ scripts/ prompts/ schemas/ 2>/dev/null
```

If any matches are found, the files with those matches cannot be safely bundled until the pattern is removed.

### 3. Build the bundle

```bash
mkdir -p dist
bash bundle.sh > dist/ultrainit.sh
chmod +x dist/ultrainit.sh
```

**Critical**: `bundle.sh` must write ONLY bundle content to stdout. Any `echo`, `log_*`, or debug output in `bundle.sh` corrupts the bundle. The `release.yml` workflow does `bash bundle.sh > dist/ultrainit.sh` — spurious stdout becomes part of the script.

### 4. Syntax-check the bundle

```bash
bash -n dist/ultrainit.sh && echo "syntax OK"
```

Failure here usually means a heredoc delimiter collision or a syntax error introduced during bundling.

### 5. Check bundle size

```bash
du -sh dist/ultrainit.sh
wc -l dist/ultrainit.sh
```

Expected range: 2,000-8,000 lines depending on prompt and schema content. A dramatically smaller bundle (< 1,000 lines) suggests a delimiter collision truncated the output.

### 6. Test self-extraction

```bash
# Test --help in an isolated tmpdir
tmpdir=$(mktemp -d)
bash dist/ultrainit.sh --help
rm -rf "$tmpdir"
```

Self-extraction should emit the usage message without error.

### 7. Clean up

```bash
make clean  # removes dist/ultrainit.sh
```

Or keep `dist/ultrainit.sh` if you need it for manual testing.

## Verify

```bash
bash -n dist/ultrainit.sh          # syntax
du -sh dist/ultrainit.sh            # size sanity
bash dist/ultrainit.sh --help       # self-extraction
```

## Common Mistakes

1. **Forgetting `stdout` purity in `bundle.sh`** — any diagnostic output in `bundle.sh` corrupts the artifact. The bundle is always produced via stdout redirect (`bash bundle.sh > dist/ultrainit.sh`), so stdout is the output.

2. **Skipping the delimiter conflict check** — low probability but high impact. A match produces a silently truncated bundle that passes `bash -n` on the truncated portion but fails at runtime when trying to source missing content.

3. **Not running `make check` first** — `bash -n dist/ultrainit.sh` only checks the bundle's wrapper script syntax, not the syntax of embedded files. Catch embedded syntax errors with `make check` before bundling.
