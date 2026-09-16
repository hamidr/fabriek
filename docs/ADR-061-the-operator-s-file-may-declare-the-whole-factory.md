---
id: ADR-061
title: The operator's file may declare the whole factory, specialists and skills included, and a factory declared twice is refused
status: proposed
date: 2026-09-16
status_date: 2026-09-16
summary: the operator file carries roles, workflows, specialists and skills; one declaration per factory, never in both places
depends_on: [ADR-020, ADR-042, ADR-048, ADR-057, ADR-058]
supersedes: [ADR-060]
superseded_by: []
---

## Context

An operator has one file, `config.toml`, or its rendering from
`services.fabriek` (ADR-048): what a factory may cost here, the
credentials, the models, and which checkouts are factories. What a
factory is, its roles, its workflow, its resources, its policy, is
`fabriek.toml` in the repository it works (ADR-020, ADR-058); who a role
is comes from fabriek's catalogue and the repository's own (ADR-042).

The operator wants the whole of it in the one file they keep: the flow,
the roles, the specialists, their skills, and the same as Nix options
for a host kept in a Nix configuration. Two reasons. A person running
factories on several repositories they do not own, or do not want to
commit a `fabriek.toml` into, has no place to declare the team today.
And specialists and skills of their own reach a role only by being
copied into each repository's catalogue.

ADR-020 put the declaration in the repository so that the team travels
with the code and a second clone gets the same factory. That reason
stands for the repositories where it applies; it does not require that
the repository be the only place. ADR-060 proposed the catalogue half of
this on its own; this record takes both halves and supersedes it.

## Decision

**1. The operator's file carries a full declaration per factory, under
`[factories.<name>]`, in `fabriek.toml`'s own words.** Beside `path`, a
factory may carry `roles`, `workflows`, `resources`, `decider` and
`catalogue`, with the schema `modules/schema.sh` already checks, key for
key: `[factories.knot.roles.backend]`, `[[factories.knot.workflows.ship.stages]]`,
`[factories.knot.resources]`. `decider.policy` and `catalogue` are still
paths inside the repository, read at the commit. `services.fabriek.factories.<name>`
gains the same as options, rendered into the file with nothing the file
cannot say. One schema, one reader (`modules/operator-config.sh` for the
file, `modules/repo-declaration.sh` for the repository's), one clamp.

**2. A factory is declared once.** At `up`, and at `check`, the
repository at the pin is read for `fabriek.toml`. A factory whose entry
in the operator's file carries a declaration (any of `roles`,
`workflows`, `resources`, `decider`, `catalogue`) while the repository
carries `fabriek.toml` is refused, naming both places, before anything
is written or booted. A factory with neither is refused as it is today.
No merge, no precedence, no override: the person who wants the
operator's declaration to win deletes the repository's, and the reverse.

**3. The operator's file carries specialists and skills.**
`[specialists.<name>]` with `extends`, `tools`, `skills`, `prompt`,
`lsp`; `[skills.<name>]` with `tools` and `skill`. `prompt` and `skill`
are a path to a file (a Markdown prompt, a `SKILL.md`) or the text
itself. `tools` and `lsp` are nixpkgs attribute names, resolved against
the machine's nixpkgs at render, which is what a catalogue's
`default.nix` does with `pkgs`. The keys are ADR-042's schema, spelled in
TOML; the reader refuses any other by name. `services.fabriek.specialists`
and `.skills` are the same as options, a `prompt` or `skill` given as a
path becoming a store path in the file.

**4. What is not a nixpkgs attribute is a catalogue directory.** A tool
built from a derivation of the operator's own, a specialist that needs
more than the schema says, keeps ADR-042's form: `catalogues = [
"<dir>" ]`, a list of directories with the catalogue layout, in the file
and as `services.fabriek.catalogues`. ADR-060's route stands: `up` adds
each to the host's store and roots it, the store paths travel to the
machine, render composes them.

**5. The operator's specialists compose beside fabriek's and the
repository's, each name once.** fabriek's shipped catalogue, the
operator's TOML specialists and skills, the operator's catalogue
directories, the repository's catalogue: a name declared in any two is
refused by name, never shadowed (ADR-042 point 3). An operator's
specialist may `extends` a shipped one; a repository's may extend an
operator's, which then binds that repository to this host, and
`fabriek check` says so where the name is missing.

**6. Everything of the factory reaches the machine as ADR-057 has it.**
The declaration goes in the machine's `fabriek.toml` credential beside
`[caps]`, where the render's clamp reads it instead of the clone's file;
prompts, skills and catalogue directories go through the lower store,
added and rooted by `up` before the boot. Render evaluates the operator's
specialists into the same `compose` the catalogues use, from the
credential's tables, and grants the paths to the evaluator on the search
path (ADR-057 point 6). The appliance is unchanged: one image for every
host (ADR-057 point 1), and a change to any of this is `down` and `up`.

**7. `check`, `ls` and `show` read the operator's file too.** `fabriek
check <factory>` resolves the declaration from wherever it is, refuses
the double one, and resolves every specialist the roles name across the
four sources; `ls` lists the operator's specialists and skills with the
shipped ones; `show <specialist>` says which source it came from.

## Consequences

An operator can run a factory on a repository that says nothing about
factories, and keep the team, the flow and the people on their own
machine, in one file or one Nix module. A repository that declares its
own keeps ADR-020's promise; the two do not mix, and the refusal names
both files so a person sees the choice.

A declaration in the operator's file is a factory that exists on one
host. That is the trade ADR-020 named, now the operator's to make per
factory rather than fabriek's to make for everyone. `fabriek check`
carries the same refusals for both.

The credential grows by the declaration and by a list of store paths.
Nothing a cage sees widens: a cage sees its profile's closure (nixcage
ADR-014), and the profile carries the specialists' tools. A prompt in the
operator's file is a prompt on the operator's own machine.

`modules/schema.sh` is shared by both readers today and stays one.
`modules/operator-config.sh` grows the three tables and the refusals;
`modules/catalogue.nix` takes TOML-declared specialists as a fourth
source, the same attrset shape it builds from a directory. ADR-058's
reader (`git show <rev>:fabriek.toml`) stands for the repository's file;
ADR-020 points 1 and 3a are amended to "in the repository or in the
operator's file, read at the commit or at `up`, never both"; ADR-060 is
superseded whole. `seam.bats` is untouched.

## Verification

```bash
nix develop --command bats tests/unit/operator_config.bats tests/unit/schema.bats \
  tests/command/vm_up.bats tests/command/render.bats tests/command/check.bats \
  tests/command/catalogue.bats tests/command/host_module.bats
docmeta-check docs && docmeta-tracker --check docs
```

Scenarios, written first: the operator's file declaring a factory whole
and `up` writing it into the credential; a factory declared in both
places refused at `check` and at `up` naming both; a TOML specialist
composed with a shipped parent and its tool on a role's PATH
(`catalogue.bats`, built for real); a TOML specialist named like a shipped
one refused; `services.fabriek` rendering roles, stages, a specialist and
a prompt path as the file would have them, with the option set diffed
against the schema's keys so the two cannot drift. On a machine:
`tests/manual/specialist.sh` against a factory declared in the operator's
file with one specialist of its own, the cage answering for its tool and
its heading in `APPEND_SYSTEM.md`. Recorded here when run.
