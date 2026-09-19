---
id: ADR-066
title: A catalogue says so through its default.nix, and every specialist reaches the base
status: implemented
date: 2026-09-19
status_date: 2026-09-19
summary: a catalogue directory calls fabriek.catalogue at a protocol version; every other specialist extends a shipped one
depends_on: [ADR-042, ADR-061, ADR-062]
supersedes: []
superseded_by: []
---

## Context

ADR-042 made a catalogue a directory with a layout: `specialists/<name>/`
and `skills/<name>/`, each entry a `default.nix` against a closed schema.
ADR-061 and ADR-062 let an operator name more of them, as directories and
as git trees at a rev. What made a directory a catalogue was only that
somebody pointed at it. `modules/catalogue.nix` read `specialists/` and
`skills/` if present and found nothing otherwise, so a wrong path, a
subdirectory one level off, or a repository that was never a catalogue
composed as an empty one, and the refusal came later as `role backend
names specialist local, which no catalogue declares`. Nothing said which
protocol a catalogue was written against, so a change to the layout could
not be refused by version; it would be read wrongly instead.

The same held for a specialist. Any directory under `specialists/` was
one, whatever it extended. The example repository's `release-here`
extended nothing and relied on the role composing it beside a shipped
specialist to get `committer`'s kit and voice. A role naming only such a
specialist would have run with neither, and nothing refused it.

## Decision

**1. A catalogue is a directory whose `default.nix` says so.** It calls
the constructor fabriek hands it:

```nix
{ fabriek }: fabriek.catalogue { version = 1; }
```

`version` is required and is the protocol this fabriek speaks, `1`.
`specialists` and `skills` are optional paths, defaulting to the two
directories beside the file. Any other key is refused by name. The
constructor tags what it is given and nothing more; every check runs in
`modules/catalogue.nix`, where the directory is known, so a refusal names
it: no `default.nix` (`has no default.nix, so it is not a catalogue`), a
`default.nix` that returns something untagged (`does not call
fabriek.catalogue`), no version, a version this fabriek does not speak
(`speaks protocol version 2; this fabriek speaks 1`). A directory is never
read as an empty catalogue.

**2. The rule holds for every catalogue directory.** fabriek's own,
the repository's (`catalogue` in `fabriek.toml`), and the operator's
directories and git trees (`catalogues` in the operator's file). The
operator's TOML `[specialists]` and `[skills]` are not directories; they
enter through the schema `modules/operator-config.sh` already checks and
are unchanged.

**3. The shipped catalogue is the base, and every specialist reaches it.**
A specialist declared anywhere else, in a directory or in TOML, has a
specialist of the shipped catalogue among what it extends, transitively,
or is refused: `specialist alone extends nothing of fabriek's catalogue;
extend committer or one of its descendants`. The name offered is computed:
the base's specialists that extend nothing. The check runs in `compose`
after flattening, so a cycle or an unknown key is still refused as itself.

**4. Nothing new reaches the evaluator.** The constructor is passed by
value when a catalogue's `default.nix` is imported, so the restricted
evaluations on the host (`modules/check.sh`) and at render
(`modules/profile.nix`) grant no new path.

## Consequences

A repository's catalogue is one four-line file more than it was. In
return a path that is not a catalogue is refused as such, at `fabriek
check` on the host before a machine exists, and a later change to what a
catalogue is can be refused by version rather than misread.

The example's `release-here` now extends `committer`. Its role composed it
beside `python` already, so the flattened set is the same; what changed is
that a role naming it alone would carry the base too.

A specialist can no longer be a bare prompt with no parent. That is the
point: the base is what every role is told about working in a cage, and
its tools for reading a repository, and a specialist that skipped it was
a role with neither.

`tests/command/catalogue.bats` builds a derivation that now includes
`committer`'s tools for fixtures that used to carry none, so a scenario's
first run builds where it used to hit the cache; the build helper keeps
nix's progress lines out of a passing scenario's output.

## Verification

Written and seen failing before the code, in the runner the component has:

```bash
nix develop --command bats tests/command/catalogue.bats
nix develop --command bats tests/command/check.bats tests/command/catalogue_cli.bats
nix develop --command bats --recursive tests/
docmeta-check docs && docmeta-tracker --check docs
```

`catalogue.bats` adds a scenario per refusal in points 1 and 3, one for a
catalogue naming its own `specialists` directory, one for a specialist
reaching the base through another catalogue's specialist, and one for a
TOML specialist that reaches nothing.
