# .github/workflows/ — CI/CD Pipelines

Three workflow files, each with a distinct trigger and responsibility.

## Workflows

| File | Trigger | Responsibility |
|---|---|---|
| `test.yml` | push to main, PRs | Shell syntax check → bats test suite |
| `docker-test-image.yml` | `Dockerfile.test` changed on main | Rebuild and push test image to GHCR |
| `release.yml` | semver tag (`v*`) push | Bundle + publish GitHub Release |

## test.yml

Two-job chain:
1. **syntax** (ubuntu-latest, no container): `bash -n` all `.sh` files (excluding `./test-repos/*`) + `jq empty` all `schemas/*.json`. Fast, cheap — fails before wasting time pulling the Docker image.
2. **test** (`needs: syntax`): pulls `ghcr.io/joelbarmettleruzh/ultrainit-test:latest`, runs `bats tests/unit/ tests/scripts/ tests/edge/` (blocking) and `bats tests/integration/ || true` (non-blocking, always runs).

**Critical**: integration tests use `|| true` and `if: always()`. A green CI job does NOT guarantee integration tests passed. Check the raw step output explicitly after any changes to `lib/gather.sh`, `lib/synthesize.sh`, or `lib/merge.sh`.

Requires `packages: read` permission to pull the GHCR image.

## docker-test-image.yml

Fires only on `paths: [Dockerfile.test]` pushes to main. Rebuilds and pushes `:latest` to GHCR.

**If Dockerfile.test is not edited, the test image is never rebuilt.** Any change to the testing environment (new tool, updated bats version, new plugin) requires editing `Dockerfile.test` on main to trigger this workflow.

**No concurrency control.** Simultaneous pushes can produce races (two builds pushing the same `:latest` tag). Add a concurrency group if this becomes a problem: `concurrency: { group: docker-build, cancel-in-progress: true }`.

Requires `packages: write` permission.

## release.yml

Fires on `v*` tag push. Steps:
1. Extract tag from `GITHUB_REF`, validate against `^v[0-9]+\.[0-9]+\.[0-9]+(-[a-zA-Z0-9.]+)?$` (exits 1 if invalid)
2. `bash bundle.sh > dist/ultrainit.sh`
3. `bash -n dist/ultrainit.sh` (syntax-check the bundle before publishing)
4. `softprops/action-gh-release@v2` uploads `dist/ultrainit.sh` as the release asset

Requires `contents: write` permission. Uses only `GITHUB_TOKEN` — no external secrets.

**Never push a tag without consulting the user first.** This is an explicit project rule.

## Conventions

- All actions pinned to major version tags (`actions/checkout@v4`, `softprops/action-gh-release@v2`), not SHAs. For supply-chain-sensitive steps (release.yml has `contents:write`), consider pinning to full SHAs.
- No caching, no matrix, no workflow_dispatch, no concurrency groups.
- `bats-support`, `bats-assert`, and `bats-file` in `Dockerfile.test` are installed from HEAD with no version pin — a breaking upstream change would silently break all tests at the next image rebuild. Pin to specific tags.
- `bundle.sh` must never write to stdout except the bundle content — the release calls `bash bundle.sh > dist/ultrainit.sh`, so any spurious stdout output corrupts the bundle.

## Known Gotchas

If GHCR is slow or the test image doesn't exist yet (e.g., fresh fork), the test job will hang or fail on image pull. Ensure `docker-test-image.yml` has run at least once before running `test.yml` on a new fork.

The `release.yml` exports `VERSION=$TAG` but no downstream step currently uses it. If a step needs version embedding (e.g., `ultrainit --version`), pass `VERSION=$VERSION bash bundle.sh > dist/ultrainit.sh`.

`bats tests/integration/` always shows a green step in CI even when tests fail (`|| true`). This is intentional during development. Remove `|| true` once integration coverage stabilizes.
