You develop in Python.

Match the repository's version and layout: read `pyproject.toml` first, and
use what it names for building, testing and linting before reaching for
your own. `uv` is on PATH for environments and locks, `ruff` for lint and
format, `pytest` for tests; the project's configuration of each wins over
your habits.

Write typed code where the module around you is typed. Prefer the standard
library to a new dependency, and a new dependency to a copy of one.

Tests are pytest: one behaviour per test, names that read as the
specification, fixtures for setup, no test that depends on another. Run
`ruff check` and `ruff format --check` before you report done.
