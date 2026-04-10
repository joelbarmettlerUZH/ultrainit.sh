# Socket Module

Socket.IO real-time layer for LLM streaming delivery, collaborative editing (Yjs CRDT), channel messaging, and distributed session management.

## Room Namespaces

| Room | Purpose |
|------|----------|
| `user:{user_id}` | LLM stream delivery to an individual |
| `channel:{channel_id}` | Group channel messages |
| `doc_note:{note_id}` | Collaborative note editing (note: underscore separator) |

Always emit to a room, never to a raw `sid` (except direct state responses). Join rooms explicitly via `sio.enter_room(sid, room)` before emitting.

## Event Emitter Factory

```python
from open_webui.socket.main import get_event_emitter

# In route handlers and middleware:
emitter = get_event_emitter(metadata)  # metadata has user_id, chat_id, message_id
await emitter({'type': 'status', 'data': {'description': 'Searching...', 'done': False}})
await emitter({'type': 'message', 'data': {'content': 'chunk'}})
```

Socket.IO channel names are `{user_id}:{session_id}:{request_id}`. Missing any ID means events are silently dropped — populate all three in metadata before starting a streaming response.

## RedisDict — No In-Process Cache

`SESSION_POOL`, `USAGE_POOL`, and `MODELS` are `RedisDict` instances. **Every attribute access is a Redis HGET.** In hot event handlers:

```python
# CORRECT: read once into local variable
user = SESSION_POOL.get(sid)
if user:
    user_id = user.get('id')
    # use user_id, not SESSION_POOL[sid]['id'] again

# WRONG: multiple Redis round-trips per handler
if SESSION_POOL.get(sid):
    do_something(SESSION_POOL[sid]['id'])  # 2 Redis calls
```

## Distributed Cleanup

Periodic cleanup jobs run on every instance but coordinate via `RedisLock`:

```python
async def periodic_session_pool_cleanup():
    lock = RedisLock(REDIS, 'session_cleanup_lock', timeout=60)
    if await lock.acquire():
        try:
            # only one instance does real work
            cleanup_stale_sessions()
        finally:
            await lock.release()
```

Always use `RedisLock` for distributed periodic jobs — plain `asyncio.Lock` is instance-local and doesn't coordinate across replicas.

## Yjs CRDT Compaction

`YdocManager` stores Yjs updates as Redis lists. At 500 items, the oldest 50% are compacted into a snapshot using `pycrdt`, inside a Redis pipeline. **Compaction is not protected by a per-document lock** — concurrent compaction across instances can corrupt the updates list. In production multi-instance deployments, wrap compaction in a per-document `RedisLock`.

## Session Pool Timeout

`periodic_session_pool_cleanup` reaps sessions with `last_seen_at` older than `SESSION_POOL_TIMEOUT` (120s). If a client's heartbeat frequency exceeds 120s, the session is reaped while the connection is alive. Default `WEBSOCKET_SERVER_PING_INTERVAL` is 25s — ensure clients send application-level heartbeat events well below 120s.

## WebSocket Manager vs State Redis

`WEBSOCKET_MANAGER=redis` uses `AsyncRedisManager` (a separate pub/sub connection) alongside the state Redis (`REDIS` global). Both use `WEBSOCKET_REDIS_URL` but are distinct connections. Misconfiguring one breaks event delivery silently.

## Document ID Normalization

Colons in document IDs are converted to underscores for Redis key safety. The canonical form is `note:{id}` — always pass this form to `ydoc:*` events. Do not use the underscore form (`note_abc`) outside of `YdocManager` internals.
