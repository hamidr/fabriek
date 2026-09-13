---
id: ADR-040
title: The declaration is built into the machine's image
status: implemented
date: 2026-09-12
status_date: 2026-09-13
summary: a generated machine flake pins the worked repository; roles, workflows and devShells resolve at build time
depends_on: [ADR-016, ADR-019, ADR-020, ADR-030]
supersedes: []
superseded_by: []
---

## Context

ADR-020 point 3 read the declaration from the commit at run time, one `nix
eval` per command. That was right when the factory ran in a shared VM and a
declaration could change under a running machine. ADR-019 gives each factory
a machine of its own, and a cage in ADR-037 has no nix daemon socket, so a
role can no longer run `nix develop`; its devShell has to be resolved before
the session starts.

## Decision

**1. Each factory gets a generated machine flake** under its own state
directory, whose input is the worked repository, with the rev pinned in that
factory's own `flake.lock`. `cageworks up` builds from the lock; updating a
role is a lock bump and a rebuild. Which declaration a run used is the
image's identity, and reproducing a run means checking out a lock.

**2. Validation moves to build time.** A bad declaration fails the build
rather than the first command that needs it. The schema, `modules/
schema.sh` and `modules/names.sh` keep their meaning; where they run
changes.

**3. Each role's devShell is resolved at build time** with `nix
print-dev-env` and handed to the session as environment, pre-built into the
store overlay.

**4. Adding or changing a role is a rebuild and a restart.** ADR-019's stale
state in `models/vm-lifecycle.qnt` is the normal path. What drains before
the restart is the tasks in flight, each retried after; roles are permanent
on the pool and lose nothing.

**5. ADR-020 points 3 and 3a are withdrawn.** The operator's caps file and
the register stand. ADR-032's clone from origin stands; its `git remote
get-url origin` off the operator's checkout does not, because the flake
input names the remote.

## Consequences

`cageworks up` has to be idempotent for everything it creates on the
machine, because it will be run after every rebuild. A factory cannot change
its roles without a restart, which is the price of the image being the
identity. `modules/repo-declaration.sh`'s run-time reader is deleted with the
`nix eval` it wrapped.

## Verification

Machine scenarios (docs/roadmap.md 2.1): a declaration with an unknown key
fails `cageworks up` at the build with the key named; a role naming a
devShell the flake lacks fails the build; a session started for a role has
that devShell's environment without running `nix develop`.

Implemented 2026-09-13: `tests/command/factory_flake.bats` fails the build
by the unknown key's name and by the role naming a devShell the flake
lacks, and `tests/command/seam.bats` hands the session its role's profile
on `NIXCAGE_PATH_PREFIX` with no `nix develop` run (docs/roadmap.md 2.1).
