---
id: ADR-019
title: cageworks builds and runs one NixOS VM per factory, on every platform
status: accepted
date: 2026-09-06
status_date: 2026-09-06
summary: cageworks owns a per-factory microVM on Linux and macOS alike, with nixcage caging roles inside it
depends_on: [ADR-010, ADR-011, ADR-017]
supersedes: [ADR-018]
superseded_by: []
---

## Context

ADR-018 split the factory out of nixcage and left the VM behind, on nixcage's
side of the line. nixcage runs a shared VM on macOS because macOS has no
containers, and runs no VM at all on Linux, where ADR-003 deleted it as a tax
with nothing to buy. Three things follow, and they were not examined when that
line was drawn.

The isolation a factory gets depends on which machine it is running on. On
macOS a role sits behind a hypervisor. On Linux the same role is an nspawn cage
on the operator's own kernel, so a kernel escape reaches the machine the
operator reads mail on. A factory runs coding agents unattended, for hours, on
work no person is watching. The boundary that matters there is the one toward
the operator's machine, and today it is the weaker of the two on the platform
where the factory is cheapest to run.

Factories are not isolated from each other at all. Two factories on one Linux
host share a kernel, a store and a uid space; on macOS they share one VM. A
factory is the unit a person reasons about, funds and throws away, and it is
not the unit of isolation.

Starting a factory rebuilds the operator's machine. On macOS that means editing
nixcage's VM flake; on Linux it means putting `cageworks.factories.*` into the
NixOS configuration of the computer being used for everything else, and running
`nixos-rebuild` to add a role. The declaration of a team of agents has been made
a property of the operator's workstation.

The VM itself is not the missing piece. ADR-001 and ADR-002 built it and it has
worked since. It is owned by the wrong project and used on only one platform.

## Decision

**1. cageworks builds and runs one NixOS VM per factory, on Linux and macOS
alike.** microvm.nix becomes cageworks' own flake input rather than something
reached through nixcage. A factory exists when its VM exists; `cageworks up`
builds and boots it, `cageworks down` stops it.

**2. The guest is an ordinary Linux host running cages.** Its configuration is
nixpkgs, the microvm module, `nixcage.nixosModules.host` and cageworks' own
guest module. Inside the VM, nixcage is in exactly the situation ADR-003 built
for it: a Linux machine running nspawn cages natively. That path is now the
only one cageworks uses, on both platforms.

**3. Each factory VM has its own disk, with ZFS on it.** ADR-017 survives
unchanged: `/var/lib/nixcage` is a dataset on that pool, each role worktree is a
dataset with a quota, `acltype=posixacl` and `xattr=sa` are set because ADR-010
needs them. What changes is who declares the pool. It is a fact about a machine,
and cageworks now builds the machine, so cageworks' guest module attaches the
volume and creates or imports the pool, then points `nixcage.storage.dataset` at
it. Handing out uids and making a dataset per worktree stay nixcage's, through
the primitives of point 5.

**4. cageworks owns the transport, because it owns the VM.** A keypair and a
forwarded port per factory, generated at `cageworks up`, which is the mechanism
nixcage's macOS path has proven. `nixcage exec` is dropped: it existed only so
that cageworks could reach a VM it had not created, and that reason is gone.

**5. The seam with nixcage becomes one NixOS module and three argv
primitives.** `nixcage.nixosModules.host` in the guest configuration, and inside
the guest `nixcage-container enter`, `nixcage-container uid` and
`nixcage-container storage ensure`, called exactly as they are called today. The
argv a role session produces does not change, and `tests/command/seam.bats`
keeps asserting the whole line.

**6. What ADR-018 decided and this document keeps.** cageworks stays a separate
project that pins nixcage from its own remote, not a path input and not a
vendored copy. The line between them is still a person entering one project by
hand: isolation, uid mapping, binds, environment selection, git worktree
resolution and secrets are nixcage's, and roles, capabilities, tasks, workflows,
stage policies, the record, integration and the supervisor are cageworks'.
cageworks still writes no nspawn arguments, allocates no uid and asks for
storage rather than making it. When it needs something these cannot express, the
interface changes in nixcage first.

**7. What a VM costs is stated by the factory and capped by the operator.**
Memory, cores and disk are declared where the rest of the factory is declared,
and clamped to a ceiling the operator owns. ADR-020 settles where both live.

## Consequences

Linux pays the tax ADR-003 shed: a second Nix store, a boot, and a memory
reservation. That ADR weighed the tax against isolating one person's projects
from each other, where the host was already trusted by everything running on it.
A factory is the case it did not weigh, and the answer comes out differently
when the thing inside the boundary is an unattended agent. ADR-003 is not
reversed upstream; nixcage keeps its native Linux path for the single-project
case, and cageworks stops using it.

Two factories can no longer share a store. Identical closures are built or
fetched twice, and disk on the host grows per factory rather than per role.

Requirements harden. KVM on Linux and Hypervisor.framework on macOS were needed
before only on one platform each; now both are needed wherever a factory runs.
The Linux builder macOS already needed to build `aarch64-linux` derivations is
unchanged.

`nixcage exec` loses its only consumer. It was exported by ADR-018 for cageworks
alone, so nixcage may retire it; that is a decision in that repository, and
nothing here breaks if it stays.

The Formal Modeling Gate fires, on the VM's lifecycle. Absent, built, booting,
running, stale (the declaration changed under a running VM) and stopping is more
than three states, and the host and the guest interleave across it: a boot can
fail after the disk is created, a stop can race a session, a rebuild can land
while roles hold worktrees. `models/vm-lifecycle.qnt` is written and run before
the implementation.

Five invariants hold there, with no violation found over 30000 traces of up to
60 steps each: a session exists only inside a machine that is up, nothing is
ever up without the disk its state lives on, a resize only reaches a machine
that is not running, the disk outlives every transition but the one that exists
to remove it, and a running machine runs the image it booted with. Two
witnesses violate, which is what they are for: the declaration can drift ahead
of the machine running it, and a machine can still be ended mid-write by the
host dying, which is the residual risk ADR-017 puts the pool underneath.

The model has no action that forces a stop. That is the design rather than an
omission: a stop that cannot complete returns the machine to running and is
reported. Allowing a rebuild to reach a running machine turns two of the five
invariants red, which is how the guard was checked rather than assumed.

It does not fire on `models/factory-structure.als`. That model already describes
a single factory in isolation, and per-factory VMs make factories disjoint
rather than changing what a role owns, which ref it may write, or who takes a
task. The model is unchanged, deliberately.

## Verification

```bash
nix develop --command shellcheck -x cageworks cageworks-container modules/*.sh
nix develop --command bats --recursive tests/
docmeta-check docs && docmeta-tracker --check docs
alloy6 exec models/factory-structure.als
quint run models/factory-lifecycle.qnt --invariant=allInvariants --max-steps=60
quint run models/vm-lifecycle.qnt --invariant=allInvariants --max-steps=60
```

The claim that a role session is unchanged is the same gate ADR-018 set:
`tests/command/seam.bats` stubs `nixcage-container` on `PATH` and asserts the
recorded argv, flag for flag, against what is produced today.

The tax this document accepts is measured rather than asserted, once on each
platform, and recorded in the PRD that implements it:

```bash
time cageworks up examples/factory-project          # cold: build and boot
time cageworks up examples/factory-project          # warm: boot only
time cageworks role acme architect -- true          # boot to first session
du -sh ~/.local/share/cageworks/acme/disk.img       # per-factory disk
```
