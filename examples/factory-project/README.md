# importer

A small CSV importer, and a repository a fabriek factory works.

The code is `importer/`, the suite `tests/` (`pytest -q` from the root).
`fabriek.toml` declares who works it: an architect, a manager, a backend
and a frontend builder, a reviewer, and the workflow `ship` they move a
task through. `flake.nix` gives each role its shell. `docs/` carries the
two files the manager keeps, the guidance every role reads and the
policy the decider is built with; `fabriek/catalogue/` is this
repository's own specialist and skill beside fabriek's.

    fabriek check .                 # what a factory would refuse, in seconds
    fabriek ls . ; fabriek show python .
