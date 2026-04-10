# Cypress E2E Tests

End-to-end tests against a running Open WebUI instance at `localhost:8080`. Requires at least one Ollama model pulled.

## Structure

```
cypress/
├── e2e/
│   ├── chat.cy.ts        # Chat flow (LLM required)
│   ├── registration.cy.ts # User registration
│   ├── settings.cy.ts    # Admin settings
│   └── documents.cy.ts   # STUB — commands not yet implemented
├── support/
│   ├── e2e.ts            # registerAdmin(), loginAdmin(), global before()
│   └── index.d.ts        # TypeScript declarations for custom commands
└── data/
    └── example-doc.txt   # Fixture for planned document tests
```

## Running Tests

```bash
# Interactive (required — no cy:run script exists in package.json yet)
npm run cy:open

# For CI, add to package.json:
# "cy:run": "cypress run"
```

App must already be running at `localhost:8080`. There is no `wait-on` configuration.

## Test Infrastructure

**Global setup** (`support/e2e.ts`):
- `before()` calls `cy.registerAdmin()` — POSTs to `/api/v1/auths/signup` with `failOnStatusCode: false`, accepts 200 OR 400 (idempotent)
- `loginAdmin()` uses `cy.session()` for caching; validates via `GET /api/v1/auths/` with Bearer token
- Sets `localStorage.setItem('locale', 'en-US')` for stable text assertions

**Hard-coded credentials** (in `support/e2e.ts`): `admin@example.com` / `password`

## Required Patterns

**Every `describe()` block must include this `after()` hook** (prevents Cypress video cut-off):
```typescript
describe('Feature', () => {
  after(() => { cy.wait(2000) });  // required — video recording workaround
  // ...
});
```

**Chat input requires `force: true`**:
```typescript
cy.get('#chat-input').type('Hello', { force: true });  // always force
```

**Changelog dialog** must be conditionally dismissed:
```typescript
cy.getAllLocalStorage().then(ls => {
  if (!ls[Cypress.config('baseUrl') || '']?.['version']) {
    cy.get('button').contains("Okay, Let's Go!").click();
  }
});
```

**Selector strategy** (in priority order):
1. `aria-label` and `aria-roledescription`
2. Element IDs
3. CSS classes
4. `data-cy` attributes
5. `cy.contains()` — only for asserting visible text, not for clicking

**Tiered timeouts** (explicit, not global):
```typescript
cy.get('[aria-label="model"]', { timeout: 10_000 })  // UI interaction
cy.get('.generated-image', { timeout: 60_000 })       // image generation
cy.get('.complete-response', { timeout: 120_000 })    // LLM response
```

## Known Issues

- `documents.cy.ts` is a stub — `uploadTestDocument()` and `deleteTestDocument()` are declared in `index.d.ts` but not implemented in `e2e.ts`. Implement both before writing document tests.
- `chat.cy.ts` has `describe('Settings')` wrapping chat tests — copy-paste error, should be `describe('Chat')`.
- No `cy:run` script in `package.json` — add one before enabling CI integration.
- Tests accumulate pending users (timestamp-suffix emails never cleaned up) — add cleanup in `afterAll` for long-running environments.
