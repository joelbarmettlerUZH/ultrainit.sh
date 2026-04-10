# Alembic Migration Versions

35 linear migration files. This is the current schema system (Peewee migrations 001–018 ran first at a lower layer).

## The Only Rules You Need

**Never edit existing files.** Generate new ones:
```bash
alembic revision --autogenerate -m 'add_foo_table'
# Then review and customize the generated file
alembic upgrade head
```

Check `util.py` for `get_existing_tables()` and `get_revision_id()` helpers.

## SQLite Compatibility (Required for ALL column changes)

SQLite cannot ALTER COLUMN type or DROP COLUMN. Always wrap:
```python
# WRONG for SQLite:
op.alter_column('table', 'col', type_=sa.JSON())
op.drop_column('table', 'col')

# CORRECT:
with op.batch_alter_table('table', schema=None) as batch_op:
    batch_op.alter_column('col', type_=sa.JSON())
    batch_op.drop_column('col')
```

For PostgreSQL type conversions with cast:
```python
op.alter_column('folder', 'created_at',
    type_=sa.BigInteger(),
    postgresql_using='extract(epoch from created_at)::bigint')
```

## Column Conventions

| Field | Type | Notes |
|-------|------|-------|
| Primary keys | `Text()` (UUID strings) | Exception: config uses `Integer` |
| Timestamps | `BigInteger` (epoch seconds) | Exception: config uses `DateTime` (historical bug) |
| JSON data | `sa.JSON()` | Older migrations used `JSONField` (TEXT-serialized) |
| Boolean flags | `sa.Boolean()` with `server_default=sa.sql.expression.true()/false()` |
| Foreign keys | Always include `ondelete='CASCADE'` |

## Idempotency Guard

Always guard `CREATE TABLE` calls:
```python
from open_webui.migrations.util import get_existing_tables
existing_tables = get_existing_tables(op.get_bind())
if 'new_table' not in existing_tables:
    op.create_table('new_table', ...)
```

## Adding NOT NULL Columns to Existing Tables

Always use `server_default` to avoid constraint violations on existing rows:
```python
batch_op.add_column(sa.Column('is_active', sa.Boolean(),
    nullable=False, server_default=sa.sql.expression.true()))
```

## Data Migration Pattern

Hybrid schema+data migrations are the norm:
```python
def upgrade():
    # 1. Add new column
    op.add_column('table', sa.Column('new_col', sa.JSON()))

    # 2. Backfill using Core API (not ORM)
    conn = op.get_bind()
    t = sa.Table('table', sa.MetaData(), autoload_with=conn)
    for row in conn.execute(sa.select(t)).fetchall():
        parsed = json.loads(row.old_col or '{}')
        conn.execute(t.update().where(t.c.id == row.id).values(new_col=parsed))

    # 3. Drop old column (via batch_alter for SQLite)
    with op.batch_alter_table('table') as batch_op:
        batch_op.drop_column('old_col')
```

## Access Control Migration

The `access_control` JSON column pattern was fully replaced by the `access_grant` table in `f1e2d3c4b5a6`. **Do not add new `access_control` columns** — use the `access_grant` table. The `access_control_to_grants()` and `grants_to_access_control()` converters in `models/access_grants.py` handle backward compatibility.

## One-Way Migrations

Several `downgrade()` functions are bare `pass` (e.g., `1af9b942657b` tag normalization). Never run `alembic downgrade` past these in production. Always back up the database before running migrations on production.

## Timestamps From JSON Blobs (Normalization Pattern)

When backfilling timestamps from legacy JSON data:
```python
def _normalize_timestamp(v):
    ts = int(float(v))
    if ts > 10_000_000_000:  # milliseconds → seconds
        ts = ts // 1000
    MIN_TS = int(datetime(2020, 1, 1).timestamp())
    MAX_TS = int(time.time()) + 86400
    return ts if MIN_TS <= ts <= MAX_TS else int(time.time())
```
