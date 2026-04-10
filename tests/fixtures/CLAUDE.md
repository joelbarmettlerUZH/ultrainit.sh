# tests/fixtures/ — Test Fixture Files

Realistic JSON and Markdown test doubles for every pipeline stage. Never call real Claude API in tests — use these fixtures with the mock claude binary instead.

## Structure

```
tests/fixtures/
├── findings/             # Phase 1 agent outputs (8 JSON files, one per gather agent)
├── synthesis/            # Phase 4 synthesis pass outputs
│   ├── output-docs.json  # Pass 1 output (CLAUDE.md files)
│   ├── output-tooling.json  # Pass 2 output (skills, hooks, MCP)
│   └── output.json       # Merged final artifact (jq -s '.[0] * .[1]' of above)
├── skills/               # SKILL.md fixtures for validate_skill.bats
│   ├── valid-skill/SKILL.md
│   ├── invalid-skill-no-desc/SKILL.md
│   └── invalid-skill-angle-brackets/SKILL.md
├── subagents/            # Subagent fixtures for validate_subagent.bats
│   ├── valid-subagent.md
│   └── invalid-subagent.md
├── developer-answers.json  # Phase 2 output (NOT in findings/)
├── envelopes/            # (empty, reserved)
└── hooks/                # (empty, reserved)
```

## Using Fixtures in Tests

### Unit Tests (direct file copy)

```bash
cp "$BATS_TEST_DIRNAME/../fixtures/findings/identity.json" "$WORK_DIR/findings/"
```

### Integration Tests (envelope-wrapped for mock dispatch)

```bash
make_claude_envelope "$(cat $BATS_TEST_DIRNAME/../fixtures/findings/identity.json)" "0.15" \
    > "$MOCK_CLAUDE_DISPATCH_DIR/identity.json"
```

### Synthesis Tests

- Unit tests (`merge.bats`): copy `output.json` raw into `$WORK_DIR/synthesis/`
- Integration tests: wrap `output-docs.json` and `output-tooling.json` with `make_claude_envelope` for dispatch mode
- Never wrap `output.json` — it is the post-merge artifact, not a Claude response

## Three-Way Identity: Fixture → Agent → Findings

Findings fixture filenames must exactly match:
1. The agent name passed as first argument to `run_agent()` in `lib/gather.sh`
2. The findings filename written to `.ultrainit/findings/{name}.json` at runtime
3. The dispatch file name used in `$MOCK_CLAUDE_DISPATCH_DIR`

Breaking any of these three links breaks mock dispatch routing silently.

## Critical Rules

### Never Pre-Merge Synthesis Fixtures

`output-docs.json` and `output-tooling.json` must stay separate — they exist specifically to test `merge_synthesis_passes()`. `output.json` is independently maintained. When you update either pass fixture, regenerate `output.json`:

```bash
jq -s '.[0] * .[1]' \
    tests/fixtures/synthesis/output-docs.json \
    tests/fixtures/synthesis/output-tooling.json \
    > tests/fixtures/synthesis/output.json
```

### `developer-answers.json` Lives Outside `findings/`

It is Phase 2 output. Copy it to `$WORK_DIR/developer-answers.json` (not `$WORK_DIR/findings/developer-answers.json`) in synthesis tests.

### Skill Fixtures Require Subdirectories

`validate-skill.sh` derives skill name from the parent directory. Place skill fixtures at `skills/{skill-name}/SKILL.md`. Dynamic test fixtures must also use `mkdir -p $TEST_TMPDIR/my-skill && cat > $TEST_TMPDIR/my-skill/SKILL.md`.

### `claude_md` Padding in `output-docs.json`

The `claude_md` field contains deliberate padding lines to exceed the 100-line minimum for `validate_claude_md` tests. Do not remove them. If trimming for readability, keep the padding comment block or adjust the test's expected minimum threshold.

## Known Fixture Violations

5 of 8 findings fixtures have fields that violate their corresponding schemas, but tests still pass because no runtime schema validation exists in `agent.sh`:

| Fixture | Violation |
|---|---|
| `patterns.json` | `type: 'design'` is not a valid enum value |
| `tooling.json` | Missing required `purpose` field |
| `git-forensics.json` | Missing `commit_patterns.example_messages`, uses `path` where schema expects `file` |
| `structure-scout.json` | Invalid `role` strings (e.g., `'source code'`), extra fields `total_files`/`total_directories` |

These will fail if runtime schema validation is ever added. Until then, they are functional and unblocking.
