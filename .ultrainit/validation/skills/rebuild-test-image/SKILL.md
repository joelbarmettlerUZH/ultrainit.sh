---
name: rebuild-test-image
description: "
  Rebuild the bats-core Docker test image after changes to Dockerfile.test,
  bats helper versions, or test system dependencies. Use when update the
  test image, add a tool to the test container, Dockerfile.test changed,
  or bats helpers need pinning. Do NOT use for changes to .bats test files
  — those don't require an image rebuild.
---

## Before You Start

- `Dockerfile.test` — the test image definition
- `.github/workflows/docker-test-image.yml` — fires only on `Dockerfile.test` path changes on main
- `Makefile` — `test-image` target
- `.github/workflows/test.yml` — pulls the image from GHCR on every CI run

## Steps

### 1. Edit Dockerfile.test

Make the needed changes. Common scenarios:

**Pinning bats helpers to a specific version** (recommended — currently unpinned and cloned from HEAD):
```dockerfile
# Before (broken — HEAD can have breaking changes):
RUN git clone https://github.com/bats-core/bats-support.git

# After (pinned to a specific tag):
RUN git clone --branch v1.11.1 --depth 1 https://github.com/bats-core/bats-support.git
```

**Adding a system tool**:
```dockerfile
RUN apt-get update && apt-get install -y --no-install-recommends \
    your-tool \
    && rm -rf /var/lib/apt/lists/*
```

### 2. Build locally

```bash
make test-image
```

This builds and tags the image as `ghcr.io/joelbarmettleruzh/ultrainit-test:latest` locally.

### 3. Run the full test suite against the new image

```bash
make test-all
```

Verify all tests pass with the new image before pushing.

### 4. Push to main

Commit and push `Dockerfile.test` to main. The `.github/workflows/docker-test-image.yml` workflow triggers **only when `Dockerfile.test` changes on main**.

```bash
git add Dockerfile.test
git commit -m "chore: pin bats-support to v1.11.1 in test image"
git push origin main
```

### 5. Monitor the GHCR image rebuild

```bash
gh run list --workflow=docker-test-image.yml
gh run watch
```

The workflow pushes to `ghcr.io/joelbarmettleruzh/ultrainit-test:latest`. No version tag — always `:latest`.

### 6. Verify the next CI run uses the new image

Trigger a test run (push any change) and verify `test.yml` pulls successfully:

```bash
gh run list --workflow=test.yml
```

## Verify

```bash
make test-image && make test-all
```

## Common Mistakes

1. **No concurrency control** — `docker-test-image.yml` has no concurrency group. Two simultaneous pushes to main with `Dockerfile.test` changes race to push `:latest`. If this becomes a problem, add `concurrency: { group: docker-build, cancel-in-progress: true }` to the workflow.

2. **GHCR image doesn't exist yet on a fresh fork** — `test.yml` will hang or fail on image pull. Run `make test-image` and push first.

3. **Editing `Dockerfile.test` on a branch, not main** — `docker-test-image.yml` only fires on main. A branch change won't rebuild the GHCR image. Test locally with `make test-image` and verify before merging.
