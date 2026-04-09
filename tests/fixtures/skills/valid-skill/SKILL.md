---
name: valid-skill
description: Use when building or modifying API endpoints in src/api/.
  Covers route creation, middleware wiring, and request validation.
  Do NOT use for frontend components or static pages.
---

# API Development

This skill covers creating and modifying API endpoints.

## Key Files

- `src/api/routes.ts` — Route definitions
- `src/api/middleware.ts` — Auth and validation middleware
- `src/api/controllers/` — Request handlers
- `src/repos/` — Data access layer
- `tests/api/` — API test files

## Workflow

1. Define route in `src/api/routes.ts`
2. Create controller in `src/api/controllers/`
3. Add middleware as needed
4. Write tests in `tests/api/`

## Verification

Run `npm test -- --grep api` to verify API changes.
