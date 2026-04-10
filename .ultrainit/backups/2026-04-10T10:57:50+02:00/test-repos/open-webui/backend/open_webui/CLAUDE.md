# open_webui Backend Package

Core FastAPI backend. Entry point: `main.py`. Middleware chain, router registration, lifespan management, and the `AppConfig` pattern all live here.

## Request Lifecycle

```
HTTP request
  → SecurityHeadersMiddleware
  → AuditLoggingMiddleware (logs request/response asynchronously)
  → StarSessionsMiddleware
  → APIKeyRestrictionMiddleware (checks endpoint allowlist for sk- keys)
  → FastAPI router matching
  → Depends(get_verified_user)  ← JWT from header/cookie/x-api-key
  → Depends(get_session)        ← SQLAlchemy session
  → Route handler
  → commit_session_after_request (auto-commits ScopedSession)
```

For chat completions (POST `/api/chat/completions`):
1. `process_chat_payload()` in `utils/middleware.py` — RAG, tools, memory, inlet filters
2. `generate_chat_completion()` in `utils/chat.py` — backend dispatch
3. `StreamingResponse` with SSE + outlet filters per-chunk
4. Background tasks: `generate_title`, `generate_tags` via `BackgroundTasks`

## PersistentConfig Pattern

Every admin-changeable setting is a `PersistentConfig[T]` in `config.py`:

```python
# Reading - always from config.py, never os.environ directly
from open_webui.config import OLLAMA_BASE_URL
print(OLLAMA_BASE_URL.value)  # access via .value

# Saving (triggers DB persist + Redis sync)
app.state.config.SOME_SETTING = new_value

# WRONG - bypasses runtime override mechanism
import os; os.environ.get('OLLAMA_BASE_URL')

# WRONG - raises TypeError
dict(OLLAMA_BASE_URL)
```

New configurable settings require updates in 4 places: `env.py` (env var), `config.py` (PersistentConfig wrapper), `main.py` (app.state.config assignment), and the relevant router.

## AppConfig and Startup

`app.state.config` is an `AppConfig` instance. `__setattr__` override means attribute assignment auto-persists. `app.state.MODELS` and `app.state.TOOLS` are in-memory dicts that must be refreshed after mutations.

`commit_session_after_request` middleware auto-commits after every request — model code does NOT need explicit `db.commit()` for standard operations.

## Dynamic Python Execution

`utils/plugin.py` loads user-authored Python functions from the DB via `importlib`. Security surface:
- Executes with full server process privileges
- `SAFE_MODE=true` in `main.py` disables all dynamic execution
- Only admins can create functions/tools
- Never store user-submitted code without admin review

The `tools/builtin.py` module contains built-in tools. **Never import it directly** — import `get_builtin_tools()` from `utils/tools.py` instead. Direct import bypasses the spec-generation and dunder injection pipeline.

## Background Tasks

Fire-and-forget via `BackgroundTasks` or `asyncio.create_task()`. Background tasks must create their own `Session` — they cannot share the request session (which closes when the response is sent).

## Logging

Always via loguru:
```python
from open_webui.utils.logger import log
log.info("message")
log.debug(f"value: {val}")
log.exception(e)  # includes full traceback
# NEVER: print(), import logging
```

Structured JSON logging enabled by `LOG_FORMAT=json` env var.

## Key Constants

- `ERROR_MESSAGES` enum in `constants.py` — all user-facing error strings, some are lambdas: `ERROR_MESSAGES.MODEL_NOT_FOUND('llama3')`
- `TASKS` enum in `constants.py` — task type identifiers for background work
- Socket.IO channel pattern: `{user_id}:{session_id}:{request_id}`
