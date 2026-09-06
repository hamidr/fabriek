---
id: ADR-020
title: A factory declares itself in the repository it works
status: proposed
date: 2026-09-06
status_date: 2026-09-06
summary: roles and workflows move into the worked repository's flake output; the operator keeps only caps and a register
depends_on: [ADR-015, ADR-016, ADR-019]
supersedes: []
superseded_by: []
---

## Context

A factory is declared today in the NixOS configuration of the machine it runs
on, as `cageworks.factories.<name>`, rendered to `/etc/cageworks/factories` by a
module. That placement was inherited rather than chosen: the factory grew inside
nixcage, nixcage had a module, so the factory got options in it.

Half of a role's definition already lives somewhere else. ADR-016 has a role
name a devShell of the assigned repository's own flake, so `shell =
"backend-jvm"` is in the operator's configuration and `devShells.backend-jvm` is
in the repository. The two are versioned separately, change separately, and
nothing notices when one moves without the other. Renaming a devShell breaks a
role in a file the person renaming it never opens.

It does not travel either. A factory is a description of how a repository is
worked: which specialists it needs, what they can take on, what finishing a
stage means there. Handing that to a second person means handing them a fragment
of a NixOS configuration to splice into their own machine.

And it makes changing a role a machine rebuild. ADR-019 takes `nixos-rebuild`
out of the operator's path for the VM. Leaving the declaration in NixOS puts it
straight back, for the edits that happen most often.

## Decision

**1. A factory declares itself in the repository it works,** as the `cageworks`
output of that repository's own flake:

```nix
cageworks = {
  name = "acme";
  roles.backend = {
    command = [ "claude" ];
    provides = [ "build" ];
    shell = "backend-jvm";
  };
  workflows.ship = {
    stages = [ { needs = "build"; ready = [ "acceptance" ]; done = "tests pass"; } ];
    budget.runs = 200;
    consults.backend = [ "architect" ];
  };
  resources = { memory = "8G"; cores = 4; roleQuota = "20G"; concurrency = 3; };
};
```

The `repository` field disappears. The repository doing the declaring is the
repository being worked, and there is nothing left for it to point at.

**2. The schema is closed and carries no NixOS.** It is read with `nix eval
--json --no-allow-import-from-derivation`, then validated field by field;
anything outside the schema is refused rather than merged. A repository cannot
add a package, a service, a bind or a kernel option to the VM it is given. The
one arbitrary thing it can reach is the devShell a role enters, which runs
inside that role's cage and is exactly what ADR-016 already grants it.

**3. The declaration is read at run time, not built into the image.** Adding a
role, changing a stage's `done`, or granting a consult costs nothing but a
commit. Only `resources` moves the VM, because only `resources` describes the
machine.

**3a. It is read from the commit, never from the working tree.** The read is
`nix eval --json git+file://<path>?rev=<sha>#cageworks`, with the rev resolved
from the repository's `HEAD`. The bare `git+file://` form was tested and does
not do this: on a dirty tree it evaluates the working tree and prints a warning,
which is the opposite of what is wanted here. Pinning the rev means the factory
a repository declares is the one in its history, and it means the rev that was
read is a fact cageworks can record beside the work, so which declaration a run
used is reconstructable afterwards. The cost is that an experiment needs a
commit, which is the same cost every other fact about the repository already
carries.

**4. The operator keeps one plain file,** `~/.config/cageworks/config.toml`,
identical on Linux and macOS: the ceilings this machine will allow, and the
register of which factories live here.

```toml
[caps]
memory = "16G"
cores = 8
roleQuota = "50G"
concurrency = 4

[factories.acme]
path = "/home/me/Src/acme"
```

There is no NixOS module for an operator to import, no flake to scaffold and no
rebuild to run. `nix run github:hamidr/cageworks -- up` is first contact.

**5. The repository states its needs and the operator caps them.** Each field of
`resources` is clamped to the matching cap, and cageworks says which value it
clamped and to what, rather than silently sizing down. A repository decides who
works it; the person whose hardware it is decides what that may cost.

**6. The old placement is deleted, not deprecated.** `modules/cageworks.nix`,
the `cageworks.factories.*` and `cageworks.supervisor.*` option namespace, the
rendering of `/etc/cageworks/factories` and `examples/config/flake.nix` go in the
same change. No alias, no compatibility read of `/etc`, no fallback when the
flake output is absent: a repository with no `cageworks` output is not a factory,
and saying so is the whole error message.

## Consequences

Reading the declaration evaluates the repository's Nix. The closed schema stops
a repository from writing VM configuration, and it does not stop code running
during evaluation; `--no-allow-import-from-derivation` bounds that, it does not
end it. This is accepted rather than solved, because a factory works a
repository whose devShells you were already going to enter and whose agents you
were already going to run. The trust required is the trust `nix develop` in that
directory already requires, and no factory should be pointed at a repository
that does not have it.

Every factory declared today is rewritten once, by hand, from NixOS options into
its repository's flake. There is no migration command, because point 6 leaves
nothing to migrate from.

A repository now carries the names of the roles that work it, and if the
repository is public, so are they.

Commands that need the declaration pay an evaluation. Nix's own eval cache
absorbs the repeat case. If it becomes the slow part, the fix is caching the
validated JSON against the flake's lock, not restoring a rendered directory.

`modules/factory-config.sh` is rewritten against the flake output and
`tests/unit/factory_config.bats` with it. The models are untouched: what a role
owns, which ref it may write and who takes a task are unchanged by where the
declaration is kept.

The Formal Modeling Gate does not fire. Config resolution is a listed shape, and
this is the degenerate case of it: each `resources` field is clamped by `min`
against one cap, no field constrains another, and there is no assignment to
search for. A model would restate the arithmetic. The schema itself is a data
format, which the gate exempts.

## Verification

```bash
nix develop --command shellcheck -x cageworks cageworks-container modules/*.sh
nix develop --command bats --recursive tests/
docmeta-check docs && docmeta-tracker --check docs
```

`examples/factory-project` gains the `cageworks` output it now needs, and is
what the suite reads: `tests/unit/repo_declaration.bats` asserts that a valid
declaration parses, that an unknown key is refused rather than ignored, that a
`resources` field over its cap is clamped and reported, and that a repository
with no `cageworks` output is rejected with the error of point 6.
