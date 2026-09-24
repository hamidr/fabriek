---
id: ADR-045
title: nixcage answers for a running cage, bounds it, names its veth, and puts a hand inside it
status: implemented
date: 2026-09-14
status_date: 2026-09-15
summary: four primitives move upstream: leader and stop from the scope, memory and cpu bounds, the veth's name, exec into a cage
depends_on: [ADR-018, ADR-037, ADR-038, ADR-043]
supersedes: []
superseded_by: []
---

## Context

Four things fabriek did around nixcage rather than through it, each found
by reading what a session and the machine actually do.

A hand entering a role whose actor runs had to find the actor's cage:
`modules/machine-plan.sh` searched the process table for nspawn's own
argv (`--machine=<role>`) and took its child. That is nixcage's state read
through the back, which ADR-018 exists to forbid, and it left `role stop`
with no way to end a session that had stopped answering the bus.

A cage was bounded by nothing but the machine. ADR-043 put language servers
in cages and noted that one JVM could take the rest of the cages' memory;
nothing here could say otherwise, because a session's limits were not a
thing `enter` took.

A role's name was bounded at twelve characters, one interface deep from
the reason: nspawn named the cage's veth after it within the kernel's
fifteen, and the bridge's rules keyed on a prefix nixcage never wrote
down.

The probes attributed by uid (ADR-038), through a table asked of nixcage
per role, and a process that changed uid inside a cage stepped out of its
role's ledger.

nixcage ADR-012 and ADR-013 answer all four, as two commits in two
repositories and a lock bump (ADR-018): every cage already runs in the
scope nspawn allocates; nixcage now answers `status`, `netns`, `stop`,
`exec` and `veth` from it, takes `--memory` and `--cpus` on `enter`, makes
the veth itself with a host end named from a hash, and exports that name
as `lib.vethHostName`.

## Decision

**1. A running cage is asked of nixcage.** `fabriek_cage_running` asks
`nixcage-container status`; the `pgrep` over nspawn's argv is gone.

**2. A hand beside a running actor is put inside its cage.** `role-enter`
by hand, when the role's cage runs, is `nixcage-container exec <role>
[-- cmd]`: the actor's mounts, processes and home, the command asked for
or the cage's shell. No agent socket reaches a hand there; a hand inside a
running actor reads and does not sign. The second cage that joined the
actor's network namespace, and the `<role>-hand` name it carried, are
gone.

**3. `role stop --now` ends the cage at its scope.** The plain `stop`
still goes through the executor and keeps the task with the role; `--now`
is for a turn that no longer answers, and is `nixcage-container stop`.

**4. A supervised session is bounded from the declaration.** `--memory`
and `--cpus` on the actor line: the declaration's `memory` and `cores`
divided by its `concurrency`, never below one cpu, nothing when nothing
is declared. A hand's own cage stays bounded by the machine. The memory
bound is RAM: nixcage sets `MemoryMax=` on an nspawn cage's scope and
leaves swap unbounded, so a cage past its share swaps rather than being
killed (nixcage ADR-012, decided 2026-09-24); a microVM's is the guest's
memory and holds hard.

**5. The bridge's rules key on nixcage's name for the veth.** `bridge.nix`
takes `nixcage.lib.vethHostName` through the module arguments and writes
the members set and the `nc-*` rules from it; `vb-` is gone. The
scenario asks the locked nixcage for the same name it asserts.

**6. The probes attribute by cgroup.** bpftrace prints the cgroup id on
every line; `probes.sh` asks `nixcage-container status` per role, takes
the scope's cgroup path from the answer, and maps its inode to the role.
The entry carries `cgroup` and `role`; the uid is in the line. A process
that changed uid inside a cage is still that cage's.

**7. A role name is a machine name.** `FABRIEK_ROLE_NAME_MAX` is
sixty-four in `names.sh` and `names.ts`; the twelve-character rule and its
scenarios are gone.

**8. `seam.bats` stubs the primitives it now uses.** `status` and `netns`
answer from a per-scenario table of running cages; `exec` and `stop` are
recorded with `enter`. The actor line gains `--memory 4096M --cpus 2`
from the fixture's resources.

## Consequences

fabriek reads nothing of nixcage's but its answers. The primitives table
in CLAUDE.md grows by five verbs and two options and the sentence about
reaching around them no longer names a place where it happened.

A hand inside a running actor cannot sign, where the hand beside it could
through its forwarded agent. That was never a good place to commit from:
the actor's branch is the actor's. A person who wants to commit as the
role enters it while the actor is not running, as before.

The bounds are a policy, and a blunt one: every cage of a factory gets the
same share, whatever it runs. A role that needs more than its share, a
JVM build beside three idle reviewers, is throttled until the declaration
says a smaller concurrency. Per-role sizing would be a declaration field;
not taken here.

Cgroup attribution makes the uid table go, and with it one primitive call
per role per refresh becomes one `status` per role per refresh. A cage
not running has no scope, so its lines cannot appear; a line from a
cgroup nobody owns is the machine's own and published with an empty
role, as an unowned uid was.

Names longer than twelve characters reach every place a role name goes:
a bus user, a forge account, a home directory, a branch prefix. None of
those had the bound; the veth had it. The contract test over
`enter --print-argv` (nixcage ADR-012) needs the real `nixcage-container`,
which runs as root on Linux, so it is a machine step and not a scenario
here.

## Verification

```bash
nix flake lock --update-input nixcage
nix develop --command bats tests/command/seam.bats tests/command/operator.bats tests/command/probes.bats
nix develop --command bats tests/unit/machine_plan.bats tests/unit/repo_declaration.bats
nix develop --command bats tests/command/machine_services.bats
nix build .#factory
nix develop --command bats --recursive tests/
```

On a machine, `tests/manual/specialist.sh` gains: `fabriek role` while the
actor runs lands inside its cage (`cat /proc/1/cgroup` names the role's
scope); `nixcage-container enter --print-argv` for a role matches what
`seam.bats` asserts word for word; a role's `--memory` is visible as
`MemoryMax` on `machine-<role>.scope`; the probes stream's entries name
the role from the cgroup. Not run as of this document's date.

Implemented 2026-09-15 (commits 1428908 through 0b9c725): every point
is in the code and held by the suites above, 112 scenarios green on this
date, and `nix build .#factory` passes. The machine scenario is in
`tests/manual/specialist.sh` ("nixcage answers for the running cage"),
with `enter --print-argv` against `seam.bats` gated on the role's paths;
not run, roadmap 6.4. The record's status lagged the code by a day.
