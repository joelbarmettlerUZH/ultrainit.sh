# CI/CD Workflows

GitHub Actions workflows for Docker builds, releases, and format checks.

## Active Workflows

| File | Trigger | Purpose |
|------|---------|----------|
| `docker-build.yaml` | main/dev push, version tags, workflow_dispatch | Multi-arch Docker build (5 variants × 2 archs) |
| `build-release.yml` | push to main | Extract version, create GitHub release, trigger Docker build |
| `release-pypi.yml` | push to main or pypi-release branch | Publish to PyPI via OIDC |
| `format-backend.yaml` | push touching `backend/**` | ruff format check |
| `format-build-frontend.yaml` | push not touching `backend/**` | prettier format + i18n parse + vite build |

**Disabled workflows** (`.disabled` extension — they never run):
- `integration-test.disabled`, `lint-frontend.disabled`, `lint-backend.disabled`, `codespell.disabled`

## Docker Build System

5 image variants: `main` (no suffix), `cuda`, `cuda126`, `ollama`, `slim`. Each variant has independent build + merge jobs. Platforms: `linux/amd64` (ubuntu-latest) and `linux/arm64` (ubuntu-24.04-arm native — no QEMU emulation).

**Digest-based multi-arch merge pattern:**
1. Platform build job: `push-by-digest=true` → image pushed without tag → digest saved to artifact
2. Merge job: downloads all platform digests → `docker buildx imagetools create` assembles multi-arch manifest
3. `copy-to-dockerhub` job mirrors to Docker Hub (best-effort, `continue-on-error: true`)

Artifact retention: **1 day**. If re-running only the merge job more than 24 hours after the build jobs ran, re-run the entire workflow.

## Release Flow

```
push to main
  → build-release.yml:
      1. Extract version from package.json
      2. Parse CHANGELOG.md section (format: '## [VERSION]' exactly — no date suffix)
      3. Create GitHub release
      4. Trigger docker-build.yaml via workflow_dispatch on version tag
  → docker-build.yaml (tag-triggered, canonical run):
      5. Build all 5 variants × 2 platforms
      6. Push to GHCR
      7. Copy to Docker Hub
  → release-pypi.yml:
      8. Build Python package
      9. Publish to PyPI via OIDC (no stored secret needed)
```

**Watch out:** `docker-build.yaml` triggers twice on release — once from `build-release.yml` dispatch and once from the version tag push. Both produce valid images; the tag-triggered run is canonical.

## Format Check Gates

The frontend format workflow runs:
```bash
npm run format       # prettier
npm run i18n:parse   # update translation keys
git diff --exit-code # fails if any files were modified
```

**i18n parse failures are format failures.** Any new `$i18n.t()` call must have `npm run i18n:parse` run and the resulting locale file changes committed before pushing.

## Known Issues

- `build-release.yml` uses deprecated `::set-output` syntax (should be `$GITHUB_OUTPUT` file)
- `format-build-frontend.yaml` uses `npm install --force` instead of `npm ci --force` (non-reproducible installs)
- CUDA builds trigger on every push to `main`/`dev` regardless of what changed — slow and expensive
- `lint-backend.disabled` is incorrectly configured (uses Bun for Python linting) — do not re-enable without rewriting
