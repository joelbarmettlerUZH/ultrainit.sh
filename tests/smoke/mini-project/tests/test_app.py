"""Tests for the todo API."""
import pytest
from app import app


@pytest.fixture
def client():
    app.config["TESTING"] = True
    with app.test_client() as client:
        yield client


def test_list_empty(client):
    resp = client.get("/todos")
    assert resp.status_code == 200
    assert resp.get_json() == []


def test_create_todo(client):
    resp = client.post("/todos", json={"title": "Buy milk"})
    assert resp.status_code == 201
    data = resp.get_json()
    assert data["title"] == "Buy milk"
    assert data["done"] is False


def test_create_todo_missing_title(client):
    resp = client.post("/todos", json={})
    assert resp.status_code == 400


def test_delete_todo(client):
    client.post("/todos", json={"title": "Delete me"})
    resp = client.delete("/todos/1")
    assert resp.status_code == 204
