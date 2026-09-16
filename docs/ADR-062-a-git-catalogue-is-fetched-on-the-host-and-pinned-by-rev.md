---
id: ADR-062
title: A git catalogue is fetched on the host at up and check, pinned by rev, and carried as a store path
status: proposed
date: 2026-09-16
status_date: 2026-09-16
summary: a catalogue may be a git repository at a rev; the host fetches it, the machine reads a store path as before
depends_on: [ADR-042, ADR-057, ADR-061]
supersedes: []
superseded_by: []
---

## Context

A catalogue is a directory with one layout (ADR-042): `specialists/<name>/`
holding a `default.nix` and a `PROMPT.md`, `skills/<name>/` holding a
`default.nix` and a `SKILL.md`. Each `default.nix` is a function of the
machine's `pkgs` and of the other entries, and returns what the specialist
brings: `tools` as packages, `extends`, `skills`, `prompt`, `lsp` (ADR-043)
and `tests` (ADR-044). It is Nix, so a catalogue may build a tool of its own
from sources in its tree, which the shipped `committer` does.

ADR-061 point 4 lets the operator name catalogue directories in
`config.toml` (`catalogues = [ "<dir>" ]`) and in `services.fabriek.catalogues`.
`up` adds each to the host's store, roots it, and the store path travels to
the machine in the credential; render composes it beside fabriek's and the
repository's, each name once. On a NixOS host that is already a catalogue
kept by someone else: `catalogues = [ "${inputs.acme}/catalogue" ]` is a
store path the flake lock pins. On a host with a plain `config.toml` the
operator clones by hand, keeps the checkout current by hand, and nothing
records which rev of it a run was given.

ADR-060 point 3, which ADR-061 kept, says a catalogue reaches the evaluator
as "a directory of files the host put there, not a URI to fetch". The
reason was the machine: it fetches nothing it did not fetch before (ADR-057
point 6). The host is a different matter; `up` already runs `nix` there.

## Decision

**1. A `catalogues` entry may be a git repository at a rev.** Beside the
directory string, an entry may be a table:

```toml
catalogues = [
  "/home/op/catalogue",
  { git = "github:acme/fabriek-catalogue", rev = "3f2a1c0e...", dir = "catalogue" },
]
```

`git` is a flake reference to a git tree (`github:`, `gitlab:`,
`git+ssh://`, `git+https://`, `git+file://`), whether or not the tree is a
flake, with no query and no fragment: `rev` is the one pin and has one
place, so `ref=`, `submodules=1` or a second `rev=` cannot ride in the
URL. `rev` is a full commit hash and is required: there is no `ref`, no
branch, no lock file, and no `--update` for a catalogue. Submodules are
not fetched; a catalogue vendors what it needs. `dir` is optional, a path
inside the tree with ADR-042's layout, absent meaning the root.
`modules/operator-config.sh` refuses any other key by name, a `git` with a
`?` or a `#`, a `rev` that is not forty hex digits, and a `dir` that is
absolute or leaves the tree. `services.fabriek.catalogues` gains nothing:
a flake input is the same thing with the lock as its pin.

**2. The host fetches, at `up` and at `check`, and nothing else does.**
`nix flake prefetch --json "<git>?rev=<rev>"` puts the tree in the host's
store and answers with its store path; `dir` is joined to it. From there
the entry is a directory entry: `up` roots the path under the factory's
machine directory (ADR-057 point 5a, ADR-061 point 6); render composes it
as `extra` in `modules/catalogue.nix`, granted to the evaluator on the
search path. The machine sees a store path of the lower store, as it does
for a directory, and fetches nothing. A private repository is fetched
with the host's own git and ssh, the operator's credentials, which never
reach the machine (invariant 2). What `check` fetched is not rooted; a
host collection between `check` and `up` drops it and `up` fetches it
again, to the same path.

**3. A git catalogue builds from what the machine's daemon could build
before.** Its `default.nix` is evaluated and built by the daemon under
ADR-057 point 6, and this record widens none of it. At evaluation,
`--restrict-eval` with `allowed-uris` naming the clone and the worked
repository's locked inputs: `builtins.fetchurl`, `builtins.fetchGit` or a
flake input the catalogue reaches for is refused by nix, and the role
that named the specialist is refused with its name. At build, the
evaluator and the substituter run as root and leave, a build user does
not: a tool resolved from `pkgs` realises when its closure substitutes; a
tool built from sources in the catalogue's own tree builds; a fixed-output
derivation of the catalogue's own (`pkgs.fetchurl` and its kin) realises
only when the cache already holds its output, and otherwise fails at
prepare with nix's own message and the role's name. A catalogue that
needs a source from elsewhere vendors it into its tree.

**4. Refusals fire at `check`, one line each** (ADR-061 point 8): a
repository or rev nix cannot fetch, with nix's message; a `dir` the tree
lacks; a tree with neither `specialists/` nor `skills/` under `dir`; a
name declared twice across the sources, as today. `fabriek show
<specialist>` names the catalogue's `git` and `rev` as its source.

**5. A run's record names the rev.** The credential's `catalogues` entry
for a git catalogue is a table, `{ path, git, rev, dir }`, the store path
beside the entry as the operator wrote it; a directory entry stays the
string it is. The machine reads `path` of a table and a string as it is,
and nothing else of the table. The copy `up` keeps beside `runtime.json`
is that credential (ADR-061 point 6), so `fabriek show -f` prints which
catalogue at which commit a run was given, and a person can read that
commit on the forge it lives on. Moving a catalogue is editing `rev`,
`down` and `up`, as changing the caps is.

## Consequences

An operator on a plain host names a catalogue someone else keeps and pins
it in the file they already keep, and two hosts with the same file run the
same catalogue. A catalogue published for others is a git repository with
ADR-042's layout at its root or under one directory, and nothing more; the
shipped catalogue could become one such entry, and this record does not
move it.

What is evaluated and built widens: a third party's Nix, chosen by the
operator, runs in the machine's daemon and its build sandbox, and its
outputs reach a cage only as the role's profile closure (nixcage ADR-014).
That is the surface a repository's own catalogue has today, held by the
same restricted evaluation; the rev pin is what makes it reviewable, and a
`ref` would have made it a moving target under a running factory, which is
why there is none.

`up` and `check` need the network to fetch a rev the host's store does not
hold, and `check` stops being evaluation-only in that one case. The store
path is content-addressed by the tree, so the same entry fetched on two
hosts is the same path, and a rev already in the store is not fetched
again. The same rev through two references need not be: `github:` is the
forge's tarball with `export-ignore` applied, `git+https://` the tree as
git holds it, so an operator who wants two hosts to agree writes the same
`git` on both.

ADR-060 point 3's "not a URI to fetch" is narrowed to the machine.
`modules/operator-config.sh` grows the table form and its refusals;
`fabriek`'s `machine_store_operator_files` grows the prefetch before the
add; `modules/credential.sh` writes the table and the machine's reader of
`catalogues` takes `path` of one; `modules/catalogue.nix`,
`modules/host.nix` and `seam.bats` are untouched.

## Verification

```bash
nix develop --command bats tests/unit/operator_config.bats tests/command/vm_up.bats \
  tests/command/check.bats tests/command/catalogue.bats
docmeta-check docs && docmeta-tracker --check docs
```

Scenarios, written first: a table entry accepted and a directory entry
beside it; `rev` missing, short, or not hex refused by name; `dir`
absolute refused; a `git` with a query or a fragment refused; `up`
prefetching the rev (the `nix` stub answering `flake prefetch --json`
with a store path), rooting it, and writing the table into the credential
with the store path beside `git`, `rev` and `dir`; the machine's reader
taking `path` of a table and a string as it is;
`check` naming a fetch that failed with nix's line; a tree without the
layout refused; `show -f` printing `git` and `rev`; `catalogue.bats`
composing a git catalogue from a `git+file://` tree at a rev for real, a
specialist of it on a role's PATH. On a machine: `tests/manual/specialist.sh`
with the example's backend role naming a specialist from a git catalogue.
Recorded here when run.
