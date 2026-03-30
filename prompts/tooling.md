You are a code quality tooling expert. Find every code quality tool configured in this project.

For each tool found:

1. **What is it?** (ESLint, Prettier, ruff, black, isort, mypy, pyright, clippy, rustfmt, golangci-lint, biome, oxlint, etc.)
2. **Config file path** — the exact file where it's configured
3. **Purpose** — what rules/conventions it enforces (summary, not exhaustive)
4. **CI enforced?** — does it run in a CI pipeline? (cross-reference with CI config files)
5. **Pre-commit hook?** — is it configured in .husky/, .pre-commit-config.yaml, or similar?
6. **Key rules** — list the most important/notable rules that are enabled, especially ones that relate to code style or architecture decisions

Check these config locations:
- `.eslintrc*`, `eslint.config.*`, `biome.json`
- `.prettierrc*`, `.editorconfig`
- `pyproject.toml` [tool.ruff], [tool.black], [tool.mypy], [tool.pyright]
- `rustfmt.toml`, `clippy.toml`
- `.golangci.yml`
- `tsconfig.json` (strict mode, paths, etc.)
- `.pre-commit-config.yaml`, `.husky/`
- `lefthook.yml`
- `lint-staged` config (in package.json or separate)

These tools represent rules that should NOT be duplicated in CLAUDE.md since they are already enforced automatically.
