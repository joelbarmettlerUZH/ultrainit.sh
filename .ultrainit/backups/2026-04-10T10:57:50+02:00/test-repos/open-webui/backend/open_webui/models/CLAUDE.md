# open_webui Models

SQLAlchemy ORM + Pydantic schemas + Repository pattern. 22 domain files, flat directory.

## The One-File Entity Pattern

Every file has exactly 5 sections in order:

```python
# 1. SQLAlchemy ORM table class
class Chat(Base):
    __tablename__ = 'chat'
    id = Column(String, primary_key=True)
    user_id = Column(String)
    chat = Column(JSONField)  # use JSONField not Column(JSON)
    created_at = Column(BigInteger)  # epoch seconds, never datetime

# 2. Pydantic model (API responses)
class ChatModel(BaseModel):
    model_config = ConfigDict(from_attributes=True)  # enables ORM validation
    id: str
    user_id: str
    # ...

# 3. Request/response Pydantic classes
class ChatForm(BaseModel): ...  # inbound
class ChatResponse(BaseModel): ...  # outbound

# 4. Repository class - ALL CRUD here, static methods only
class ChatsTable:
    def get_chat_by_id(self, id: str, db: Optional[Session] = None):
        with get_db_context(db) as db:
            chat = db.query(Chat).filter_by(id=id).first()
            return ChatModel.model_validate(chat) if chat else None

# 5. Module-level singleton
Chats = ChatsTable()
```

Never call SQLAlchemy directly outside repository classes. Never return raw ORM objects — always convert: `ModelClass.model_validate(orm_obj)`. Use `model_validate`, not the deprecated `.from_orm()`.

## Session Pattern

All methods accept `db: Optional[Session] = None` and use `get_db_context(db)`:

```python
def create_chat(self, form_data: ChatForm, db: Optional[Session] = None):
    with get_db_context(db) as db:
        obj = Chat(**form_data.model_dump())
        db.add(obj)
        db.commit()
        db.refresh(obj)
        return ChatModel.model_validate(obj)
```

`DATABASE_ENABLE_SESSION_SHARING=False` (default) means `get_db_context(db)` opens a fresh session even when `db` is passed. Set to `True` for transactional consistency across multiple model calls.

## Column Conventions

| Convention | Rule |
|-----------|------|
| Primary keys | `str(uuid.uuid4())` — UUID strings, never integers |
| Timestamps | `BigInteger` epoch seconds — `int(time.time())` |
| JSON columns | `JSONField` from `open_webui.internal.db` |
| Boolean flags | `is_` prefix: `is_active`, `is_private`, `is_pinned` |
| FK columns | `entity_id`: `user_id`, `chat_id`, `group_id` |
| Flexible data | `data`, `meta`, `info` column names |

## Chat Messages Are a Tree

The `chat.chat` column is a JSON blob with tree structure for conversation branching. The normalized `chat_message` table was added later for search:

```python
# WRONG - raw SQL against chat column
db.execute("SELECT chat FROM chat WHERE ...")  # returns JSON blob

# RIGHT - use repository methods
chat = Chats.get_chat_by_id(chat_id, db=db)
messages = chat.chat.get('messages', {})
```

Shared chats use synthetic `user_id = 'shared-{original_chat_id}'`. Queries filtering by `user_id` will miss shared chats.

## AccessGrant Integration

For shareable resources (knowledge, model, prompt, tool, note, channel, file):

```python
# On write — filter before persisting
from open_webui.utils.access_control import filter_allowed_access_grants
filtered = filter_allowed_access_grants(user.id, form_data.access_grants, 'sharing.public_tools', config.USER_PERMISSIONS)
AccessGrants.set_access_grants('tool', tool_id, filtered, db=db)

# On list read — batch check prevents N+1
AccessGrants.has_permission_filter('tool', user_id, 'read')  # as JOIN clause
```

Public access uses `principal_id='*'` (string asterisk), not NULL. Always use `AccessGrants.has_access()` rather than raw grant queries.

## Tag IDs Are Derived

Tag IDs are normalized: `name.replace(' ', '_').lower()`. Always normalize before lookup:
```python
tag_id = name.replace(' ', '_').lower()
```

## Null-Byte Sanitization

LLM-generated text can contain null bytes that corrupt SQLite JSON on INSERT. Apply sanitization to any user-facing text before persistence. The pattern lives in `chats.py` — copy it for new text fields that accept LLM output.
