---
id: ADR-070
title: A factory runs in a nixcage machine of its own, and every role is an nspawn cage inside it
status: proposed
date: 2026-09-25
status_date: 2026-09-25
summary: a nixcage machine per factory holds its clone, worktrees and nspawn roles; forge, bus, proxy, executor stay on host
depends_on: [ADR-010, ADR-017, ADR-034, ADR-037, ADR-038, ADR-045, ADR-067, ADR-068, ADR-069]
supersedes: []
superseded_by: []
---

## Context

ADR-067 made fabriek a program on a NixOS host and put the kernel boundary
per role: a role says `substrate = "microvm"` and gets a kernel, and every
other role shares the host's. Two factories' `nspawn` roles share the
operator's kernel with each other and with everything else the host runs.
ADR-067 gave up ADR-019's factory as the isolation unit on purpose.

The operator wants it back without ADR-019's cost: an escape from any role
must land in its factory's kernel, not on the host and not in another
factory, and the roles of one factory, which cooperate on one repository,
may share that kernel. A microVM per role buys more than that at seven
boots and seven reservations per factory, and still leaves the uncaged
parts of a factory's work (its clone, its worktrees, the git ACLs of
ADR-010) on the host.

nixcage ADR-026 proposes the primitive: a machine, a long-lived microVM that
is itself a nixcage host, reached by `--machine <name>` on the cage verbs and
on `nixcage exec`. This ADR is what fabriek does with it, and it waits on
ADR-026.

## Decision

**1. Every factory is a nixcage machine, and nothing of a factory's work is
on the host's disk.** `services.fabriek.factories.<name>` declares
`nixcage.machines.<name>`: memory and cores from the factory's resources,
clamped by the operator's caps as today; `diskSize` from the factory's
declaration; `uidSlice` the factory's position times a fixed width inside a
range `services.fabriek` declares; placement on `fb-<idx>` with every role's
address; the operator's checkout as a read-only share; and fabriek's guest
module in `modules`. The clone, the worktrees, the ACLs, the signing keys,
the transcripts and the role state live on the machine's disk.

**2. fabriek-container runs inside the machine for everything that touches
a role.** The guest module installs `fabriek-container` and the
nspawn-side profiles. `role-enter`, `role-worktree`, `role-stop`,
`role-transcript`, `factory-clone` and the per-role half of
`factory-prepare` run as `nixcage exec --machine <name> fabriek-container
...`, and inside the machine call `nixcage-container` locally, unchanged.
The host half keeps what touches the host's services: the forge owner and
role accounts (ADR-068), the bus account (ADR-069), the proxy's dictionary,
and handing the machine the credentials it needs over that exec's stdin,
never on its argv.

**3. The executor stays on the host.** ADR-034's uncaged executor is the
host's `fabriek-<name>` unit as today; its session command is the prefix
`nixcage exec --machine <name> fabriek-container`, which `sessions.ts`
already takes as a configured command. The factory's slice holds its state
unit, egress credentials and executor; the machine's unit holds the
factory's kernel.

**4. Every role is `nspawn`.** `[roles.<role>] substrate`,
`substrate.floor`, the clamp in `resources.sh`, `fabriek_cage_substrate`,
the `--substrate` word in `role-enter`, and the microVM branch of
`specialist.sh` are removed with their tests. A repository that declares
`substrate` is refused with a message naming this ADR's change, not
ignored.

**5. A role's disk bound is its factory's.** Inside a machine nixcage
refuses a quota (ADR-026 point 3), so `roleQuota` and the quota argument of
`fabriek_role_worktree_ensure` are removed, and the factory declares
`disk`, which is the machine's `diskSize`. ADR-017's dataset per role
worktree is given up; the factory's image is on a dataset of its own on
the host's pool.

**6. The network is unchanged as the forge, bus and proxy see it.** Each
role keeps its address on `fb-<idx>` through the guest bridge's uplink
(ADR-026 point 9), so the proxy's attribution by address (ADR-037), the
host's input chain, the forward chain and the bus ACLs read the same
packets. The host pins the machine's tap to the factory's addresses; the
guest pins each role's veth to its own.

**7. The kernel source of ADR-038 moves into the machine.** `probes.nix`
is imported into the guest through fabriek's guest module and runs as the
guest's root; it attributes by the uid the guest's nixcage allocated and
publishes to the host's bus with the factory's account, whose credential
only the guest's root can read. The host's bpftrace reader is removed: a
host sees a machine as one qemu.

**8. The operator fetches from the forge, not the clone.** The clone is on
a disk the host does not read (ADR-026 point 3), so ADR-067 point 5's
remote at the clone's path becomes a remote at the factory's repository on
the host's Forgejo, over the bridge address, with a read-only token `up`
makes and keeps in the factory's state for the `fabriek` group. The
refspecs are unchanged. What reached the clone and not the forge,
`refs/fabriek/record` and each role's branch between stage moves, is
pushed to the forge by `mirror` and on every stage move. The checkout
remains untouched by anything but the operator and this fetch.

## Consequences

A factory costs a boot at `up` and a memory reservation, where ADR-067's
cost was its units. A factory's panic or OOM ends its roles and nothing
else. Two factories share no kernel, and neither shares the operator's.

The roles of one factory share a kernel and a disk. A role that must not
share its factory's kernel is not expressible; a separate factory is.

The host still runs Forgejo, NATS, nginx and the executors, and every
machine reaches them. A compromised machine is contained by the host's
input chain to three ports and by the factory's own forge and bus
accounts, as a compromised cage is today.

`fabriek up` gains `machine up` before rendering and preparing, and `down`
gains `machine down` after the executor stops. The Formal Modeling Gate
fires on the lifecycle ADR-067 modelled: `models/factory-lifecycle.qnt`
gains the machine's states (booting, ready, failed) between started and
cloned, a machine that stops answering at any step, and a seventh
invariant: no role is entered in a machine that is not ready. It runs before
the implementation, with the mutant that enters before ready shown to
violate it.

ADR-067 points 4 and 5 and its "the factory as the isolation unit is given
up" are amended by this ADR once it is implemented; ADR-017, ADR-037,
ADR-038 and ADR-045 are amended as stated in points 5, 6, 7 and 4. Nothing
is superseded whole.

## Measurement plan

On `pc`, after nixcage ADR-026 is released and pinned, transcripts under
`/tmp/fabriek-proof/`:

- `two-factories.sh`: both factories' machines up (`nixcage-container
  machine status example` and `widgets`), each role's `uname -r` differs
  from the host's, the two machines' boot ids differ, `fabriek down
  example` leaves `widgets`'s machine and executor running.
- `isolation.sh`: every check it makes today, from inside a machine; plus
  a role's address pinned at the host tap and at the guest veth.
- `forge-boundary.sh` and `bus-account.sh`: unchanged and passing.
- `parity.sh` on a factory with a `ship` workflow: the checkout's
  `fabriek/<name>/<role>` and `refs/fabriek/<name>/record` arrive by the
  forge remote, and the checked-out branch and tree are untouched.
- The cost: `nixcage-container machine up example` timed, and
  `MemoryCurrent` of the machine's unit plus `fabriek-example.slice` idle,
  against ADR-067's 433 MiB.
