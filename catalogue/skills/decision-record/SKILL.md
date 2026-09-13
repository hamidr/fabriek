---
name: decision-record
description: Write, number, supersede and index an architecture decision record under docs/adr/ in the repository being worked. Use whenever a design choice is made, changed or withdrawn.
---

# Decision records

## Where

`docs/adr/ADR-NNN-<slug>.md`, three digits, numbered in order of writing
and never reused. `docs/adr/README.md` is the index: one line per record,
number, title, status.

## Next number

```sh
ls docs/adr | grep -o '^ADR-[0-9]*' | sort | tail -1
```

## Shape

```markdown
# ADR-012: A task is a forge issue and nothing else

Status: accepted | proposed | superseded by ADR-020 | withdrawn
Date: 2026-09-13

## Context
What was true and what forced a choice. Facts, measured where they can be.

## Decision
What is decided, in numbered points, each one sentence you could test.

## Consequences
What this costs, what it forbids, what it makes easy. Trade-offs accepted
knowingly, written so the next reader does not relitigate them.
```

One page. Prose in the language of `docs/GLOSSARY.md`.

## Rules

- A record is written before the code that follows it, as proposed; it
  becomes accepted when that code is integrated.
- Never rewrite a record into a different decision. Write a new one, set
  the old one's status to `superseded by ADR-NNN`, and say in the new
  one's context why the old one no longer holds.
- A withdrawn record stays in the tree; deleting it deletes the reason.
- Every record the overview cites must exist; every accepted record that
  shaped the tree must be cited by the overview.
- Update the index in the same commit as the record.
