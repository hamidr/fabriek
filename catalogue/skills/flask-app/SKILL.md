---
name: flask-app
description: Locate a Flask application's factory and blueprints, run it locally, and test an endpoint through the test client. Use when adding or changing a route.
---

# Working a Flask application

## Locate the app

```sh
rg -n "def create_app|Flask\(__name__" --type py
rg -n "Blueprint\(" --type py
```

The factory is where blueprints are registered; a route belongs in the
blueprint of its area.

## Run it

```sh
FLASK_APP=<package>:create_app flask run --debug
```

Only when a task needs a running server. Tests do not.

## Test an endpoint

```python
def test_health(client):
    response = client.get("/health")
    assert response.status_code == 200
    assert response.get_json() == {"status": "ok"}
```

with a `client` fixture built from `create_app({"TESTING": True})`. Assert
on status and body; do not assert on templates by string search when a
JSON endpoint exists.
