# Working this repository

Read by every role at the front of its brief, from its own worktree, so
a line here reaches a role as soon as its branch carries it (ADR-050).
The manager keeps it; a line is added when the record shows the same
friction twice, and removed when it stops earning its place.

## Tests

The suite is `pytest -q` from the repository root; `pyproject.toml`
puts the root on `sys.path`. Every role's shell carries `pytest`.
Do not look for it under `/nix/store`, and do not write a
`conftest.py` to fix the path: it is already fixed.

## Stages

- At `design`, write the approach down and split the work: which
  function changes, what the test asserts, what must not be touched.
  Do not implement; the builder does, from your record.
- At `build`, the test comes first and is seen failing before the change
  that makes it pass; the guard refuses the other order.
- At `review`, run the suite yourself and read the diff against the
  design's record; `done` is a verdict, not a change.

## What not to touch

`fabriek.toml`, `flake.nix` and this file belong to the manager; a
builder that needs them changed says so in its outcome.
