# todo-api

A minimal REST API for managing todo items. Built with Python/Flask.

## Setup

```bash
pip install -r requirements.txt
python app.py
```

## Testing

```bash
python -m pytest tests/
```

## API

- `GET /todos` — List all todos
- `POST /todos` — Create a todo (body: `{"title": "..."}`)
- `DELETE /todos/:id` — Delete a todo
