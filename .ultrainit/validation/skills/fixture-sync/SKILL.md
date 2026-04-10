---
name: fixture-sync
description: "
  Validate all tests/fixtures/findings/ JSON files against their corresponding
  schemas/ files, report mismatches, and optionally fix them. Use when
  fixtures are out of sync, schema was updated, fixture has wrong field
  names, tests pass against wrong data, or adding a new schema constraint.
  Do NOT use for synthesis fixtures — use add-synthesis-fixture for those.
---

## Before You Start

- `tests/fixtures/findings/` — 8 fixture files, one per Phase 1 agent
- `schemas/` — 14 JSON schema files; the 8 relevant ones match by base name
- `tests/fixtures/CLAUDE.md` — documents the 5 known schema violations in current fixtures

## Known Violations

Five of eight current fixtures violate their schemas. These are documented and intentional — no runtime schema validation exists in `agent.sh`. Proceed only if you are intentionally fixing drift:

| Fixture | Known Violation |
|---------|----------------|
| `patterns.json` | `type: 'design'` is not in the schema's enum |
| `tooling.json` | Missing required `purpose` field |
| `git-forensics.json` | Uses `path` where schema expects `file`; missing `commit_patterns.example_messages` |
| `structure-scout.json` | Invalid `role` strings; extra `total_files`/`total_directories` fields |

## Steps

### 1. Check which fixtures have required-field violations

```bash
for agent in identity commands git-forensics patterns tooling docs-scanner security-scan structure-scout; do
    fixture="tests/fixtures/findings/${agent}.json"
    schema="schemas/${agent}.json"
    if [[ ! -f "$fixture" || ! -f "$schema" ]]; then
        echo "MISSING: $agent"
        continue
    fi
    # Check required fields
    required=$(jq -r '.required[]?' "$schema" 2>/dev/null)
    for field in $required; do
        present=$(jq -e ".${field}" "$fixture" 2>/dev/null && echo yes || echo no)
        if [[ "$present" == "no" ]]; then
            echo "MISSING REQUIRED: $agent.$field"
        fi
    done
done
```

### 2. Check for additionalProperties violations

```bash
for agent in identity commands git-forensics patterns tooling docs-scanner security-scan structure-scout; do
    fixture="tests/fixtures/findings/${agent}.json"
    schema="schemas/${agent}.json"
    fixture_keys=$(jq -r 'keys[]' "$fixture" 2>/dev/null | sort)
    schema_keys=$(jq -r '.properties | keys[]' "$schema" 2>/dev/null | sort)
    extra=$(comm -23 <(echo "$fixture_keys") <(echo "$schema_keys"))
    if [[ -n "$extra" ]]; then
        echo "EXTRA FIELDS in $agent: $extra"
    fi
done
```

### 3. Check enum values

For fields with enum constraints (particularly `patterns.json` type and `structure-scout.json` role):

```bash
# Check patterns.json type values
jq -r '.patterns[].type' tests/fixtures/findings/patterns.json | sort -u
# Compare against schema enum:
jq -r '.properties.patterns.items.properties.type.enum[]' schemas/patterns.json | sort
```

### 4. Fix a fixture

When fixing, use real values — never hand-craft values. Capture from real claude output if possible:

```bash
# Option A: Minimal fix — add missing required field
jq '.findings[0] += {"purpose": "example purpose"}' \
    tests/fixtures/findings/tooling.json > /tmp/fixed.json
mv /tmp/fixed.json tests/fixtures/findings/tooling.json

# Option B: Replace invalid enum value
jq '.patterns[].type |= if . == "design" then "architecture" else . end' \
    tests/fixtures/findings/patterns.json > /tmp/fixed.json
mv /tmp/fixed.json tests/fixtures/findings/patterns.json
```

### 5. Verify tests still pass after fixing

```bash
make test-unit
make test-integration
```

Fixing a schema violation can break existing tests if a test was asserting on the (incorrect) current value. Update the assertion alongside the fixture.

## Verify

```bash
# All fixtures are valid JSON
for f in tests/fixtures/findings/*.json; do jq empty "$f" && echo "OK: $f"; done

# Run tests
make test-unit
```

## Common Mistakes

1. **Hand-crafting fixture values** — the `tests/fixtures/CLAUDE.md` rule says to capture real `claude -p --output-format json` output. Hand-crafted fixtures can make tests pass against data that real Claude would never produce.

2. **Fixing a fixture without updating dependent tests** — some unit tests assert on specific fixture field values. If you fix `patterns.json`'s type enum, find any test that asserts `type: 'design'` and update it too.
