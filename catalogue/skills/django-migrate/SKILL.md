---
name: django-migrate
description: Create, check and apply Django migrations after a model change, and decide when a migration must not be edited. Use whenever models.py changes.
---

# Django migrations

## After a model change

```sh
python manage.py makemigrations <app>
python manage.py migrate
python manage.py makemigrations --check --dry-run
```

The third line must print nothing: an unrecorded model change fails review.

## Rules

- Never edit a migration that may have been applied anywhere. Add a new one.
- Name the migration for what it does: `makemigrations <app> -n add_invoice_currency`.
- A data migration is its own file with `RunPython` and a reverse; a schema
  change and a data change are two migrations.
- A field made non-null on an existing table needs a default or a two-step
  migration (add nullable, backfill, make required).
- `python manage.py check` before reporting done; it catches what
  `makemigrations` does not.

## When the project uses a custom settings module

Read `manage.py` for the `DJANGO_SETTINGS_MODULE` it sets, and pass
`--settings` only when the project's own docs say to.
