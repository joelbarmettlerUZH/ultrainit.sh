# open_webui Routers

28 FastAPI `APIRouter` files, one per resource domain. Flat directory — no subdirectory grouping.

## Anatomy of a Router Function

```python
@router.get("/id/{resource_id}")
async def get_resource(
    resource_id: str,
    user: UserModel = Depends(get_verified_user),  # always last user dep
    db: Session = Depends(get_session),            # always last param
):
    # 1. Fetch resource
    resource = Resources.get_by_id(resource_id, db=db)
    if not resource:
        raise HTTPException(status_code=404, detail=ERROR_MESSAGES.NOT_FOUND)

    # 2. Access control
    if resource.user_id != user.id:
        if not AccessGrants.has_access(user.id, 'resource', resource_id, 'read', db=db):
            raise HTTPException(status_code=401, detail=ERROR_MESSAGES.UNAUTHORIZED)

    return resource
```

## Auth Dependencies

- `Depends(get_verified_user)` — any authenticated non-pending user
- `Depends(get_admin_user)` — admin role required (use this, not manual role check)
- `Depends(get_current_user)` — extracts user, no role gate (rare)
- `Depends(get_session)` — SQLAlchemy session, always last

## Three-Layer Access Control

Check in order. Missing any layer is a security gap:

```python
# 1. Admin bypass (check config flag)
if user.role == 'admin' and not BYPASS_ADMIN_ACCESS_CONTROL:
    pass  # bypass

# 2. Feature gate (workspace-level permission)
if not has_permission(user.id, 'workspace.models', config.USER_PERMISSIONS):
    raise HTTPException(401, ERROR_MESSAGES.UNAUTHORIZED)

# 3. Per-resource grant
if not AccessGrants.has_access(user.id, 'model', model_id, 'read', db=db):
    raise HTTPException(401, ERROR_MESSAGES.UNAUTHORIZED)
```

**Batch check for list endpoints** (prevents N+1):
```python
user_group_ids = {g.id for g in Groups.get_groups_by_member_id(user.id, db=db)}
writable_ids = AccessGrants.get_accessible_resource_ids(
    'model', user.id, resource_ids=[m.id for m in models],
    permission='write', db=db
)
for m in models:
    m.write_access = m.id in writable_ids
```

## URL Conventions

- List: `GET /list`
- Create: `POST /create`
- Single: `GET /id/{id}`
- Update: `POST /id/{id}/update`
- Delete: `DELETE /id/{id}/delete`
- Toggle: `POST /id/{id}/toggle`
- Access: `POST /id/{id}/access/update`

**Model IDs can contain `/`** (e.g., `ollama/llama3:8b`). Use query params not path segments: `GET /model?id=ollama/llama3` not `GET /model/{id}`.

## Error Handling Pattern

```python
try:
    result = do_something()
except HTTPException:
    raise  # must re-raise before bare except
except Exception as e:
    log.exception(e)
    raise HTTPException(status_code=500, detail=ERROR_MESSAGES.DEFAULT(e))
```

## memories.py Special Case

`memories.py` intentionally omits `Depends(get_session)` to avoid holding a DB connection during multi-second embedding calls. Adding a session to memory endpoints causes connection pool exhaustion under load. Use the model's internal session management.

## Access Grants Update is Destructive

`POST /id/{id}/access/update` **completely replaces** all grants — it is not additive. Always fetch current grants, merge changes, and submit the full list.

## Primary Admin Protection

The first user in the DB (primary admin) is protected from deletion/demotion:
```python
if user.id == Users.get_first_user(db=db).id:
    raise HTTPException(400, ERROR_MESSAGES.ACTION_PROHIBITED)
```
Never bypass this check when adding new admin-delete flows.
