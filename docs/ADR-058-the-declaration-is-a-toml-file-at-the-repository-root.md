---
id: ADR-058
title: The declaration is fabriek.toml at the repository root, and no expression of the repository's is evaluated to read it
status: proposed
date: 2026-09-15
status_date: 2026-09-15
summary: fabriek.toml replaces fabriek.nix and the flake's fabriek output; read from the commit with git show and fromTOML
depends_on: [ADR-020, ADR-042, ADR-057]
supersedes: []
superseded_by: []
---

## Context

ADR-020 put the declaration in the repository it works, as the `fabriek`
output of the repository's flake, and made its schema closed: plain data,
no NixOS, validated field by field (`modules/schema.sh`). The example
keeps it in `fabriek.nix` and imports it from `flake.nix`. Reading it is
`nix eval --json --no-allow-import-from-derivation` of
`(builtins.getFlake "git+file://<path>?rev=<sha>").fabriek`
(`modules/repo-declaration.sh`, `modules/check.sh`, and under ADR-040 the
same inside a derivation).

Three things follow from a flake output that are not wanted for a file of
plain data. Reading it evaluates the repository's `flake.nix`, which fetches
every input the flake names and runs whatever Nix the repository put in
front of the output; the schema is closed but the road to it is not, which
is why ADR-057 point 6 restricts evaluation on the machine. A repository
that does not use Nix has to grow a `flake.nix` to declare a factory,
where ADR-005 let a project have none. And the operator's side is a TOML
file (`config.toml`, ADR-020 point 4, ADR-048), so the two files a person
edits to run a factory are in two languages for the same kind of thing.

The schema is a tree of strings, numbers, lists and tables. TOML holds all
of it; the operator's file already does.

## Decision

**1. The declaration is `fabriek.toml` at the repository root.** Same
schema, same keys, same refusals: `schema.sh`, `resources.sh`, `sizes.sh`
and `names.sh` validate the same JSON they validate today, produced by
`builtins.fromTOML` instead of by evaluating the repository. The example
becomes:

```toml
name = "example"
catalogue = "fabriek/catalogue"

[roles.backend]
provides = ["build"]
specialists = ["springboot", "python"]
shell = "backend-jvm"

[workflows.ship]
budget.runs = 200

[[workflows.ship.stages]]
needs = "build"
ready = ["acceptance"]
done = "tests pass and the change is reviewable"

[workflows.ship.consults]
backend = ["architect"]

[resources]
memory = "8G"
cores = 4
concurrency = 3
egress = ["api.anthropic.com"]

[decider]
policy = "docs/decider-policy.md"
```

**2. It is read from the commit with `git show <rev>:fabriek.toml`**, which
keeps ADR-020 point 3a (never the working tree) without fetching a flake,
and parsed with the reader `operator-config.sh` already has, `nix eval
--expr 'builtins.fromTOML ...'`, over the text written to a file and read
with `builtins.readFile` rather than through the environment, so the size
is the file's and a parse error keeps nix's line number. No expression of
the repository's runs; the evaluation is fabriek's fixed one over a
string. A repository with no `fabriek.toml` at the rev is refused naming
the file and the rev; one with a `fabriek` flake output and no file is
refused the same way, with a sentence saying the output is no longer
read. The output is never read: with both present the file is the
declaration and `check` says once that the output is ignored.

**3. What stays Nix stays where it is, and is read at the same rev.**
`shell` names a devShell of the repository's `flake.nix` (ADR-016),
realised by the machine's daemon under ADR-057 point 5; a repository
whose roles name no `shell` needs no flake at all. A catalogue specialist's
`default.nix` names its tools as `pkgs` values (ADR-042) and is evaluated
where the catalogue is composed, from the repository at the rev and never
its working tree: `builtins.fetchGit { url; rev; }` on the operator's
host, the clone on the machine. The declaration itself names both by
string. `check` keeps the refusal the build gave: a role naming a `shell`
has `devShells.<system>.<shell>` evaluated at the rev and is refused when
the flake lacks it (ADR-057 point 9 allows `check` that evaluation); a
declaration naming no `shell` has nothing evaluated.

**4. `fabriek.nix`, the `fabriek` flake output and their readers go.**
`fabriek_declaration_read` reads the file; `check.sh` and ADR-057's
`factory-prepare` call it; `examples/factory-project/flake.nix` stops
importing a declaration and keeps its devShells. ADR-020's point 1 (the
mechanism, not the placement), 2 and 3a are amended to say the file and
the read; the rest of ADR-020 stands.

**5. This lands before ADR-057, not after it.** `depends_on` names 057
because the appliance's prepare reads the file too; the change itself is
`modules/factory.nix` reading `builtins.fromTOML (builtins.readFile
"${project}/fabriek.toml")` where it read `project.fabriek`, and
`repo-declaration.sh` swapping one `nix eval` of the flake for `git show`
and `fromTOML`. Both fit the machine as built.

## Consequences

A factory can be declared in a repository that has no Nix in it, which
ADR-020 point 1 wanted ("a description of how a repository is worked")
and its mechanism denied. `fabriek check` on the operator's host reads a
file; what it still evaluates is the catalogue, for the specialists each
role names, and the repository's flake only when a role names a `shell`.

ADR-057 point 6's restriction on evaluation stays for the devShell and the
repository's own catalogue, which are Nix by nature; the declaration is no
longer one of the things it protects.

A declaration cannot be computed. A repository that generated roles from
a list, or shared a stage between workflows by a `let`, writes them out.
That is the price of a file that is data, and it is the same price
`config.toml` already charges the operator.

Existing repositories move by writing the file once; `fabriek check` says
what is missing. Nothing on the machine changes shape: `declaration.json`
is the same JSON from a different parser.

## Verification

`tests/unit/repo_declaration.bats`: a committed `fabriek.toml` is read at
the rev and not from the working tree; a missing file is refused naming
the file and the rev; a repository with only a `fabriek` output is refused
with the sentence about the output; every refusal `schema.sh` gives for
JSON is given for the same TOML. `tests/command/check.bats`: `fabriek
check` on the example passes with no `nix eval` of the repository in the
stubbed nix's calls. `tests/command/factory_flake.bats` and, under
ADR-057, the prepare test read the example's TOML. The example's
`flake.nix` carries no `fabriek` output.
