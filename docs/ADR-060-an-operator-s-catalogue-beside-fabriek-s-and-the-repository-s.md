---
id: ADR-060
title: An operator's catalogue reaches the machine as store paths beside fabriek's and the repository's
status: superseded
date: 2026-09-16
status_date: 2026-09-16
summary: operator catalogue directories reach the machine through the lower store; roles stay in the repository
depends_on: [ADR-020, ADR-042, ADR-048, ADR-057, ADR-058]
supersedes: []
superseded_by: [ADR-061]
---

## Context

ADR-042 gives a role its specialists from two catalogues: the one fabriek
ships in `catalogue/`, built into the appliance, and the one a repository
may carry at the path `fabriek.toml` names, read from the clone at render.
An operator who keeps their machine in a Nix configuration (ADR-048,
`services.fabriek`) has specialists and skills of their own, kept beside
that configuration and used across every repository they run a factory
on, and today the only way to give a role one is to copy it into each
repository's catalogue.

The roles themselves are a different matter. ADR-020 and ADR-058 put the
declaration in the worked repository so that the team travels with the
code and a second person cloning it gets the same factory; ADR-057
withdrew the one place a host ever baked a factory into an image. A
role declared in an operator's configuration would be a factory that
exists on one machine, which is what those records decided against.
This record does not reopen it.

What ADR-057 added is the route: the host's store is the machine's lower
store, and a path the host holds at boot is valid on the machine. ADR-046,
re-decided, uses it for the dependency cache. A catalogue is a directory
of Nix files and prompts, which is a store path on any host.

## Decision

**1. The operator names catalogue directories, in the same two places the
caps live.** `config.toml` gains a top-level `catalogues`, a list of
directories with ADR-042's layout; `services.fabriek` gains
`catalogues = [ ./catalogue ]`, a list of paths, rendered into the file
as the store paths Nix makes of them. Absent means none; the schema
refuses any other key as it does today (`modules/operator-config.sh`).

**2. `up` puts each catalogue in the host's store before the boot and
roots it.** A path that is not a store path is added with `nix store
add-path` (a directory of files: the same store path on every system), a
store path is used as it is, and each is rooted under the factory's
machine directory as the profiles are (ADR-057 point 5a). The store paths
travel to the machine in `fabriek.toml`, a `catalogues` list beside
`[caps]`; the lower store's snapshot is taken at boot (ADR-057), which is
why the add comes before the start.

**3. Render composes three catalogues.** `fabriek_profile_build` hands
`modules/profile.nix` the operator's paths beside the repository's, and
`modules/catalogue.nix` takes them all as `extra`: fabriek's first, the
operator's, the repository's. A name declared twice, in any two of the
three, is refused by name and never shadowed (ADR-042 point 3), so an
operator cannot redefine `developer` under a repository's feet and a
repository cannot redefine an operator's. The paths are granted to the
evaluator on the search path, as fabriek's own are (ADR-057 point 6): a
directory of files the host put there, not a URI to fetch.

**4. `check`, `ls` and `show` read them on the host.** `modules/check.sh`
evaluates against the same three catalogues, from the file, so an
operator sees a name clash before paying for a boot (ADR-057 point 9).

**5. The appliance is unchanged.** One image for every host (ADR-057
point 1) stays one: nothing of an operator's catalogue is evaluated into
it. A catalogue change is a `fabriek up` after `down`, as a change to the
caps is, and never a rebuild.

## Consequences

An operator's specialists and skills live once, in their configuration,
and every factory on that host may name them. A repository that names
one of them runs the same on a host that lacks it only if it carries the
specialist too, which the clash rule then refuses: a repository that
wants to be portable keeps its specialists in its own catalogue, and this
record does not change that trade. `fabriek check` says which.

The credential grows by a list of store paths; the machine reads
directories the host holds, which is what it does for every path of the
lower store. A path added by `up` is the operator's own file, on the
operator's own machine, and widens nothing a cage sees: a cage sees its
profile's closure and nothing else of the store (nixcage ADR-014), and the
profile carries the specialists' tools, not the catalogue.

`seam.bats` is untouched: the session line does not change. `vm_up.bats`
gains the add, the root and the credential's list; `render.bats` the
third catalogue on the build line and the clash refused; `catalogue.bats`
an operator catalogue composed for real; `host_module.bats` the option
rendered as store paths; `operator_config.bats` the key accepted and a
non-directory refused.

## Verification

```bash
nix develop --command bats tests/command/vm_up.bats tests/command/render.bats \
  tests/command/catalogue.bats tests/command/host_module.bats tests/command/operator_config.bats
docmeta-check docs && docmeta-tracker --check docs
```

On a machine: an operator catalogue with one specialist named by the
example's backend role, `fabriek up`, and `tests/manual/specialist.sh`'s
first scenario asking the cage for that specialist's tool and its heading
in `APPEND_SYSTEM.md`; then the same specialist copied into the
repository's catalogue and `fabriek check` refusing the name. Recorded
here when run.
