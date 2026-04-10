# open-webui

Self-hosted AI chat platform with multi-model LLM integration, RAG pipelines, real-time streaming, and a plugin/pipeline extensibility system. Connects to Ollama, OpenAI-compatible APIs, Anthropic, and Google Gemini through a unified interface.

## Quick Reference

| Task | Command |
|------|---------|
| Frontend dev server | `npm run dev` |
| Build frontend | `npm run build` (runs pyodide:fetch first) |
| Format frontend | `npm run format` |
| Lint frontend | `npm run lint` |
| Type-check frontend | `npm run check` |
| Test frontend | `npm run test:frontend` |
| Format backend | `npm run format:backend` (ruff format) |
| Lint backend (ruff) | `ruff check . --fix --exclude .venv --exclude venv` |
| Run with Docker | `docker compose up -d --build` |
| Parse i18n strings | `npm run i18n:parse` (run before committing if adding UI strings) |
| E2E tests (interactive) | `npm run cy:open` |

**Before every push:** `npm run format && npm run i18n:parse && git diff --exit-code` — the CI format check will fail if these were not run.

## Architecture

### Overview

Full-stack monolith deployed as a Docker container. A **SvelteKit SPA** (built to `build/`) is served statically by the **FastAPI Python backend**. The backend handles all API routes, streams SSE for chat completions, proxies all LLM provider calls, and hosts a **Socket.IO server** at `/ws/socket.io` for real-time events.

Configuration is managed through `PersistentConfig` — a DB-backed registry that reads env vars at startup and can be overridden at runtime via the admin UI without restart. The **plugin system** (`tools/`, `functions/`) executes arbitrary user-authored Python stored in the database, loaded via `importlib` at request time. **RAG** runs as a middleware stage before the LLM call, injecting retrieved chunks from any of 12+ vector DB backends selected at startup via factory pattern.

Horizontal scaling requires Redis: Socket.IO pub/sub (`WEBSOCKET_MANAGER=redis`), JWT revocation, rate limiting, and config sync all fall back to in-process equivalents that break under multiple instances.

### Directory Structure

```
open-webui/
├── backend/
│   └── open_webui/
│       ├── main.py                # FastAPI app, lifespan, middleware stack
│       ├── config.py              # PersistentConfig registry, AppConfig
│       ├── env.py                 # Env var parsing, load_dotenv
│       ├── constants.py           # ERROR_MESSAGES enum, TASKS enum
│       ├── tasks.py               # Background task scheduling
│       ├── routers/               # 28 APIRouter files, one per domain
│       ├── models/                # SQLAlchemy ORM + Pydantic + Repository (22 files)
│       ├── utils/
│       │   ├── middleware.py      # 6500-line chat pipeline (RAG, tools, filters)
│       │   ├── auth.py            # JWT, get_verified_user, get_admin_user
│       │   ├── chat.py            # generate_chat_completion, backend dispatch
│       │   ├── plugin.py          # Dynamic importlib loader for functions/tools
│       │   ├── filter.py          # Inlet/outlet filter execution
│       │   ├── tools.py           # Tool spec generation, dunder injection
│       │   ├── access_control/    # Permission tree + AccessGrant checks
│       │   └── mcp/               # MCP server client (client.py)
│       ├── retrieval/
│       │   ├── vector/            # VectorDBBase ABC + factory + 14 adapters
│       │   ├── loaders/           # Document loaders (PDF, DOCX, web, YouTube)
│       │   └── web/               # 26 search engine adapters
│       ├── socket/
│       │   ├── main.py            # Socket.IO server, event handlers, SESSION_POOL
│       │   └── utils.py           # RedisDict, RedisLock, YdocManager
│       ├── storage/
│       │   └── provider.py        # StorageProvider ABC: Local/S3/GCS/Azure
│       ├── migrations/            # Alembic (current schema system)
│       │   └── versions/          # 35 linear migration files
│       ├── internal/
│       │   ├── db.py              # SQLAlchemy engine/session, JSONField
│       │   ├── wrappers.py        # ContextVar Peewee state
│       │   └── migrations/        # Legacy Peewee migrations 001–018
│       ├── tools/
│       │   └── builtin.py         # Built-in tools (web search, code exec, memory)
│       └── test/                  # pytest test suite
├── src/
│   ├── routes/
│   │   ├── +layout.svelte         # Global init: socket, i18n, Pyodide worker
│   │   ├── (app)/                 # Authenticated route group
│   │   │   ├── +layout.svelte     # App init: models, tools, banners, shortcuts
│   │   │   ├── c/[id]/            # Chat route
│   │   │   ├── admin/             # Admin panel (users/settings/functions/analytics)
│   │   │   ├── workspace/         # Models/prompts/knowledge/tools/skills
│   │   │   ├── notes/             # Notes feature
│   │   │   └── playground/        # API playground
│   │   └── auth/+page.svelte      # Sign-in / OAuth callback
│   └── lib/
│       ├── stores/index.ts        # ALL 70+ global Svelte writable stores
│       ├── apis/                  # 27 domain API client modules
│       ├── components/            # All Svelte UI (chat/, admin/, workspace/, common/)
│       ├── utils/
│       │   ├── index.ts           # 1855-line utility barrel
│       │   └── marked/            # 7 custom marked.js extensions
│       └── workers/               # Pyodide WASM worker, Kokoro TTS worker
├── cypress/                       # E2E tests (4 spec files)
├── scripts/
│   ├── prepare-pyodide.js         # Pre-fetches Pyodide WASM and Python wheels
│   └── generate-sbom.sh           # CycloneDX SBOM generation
├── pyproject.toml                 # Ruff + Black + Python config
├── package.json                   # Frontend scripts
└── docker-compose.yaml
```

### Backend Architecture

**Request path for chat completions:**
1. Request → Starlette middleware stack (`AuditLoggingMiddleware`, `SecurityHeadersMiddleware`)
2. FastAPI router → `Depends(get_verified_user)` (JWT from header/cookie/x-api-key)
3. `Depends(get_session)` injects SQLAlchemy session
4. Route handler → `process_chat_payload()` in `utils/middleware.py`:
   - Memory injection
   - RAG context retrieval from `VECTOR_DB_CLIENT`
   - Web search injection
   - Tool spec generation (with dunder param stripping)
   - Inlet filter execution (priority-ordered)
   - Arena model resolution
5. `generate_chat_completion()` in `utils/chat.py` → routes to Ollama/OpenAI/custom function
6. `StreamingResponse` with SSE chunks → outlet filter per-chunk
7. Background tasks: title generation, tagging

**Layered architecture:**
- **Routers** (`routers/`): HTTP boundary, auth deps, HTTPException
- **Repository** (`models/`): static methods, session context managers
- **Utils** (`utils/`): business logic, pipeline, format conversion
- **Infrastructure** (`internal/`, `socket/`, `storage/`, `retrieval/`): DB engine, real-time, file storage, vector search

### Frontend Architecture

SvelteKit CSR (no SSR — `ssr=false` in `+layout.js`). All data fetching is client-side in `onMount()`.

**State:** A single `src/lib/stores/index.ts` holds all 70+ global writable stores. No Redux, no context (except `i18n`). Update with `store.set(newValue)` or `store.update(fn)` — never mutate store values in place without reassignment.

**Streaming:** Two paths exist simultaneously — SSE via `clearStream` from `generateOpenAIChatCompletion()` → `createOpenAITextStream()` async generator, AND Socket.IO `chat:message:delta` events. Both update the same history message store. Do not try to de-duplicate — one request uses exactly one path.

**Message history** is a DAG, not a flat array: `{ messages: Record<string, Message>, currentId: string }`. Each message has `parentId`/`childrenIds[]`. Always use `buildMessages(history, currentId)` from `src/lib/utils/index.ts` to get the ordered display list. Never iterate `history.messages` directly.

**Route pattern:** +page.svelte files are thin wrappers (5–30 lines) that delegate to heavy components in `$lib/components/`. All business logic belongs in the component, not the route.

### Key Abstractions

**`PersistentConfig[T]`** (`backend/open_webui/config.py`): Wraps each admin-configurable setting. Reads from env var on startup, can be overridden from DB at runtime. Access the value via `.value`. Never access via `dict()` or `vars()` — raises `TypeError`. Never read env vars directly in routers; import from `config.py`. Assigning to `app.state.config.X = value` automatically persists to DB and syncs to Redis.

**Repository Pattern** (`backend/open_webui/models/`): Every domain has three classes in one file: SQLAlchemy ORM class (e.g. `Chat`), Pydantic model with `ConfigDict(from_attributes=True)` (e.g. `ChatModel`), and a plural static-method repository class (e.g. `Chats`). Never call SQLAlchemy directly outside these classes. Convert with `ModelClass.model_validate(orm_obj)`.

**`VectorDBBase` + Factory** (`backend/open_webui/retrieval/vector/`): All vector work goes through `VECTOR_DB_CLIENT` from `factory.py`. Never instantiate Chroma/Qdrant/etc. directly. Collection naming convention: `{kb_id}` for knowledge bases, `file-{id}` for files, `user-memory-{user_id}` for memories. Violating this breaks retrieval silently.

**Plugin System** (`backend/open_webui/utils/plugin.py`): Four types — **Pipe** (custom LLM provider with `pipe(body, __user__)` method), **Filter** (pre/post-process with `inlet(body)`/`outlet(body)`, respects Valves.priority), **Action** (UI toolbar button with `action(body, __event_emitter__)`), **Manifold** (Pipe with `pipes()` returning list of sub-models). `SAFE_MODE=true` disables all dynamic execution. Built-in tools live in `tools/builtin.py` — never import that file directly, use `get_builtin_tools()` from `utils/tools.py`.

## Patterns and Conventions

### Plugin / Extension Authoring

Plugins are Python stored as source in the DB and loaded via `importlib`. Rules:

- **Valves** (`class Valves(BaseModel)` inside your plugin class) are the only persistent config mechanism. Class-level variables lose state on restart.
- **Dunder parameters** are injected at call time and stripped from LLM-visible specs: `__user__`, `__request__`, `__event_emitter__`, `__event_call__`, `__chat_id__`, `__message_id__`, `__metadata__`, `__model_knowledge__`.
- **Filter vs Pipe**: Filter `outlet()` is NOT called for direct `/v1/chat/completions` API requests — only for UI-initiated chats. If post-processing must apply to all requests, use a Pipe or `utils/middleware.py`, not a Filter outlet.
- **Manifold IDs** use dot notation: `manifold_id.sub_model_id`. Any code parsing model IDs must split on the first dot only.
- Use `__event_emitter__` for async status updates to the UI; use `__event_call__` for blocking user dialogs that need input.

See `backend/open_webui/utils/tools.py` for the canonical injection pattern.

### Backend Error Handling

All errors use `HTTPException` with constants from `backend/open_webui/constants.py`:
```python
raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=ERROR_MESSAGES.DEFAULT("custom message"))
```

Never raise `HTTPException` with inline string literals. Add new error messages to `ERROR_MESSAGES` enum. Repository methods return `Optional[T]`; routers check for `None` and raise. Always re-raise `HTTPException` before the bare `except Exception` to prevent swallowing HTTP errors:
```python
try:
    ...
except HTTPException:
    raise
except Exception as e:
    log.exception(e)
    raise HTTPException(status_code=500, detail=ERROR_MESSAGES.DEFAULT(e))
```

Logging always via loguru: `from open_webui.utils.logger import log`. Use `log.exception(e)` for full traceback. Never use `print()` or stdlib `logging` directly.

### Frontend API Client Pattern

Every function in `src/lib/apis/*/index.ts` uses the deferred-throw pattern:
```typescript
let error = null;
const res = await fetch(url, opts)
  .then(async r => { if (!r.ok) throw await r.json(); return r.json(); })
  .catch(err => { error = err.detail; return null; });
if (error) throw error;
return res;
```
Callers catch with `.catch(err => { toast.error(String(err)); return null; })`. Never use raw `fetch` in components. Never manually set `Content-Type` on `FormData` requests.

### Database Conventions

- All primary keys: UUID v4 strings (`str(uuid.uuid4())`)
- All timestamps: Unix epoch seconds as `BigInteger` — never `datetime` objects
- JSON columns: use `JSONField` from `open_webui.internal.db`, not `Column(JSON)`
- Sessions: always via `Depends(get_session)` in routers, `get_db_context(db)` in model methods
- Commits: `commit_session_after_request` middleware auto-commits after every request — model code does not need explicit `db.commit()` for normal operations
- Never write SQL against the `chat.chat` column (messages JSON blob) — use `Chats` manager methods which handle serialization

### Database Migrations

Two migration systems run sequentially at every startup from `internal/db.py` import:
1. **Peewee** migrations `001–018` in `backend/open_webui/internal/migrations/` (legacy, do not add to)
2. **Alembic** migrations in `backend/open_webui/migrations/versions/` (current)

Always add new schema changes as Alembic migrations only. **Never edit existing migration files.** Generate new migrations: `alembic revision --autogenerate -m 'description'`. SQLite requires `batch_alter_table` for column changes — use `with op.batch_alter_table('table', schema=None) as batch_op:` pattern. New NOT NULL columns must use `server_default=` to backfill existing rows. Timestamps: `BigInteger` epoch seconds everywhere except `config` table (historical inconsistency).

### Auth and Permissions

Three FastAPI dependencies:
- `get_current_user`: extracts user, no role check
- `get_verified_user`: requires non-pending role
- `get_admin_user`: requires `admin` role

Token resolution order: `Authorization: Bearer` header → `token` cookie → `x-api-key` header. API keys prefixed `sk-` handled separately. JWT revocation via Redis keyed by `jti`.

Three-layer resource access:
1. Admin bypass (`BYPASS_ADMIN_ACCESS_CONTROL` flag — defaults true)
2. Feature gates via `has_permission(user.id, 'workspace.models', config.USER_PERMISSIONS)` — uses `?? true` defaults
3. Per-resource `AccessGrants.has_access(user_id, resource_type, resource_id, permission, db=db)`

**Batch access checks prevent N+1:** Use `AccessGrants.get_accessible_resource_ids(resource_type, user_id, resource_ids=[...])` for list endpoints instead of per-item `has_access()`.

### Svelte Store Updates

```typescript
// CORRECT: spread + set
settings.update(s => ({ ...s, theme: 'dark' }));
await updateUserSettings(localStorage.token, { ui: $settings });

// WRONG: direct mutation (does not trigger reactivity)
$settings.theme = 'dark';
```

Always reload affected global stores after mutations — they are not invalidated automatically: `models.set(await getModels(localStorage.token))`.

### i18n in Frontend Components

```typescript
// CORRECT: getContext, reactive $prefix
const i18n = getContext('i18n');
// in template:
{$i18n.t('Key string')}
{$i18n.t('Hello {{name}}', { name: $user?.name })}

// WRONG: import or non-reactive call
import i18n from '$lib/i18n';  // Don't
i18n.t('key')  // Not reactive, won't update on locale change
```

Run `npm run i18n:parse` and commit the generated locale changes whenever adding new `$i18n.t()` calls.

### Naming Conventions

**Python backend:**
- `snake_case` for functions/modules (`get_current_user`, `rate_limit.py`)
- `PascalCase` for classes (`UsersTable`, `VectorDBBase`)
- `UPPER_SNAKE_CASE` for env vars and constants
- Pydantic suffixes: `*Model` (response), `*Form` (request body), `*Response` (response shape)
- Repository classes: plural noun (`Users`, `Chats`, `Functions`)
- SQLAlchemy table class: singular noun (`User`, `Chat`)
- Timestamps: epoch integers via `int(time.time())` — never `datetime.now()`

**TypeScript/Svelte frontend:**
- `PascalCase.svelte` for components
- `camelCase` for functions/variables/stores
- `SCREAMING_SNAKE_CASE` for injected build-time constants (`WEBUI_API_BASE_URL`, `APP_VERSION`)
- API functions: `getX`, `createX`, `updateXById`, `deleteXById`
- Callback props: `onX` prefix (`onSubmit`, `onClose`)
- Boolean stores: `show` prefix (`showSidebar`, `showSettings`)

## Development Workflow

### Building and Running

```bash
# First-time setup
npm install --force

# Pyodide WASM assets must be prepared before build
npm run pyodide:fetch

# Full frontend build
npm run build

# Dev with HMR (frontend only)
npm run dev
# Backend must run separately in dev mode

# Full Docker stack
docker compose up -d --build
```

**Important:** `npm run build` (not `vite build` directly) — the `prepare-pyodide.js` step is wired into the npm build script. Skipping it silently breaks in-browser Python execution.

### Testing

```bash
# Frontend unit tests
npm run test:frontend        # vitest, --passWithNoTests

# Backend tests (requires PostgreSQL)
# Tests live in backend/open_webui/test/
# Run with pytest after setting DATABASE_URL env var

# E2E (requires running app at localhost:8080 with a pulled Ollama model)
npm run cy:open
```

Backend tests use `AbstractPostgresTest` base class (real PostgreSQL, not mocked). Auth is injected via `mock_webui_user(id=..., role=...)` context manager, not JWT tokens. Cypress E2E tests select `.first()` model — any Ollama model works.

### Tooling

- **Ruff** (Python): CI-verified formatting and linting. Config in `pyproject.toml`. `import datetime as dt` alias is enforced. Max line length 120.
- **Prettier**: Tabs (not spaces), single quotes, 100-char print width. Config in `.prettierrc`.
- **ESLint**: `@typescript-eslint/recommended` + `svelte/recommended`. Config in `.eslintrc.cjs`.
- **TypeScript**: strict mode, `svelte-check` for Svelte components.

## Things to Know

**PR workflow:** All PRs must target the `dev` branch — PRs to `main` are automatically closed. Check the project roadmap before opening a PR for a new feature. Conventional commit prefixes are required: `feat/fix/docs/test/style/refactor/perf/chore/build/ci/WIP`. Translation/i18n PRs must be standalone, not bundled with features.

**Dual migration startup cost:** Both Peewee and Alembic migrations run synchronously when `internal/db.py` is first imported. This happens at app startup. Never import `config.py` in test setup without a real DB connection — importing `config.py` triggers DB schema changes.

**`middleware.py` is 6500+ lines and handles everything:** Changes here affect ALL chat completions — plain chat, tool-enabled, RAG-enabled, and function/pipe models. Test all modes after any change.

**Chat message history is a DAG in a JSON blob:** The `chat.chat` column stores the full conversation tree. The normalized `chat_message` table was added later for search/indexing. Both exist simultaneously — always use `Chats` repository methods, never raw SQL on the `chat` column.

**`local:` prefix bypasses ownership checks:** Chat IDs prefixed `local:` are treated as temporary/unauthenticated chats and skip `is_chat_owner()` validation. Intentional for guest usage.

**Nginx SSE buffering breaks streaming:** In production deployments behind Nginx, `proxy_buffering off` is required for all API location blocks, or tokens will batch in 40–50 token bursts instead of streaming smoothly. Also add `X-Accel-Buffering: no` response header.

**aiohttp 3.13.3 is broken:** Pinned in `pyproject.toml`. Do not upgrade aiohttp past the pinned version — it breaks all backend LLM API calls.

**`console.log` is stripped in production:** All `console.log/debug/error` calls are removed from production builds by Vite's `esbuild.pure` config. Use the backend logging system for persistent debug output.

**Pyodide WASM build step:** `static/pyodide/` directory must be populated before every build via `npm run pyodide:fetch` / `npm run build`. CI caches this directory. Missing it silently breaks in-browser Python execution.

**Token in localStorage (not HttpOnly cookie):** Intentional architectural choice for API key usability, but means XSS would steal sessions. Ensure strict CSP headers are configured.

**`BYPASS_ADMIN_ACCESS_CONTROL` defaults to `true`:** Admins bypass all resource-level access grants. Set to `false` in production if admins should be subject to sharing restrictions.

**Redis is optional but 12+ features degrade silently without it:** Distributed task management, cross-instance session pools, rate limiting, config sync, and task cancellation all fall back to in-memory alternatives that break in multi-instance deployments.

## Security-Critical Areas

These files require human review before any AI-assisted modification:

- `backend/open_webui/utils/auth.py` — JWT generation/validation, token revocation, API key handling
- `backend/open_webui/utils/access_control/` — permission tree, resource grants, sharing enforcement
- `backend/open_webui/routers/auths.py` — login/logout/token endpoints
- `backend/open_webui/models/auths.py` — credential storage
- `backend/open_webui/internal/migrations/` — existing Peewee migrations (010 is a destructive data transform)
- `backend/open_webui/migrations/versions/` — never edit existing files, only generate new ones
- `src/lib/constants/permissions.ts` — RBAC permission defaults
- `.env*` files — never commit real credentials; use `.env.example` as template
- `.webui_secret_key` — session encryption key

## Domain Terminology

| Term | Meaning in Codebase |
|------|-------------------|
| **Pipe** | Plugin type that acts as a custom LLM provider (`pipe()` method replaces model call) |
| **Filter** | Plugin type that pre/post-processes messages (`inlet()`/`outlet()` methods); outlet only runs for UI-initiated chats |
| **Action** | Plugin type that adds a toolbar button to messages (`action()` method) |
| **Manifold** | Pipe with a `pipes()` method that returns multiple sub-model entries; addresses as `manifold_id.sub_model_id` |
| **Valves** | Nested `class Valves(BaseModel)` inside a plugin — admin-configurable persistent settings |
| **UserValves** | Nested `class UserValves(BaseModel)` — per-user overrides on top of Valves |
| **Pipeline** | Separate Python FastAPI process for plugins that need pip dependencies; exposes OpenAI spec |
| **RAG** | Retrieval-Augmented Generation — vector DB document retrieval injected into chat context |
| **Arena model** | Meta-model that randomly picks from a pool of real models; actual model in `selected_model_id` metadata |
| **Knowledge base** | User-curated document collection stored in vector DB under collection name = KB ID |
| **PersistentConfig** | Generic wrapper for admin-changeable settings that auto-persist to DB and sync to Redis |
| **USAGE_POOL** | In-memory or Redis dict tracking active model usage counts per user session |
| **SESSION_POOL** | Socket.IO session registry mapping socket IDs to user info |
| **IDBFS** | IndexedDB-backed virtual filesystem used by the Pyodide in-browser Python worker |
| **Dunder params** | `__double_underscore__` parameters injected into plugin functions at call time, stripped from LLM specs |
| **YDoc** | Yjs CRDT document used for collaborative note editing |
| **local: prefix** | Chat ID prefix meaning temporary/anonymous — bypasses ownership checks |
