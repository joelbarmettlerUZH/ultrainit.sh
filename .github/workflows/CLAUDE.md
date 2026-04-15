# .github/workflows/ — CI/CD Pipelines

Three workflow files, each with a distinct trigger and responsibility.

## Workflows

| File | Trigger | Responsibility |
|---|---|---|
| `test.yml` | push to main, PRs | Shell syntax check → bats test suite |
| `docker-test-image.yml` | `Dockerfile.test` changed on main | Rebuild and push test image to GHCR |
| `release.yml` | `Test` workflow success on main, workflow_dispatch | Auto-tag (patch/minor/major via PR label) + bundle + publish GitHub Release |

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

Fires via `workflow_run` after `test.yml` completes on `main`, and on manual `workflow_dispatch`. The job guards with `if: github.event_name == 'workflow_dispatch' || github.event.workflow_run.conclusion == 'success'` so failed test runs don't publish. Self-contained: computes the next version, creates and pushes the tag, bundles, and publishes in a single job.

`workflow_run` fires on the default branch at the time the triggering workflow completed; `github.sha` does NOT point at the commit being released. The checkout and label lookup both use `github.event.workflow_run.head_sha` (falling back to `github.sha` on manual dispatch) to operate on the right commit.

Steps:
1. **Determine bump**: on `workflow_dispatch`, uses the `bump` input (`patch`/`minor`/`major`). On push to main, reads the merged PR's labels via `gh api repos/{repo}/commits/{sha}/pulls`:
   - `release:major` → major bump
   - `release:minor` → minor bump
   - `release:skip` → no release (whole job short-circuits)
   - anything else (including `release:patch` or no label) → patch bump
2. **Compute version**: reads highest `vX.Y.Z` tag via `git tag -l 'v[0-9]*.[0-9]*.[0-9]*' --sort=-v:refname`, increments per bump type. Defaults to `v0.0.0` if no tags exist.
3. **Create and push tag** as `github-actions[bot]` using the default `GITHUB_TOKEN`.
4. `bash bundle.sh > dist/ultrainit.sh`
5. `bash -n dist/ultrainit.sh` (syntax-check the bundle before publishing).
6. `softprops/action-gh-release@v2` uploads `dist/ultrainit.sh` with `tag_name` set to the computed tag.

Requires `contents: write` and `pull-requests: read`. Uses only `GITHUB_TOKEN` — no external secrets.

**Why tag and release are in the same workflow**: a tag pushed using `GITHUB_TOKEN` does NOT trigger other workflows (GitHub blocks this to prevent recursion). Splitting tag-push and release into separate workflows would silently fail. If you ever split them, you must push the tag with a PAT stored as a secret.

**Direct pushes to main (not via PR) default to patch.** The label lookup returns empty, which falls through to patch. If you want to skip a direct push, tag it manually with `release:skip` semantics — or commit an empty change with `[skip ci]` if `test.yml` should also skip (release.yml does not honor `[skip ci]`).

**The `release:patch` label is redundant but harmless** — patch is already the default for unlabeled PRs. Labels exist so authors can make intent explicit in the PR UI.

## Conventions

- All actions pinned to major version tags (`actions/checkout@v4`, `softprops/action-gh-release@v2`), not SHAs. For supply-chain-sensitive steps (release.yml has `contents:write`), consider pinning to full SHAs.
- No caching, no matrix, no concurrency groups. `release.yml` uses `workflow_dispatch` for manual minor/major bumps.
- `bats-support`, `bats-assert`, and `bats-file` in `Dockerfile.test` are installed from HEAD with no version pin — a breaking upstream change would silently break all tests at the next image rebuild. Pin to specific tags.
- `bundle.sh` must never write to stdout except the bundle content — the release calls `bash bundle.sh > dist/ultrainit.sh`, so any spurious stdout output corrupts the bundle.

## Known Gotchas

If GHCR is slow or the test image doesn't exist yet (e.g., fresh fork), the test job will hang or fail on image pull. Ensure `docker-test-image.yml` has run at least once before running `test.yml` on a new fork.

`release.yml` does not embed the version into the bundle. If `ultrainit --version` is ever needed, pass `VERSION=${{ steps.version.outputs.tag }} bash bundle.sh > dist/ultrainit.sh` in the bundle step.

Every merge to main produces a release. For PRs that shouldn't ship a release (docs-only, CI-only, test fixes), apply the `release:skip` label before merging.

`bats tests/integration/` always shows a green step in CI even when tests fail (`|| true`). This is intentional during development. Remove `|| true` once integration coverage stabilizes.
