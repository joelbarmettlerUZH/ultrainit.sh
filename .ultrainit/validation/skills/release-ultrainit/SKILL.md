---
name: release-ultrainit
description: "
  Full release workflow for ultrainit: verify tests pass, build and
  syntax-check the bundle, then create and push a semver tag to trigger
  release.yml. Use when cut a release, publish a new version, tag v1.2.3,
  or ship ultrainit. Do NOT push a tag without consulting the user first
  — never push tags autonomously. Do NOT use without running the full test
  suite first.
---

## Before You Start

- `.github/workflows/release.yml` — the release pipeline (validates tag, builds bundle, publishes)
- `bundle.sh` — what gets bundled and the `__EOF_LIB_<name>__` delimiter strategy
- `Makefile` — `bundle` and `test-all` targets
- `CLAUDE.md` section on Security-Critical Areas — `bundle.sh` ships broken releases if wrong

## Steps

### 1. Determine the next version

```bash
git tag --sort=-v:refname | head -5
```

Decide the next semver: `v<MAJOR>.<MINOR>.<PATCH>`. Pre-release format: `v1.2.3-beta.1` (the `.digit` after the label is required — `v1.2.3-beta` alone fails `release.yml`'s regex check).

### 2. Verify the branch is clean and on main

```bash
git status
git log --oneline main..HEAD
```

All changes must be merged to main before tagging. Releases are always cut from main.

### 3. Run the full test suite

```bash
make check     # syntax + schema validation
make test-all  # full bats suite inside Docker
```

Do not proceed if any test fails. Integration tests: check raw output — CI shows green even when they fail.

### 4. Check for bundle delimiter conflicts

```bash
grep '__EOF_LIB_' lib/*.sh prompts/*.md scripts/*.sh
```

If any file contains a line matching `__EOF_LIB_<name>__`, the heredoc in `bundle.sh` terminates early, shipping a broken bundle silently.

### 5. Build and verify the bundle

```bash
mkdir -p dist
bash bundle.sh > dist/ultrainit.sh
chmod +x dist/ultrainit.sh
bash -n dist/ultrainit.sh && echo "syntax OK"
du -sh dist/ultrainit.sh
```

If `bash -n` fails, `bundle.sh` has a syntax error or delimiter conflict. Do not tag.

### 6. STOP — confirm the version with the user

Show the user:
- The version number you plan to tag
- `git log --oneline $(git tag --sort=-v:refname | head -1)..HEAD` (commits since last tag)
- The bundle size from step 5

**Wait for explicit approval before proceeding.** The developer answers explicitly state: never release new tags without consulting the user first.

### 7. Create and push the tag

```bash
git tag v<VERSION>
git push origin v<VERSION>
```

This triggers `.github/workflows/release.yml` automatically.

### 8. Monitor the release workflow

```bash
gh run list --workflow=release.yml
gh run watch  # follow the live output
```

### 9. Verify the published release

```bash
gh release view v<VERSION>
```

Verify `dist/ultrainit.sh` is attached as a release asset. Check the download URL in the release body matches the curl-pipe-bash install command in `README.md`.

## Verify

```bash
bash -n dist/ultrainit.sh                          # bundle syntax
gh release view v<VERSION> --json assets --jq '.assets[].name'  # asset attached
```

## Common Mistakes

1. **Tagging without consulting the user** — the project rule is explicit. Always show the planned tag and commit range before tagging.

2. **`v1.2.3-beta` without `.digit`** — `release.yml` validates against `^v[0-9]+\.[0-9]+\.[0-9]+(-[a-zA-Z0-9.]+)?$`. The suffix must be `beta.1` not `beta`.

3. **Skipping `make test-all` before tagging** — `release.yml` runs `bash -n` but does NOT run the bats test suite. A broken release can ship even with failing tests if you skip step 3.

4. **`bundle.sh` stdout contamination** — any `echo` or `log_*` call added to `bundle.sh` corrupts the bundle output because `release.yml` does `bash bundle.sh > dist/ultrainit.sh`.
