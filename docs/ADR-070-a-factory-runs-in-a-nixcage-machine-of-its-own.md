---
id: ADR-070
title: A factory runs in a nixcage machine of its own, and every role is an nspawn cage inside it
status: implemented
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

**9. Amended before implementation (2026-09-25), from reading the code
against nixcage 5.2.0.** Four things the points above had wrong or left
open:

- *The enter is the host's.* A machine's guest has the store without its
  database and cannot compute a cage's closure (nixcage ADR-026 decision
  6); only `nixcage-container enter --machine` on the host can. So
  `role-enter` is split: the host's `fabriek-container role-enter` runs
  the guest's with `--plan` through `nixcage exec --machine`, which
  prepares the role where its state is (worktree, key, pi directory) and
  prints the nixcage words it would have run, NUL-separated; the host
  refuses a plan whose verb is not `enter` or `exec` or that names
  `--auth-sock`, adds its own `--auth-sock` when a person entering gave
  one, and runs `nixcage-container <verb> --machine <name> ...`. What the
  guest can put in a plan is interpreted in the guest, but for store roots,
  which are read-only paths it already sees.
- *A machine's size is the host's.* A factory's resources are read from its
  repository at `up`, after evaluation, and a machine is evaluated.
  `services.fabriek.factories.<name>.machine` declares `memory`, `cpus`
  and `disk`, with defaults; `machine-spec.sh` still bounds each role's
  cage inside it by the declaration.
- *Credentials are minted on the host and shared, read-only.* The host
  keeps `bus/` and `forge/` under the factory's state path on its own
  filesystem as today, owned by the uid the machine's nixcage allocated
  for each cage (`uid --machine`), and shares both read-only at the same
  path; the guest's disk holds everything else under that path: the
  clone, worktrees, homes, keys, filed tasks and transcripts. `egress/`
  stays on the host and is shared with nothing. `FABRIEK_ETC` is shared
  read-only whole: it holds the declaration, the plan and the rendered
  pi directories, and no secret beyond the bus's password hashes.
- *The guest's nixcage allocates from its own range*, set by fabriek's
  guest module, and the host's `principalUidRange` is not consulted for a
  factory's cages.

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

Run 2026-09-25, before any code: `models/factory-lifecycle.qnt` gains
`machine` (off, booting, ready, failed), `machineUp`, `machineReady` and
`machineFails` (a failure ends every session and is bounded at two a
trace), clone, prepare and sessions wait for ready, and stop and a host
death leave the machine off. Two invariants are added, the seventh and
`stoppedMeansMachineOff`. `quint run --invariant=allInvariants
--max-steps=60 --max-samples=100000` finds no violation under `step`,
`witnessStep` or `recoveryStep`; the mutant whose `startSession` does not
wait for ready violates `noSessionInAMachineNotReady` within 100000
traces. Every witness is reached, a failure under a write and a recovery
from one among them, but three only under the narrower steps: the random
walk of `step` spends `maxPinGen` and the machine's failures before the
factory is running, and `neverCurrentAgainAfterStale` went unreached in
four million traces of it, as it needed 300000 of the model ADR-067
committed, whose "every witness reached in 10000" it contradicts.
`witnessStep` and `recoveryStep` are subsets of `step` that move the pin
and fail the machine only once running, so what they reach, `step`
reaches.

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

## Verification

Implemented 2026-09-25 from the model (`907f3a2`) to the manual proofs'
adaptation, on nixcage 5.2.1. `bats --recursive tests/`: 493 of 493;
`factory/`: 224 of 224, in the dev shell and in the package's own build;
`nix flake check` passes.

The measurement plan ran on `pc` on 2026-09-25, with `example` and
`widgets` each in a machine (`example` 12 GiB and six cores, `widgets`
6 GiB and two), transcripts under `/tmp/fabriek-proof/*-070.txt`:

- `two-factories.sh`: 16 ok. Both machines ready and two kernels, neither
  the host's; a role of `example` reaches its own bus and not `widgets`'s;
  `down example` leaves `example`'s machine off and `widgets`'s ready.
  Idle, `machine-example.scope` holds 2.57 GB and `fabriek-example.slice`
  179 MB, against ADR-067's 433 MiB for the slice alone.
- `isolation.sh` on `widgets`: 30 ok, nothing gated. Every role on the
  machine's kernel and none on the host's, the forged source dropped by the
  guest's pin, spend attributed by address through the hop, the ceiling at
  the proxy and the decider held at it.
- `forge-boundary.sh`: 22 ok; `bus-account.sh`: 16 ok; `host-autostart.sh`:
  9 ok; `specialist.sh` on `backend-1`: 27 ok.

Running a factory in a machine found faults the tests had not, each fixed
with a test that failed first:

- in fabriek: every role's first session cloned at once into a fresh
  machine and all but one failed (the clone is made under a lock); a
  switch either cycled every factory or left sessions on a render of the
  old floor (the factory's unit reloads, which is up, and the executor is
  not restarted by a switch); the executor died on SIGTERM before its
  sessions had stopped their cages (it now ends every session and waits);
  a supervised session found its role's cage left running by an executor
  before it (it stops it first); the executor's git test needed git and
  /bin/sh in the package's build.
- in nixcage, released as 5.2.1 and recorded in its ADR-026: a connection
  per forward, a session outliving its caller, a quota ignored inside a
  machine, a machine restarted by a switch, a uid lock outliving its
  holder, and an enter under a running cage's name deleting its port.

Not done: `parity.sh`, which wants a factory with a `ship` workflow run by
real models; and an operator's shell that joined the `fabriek` group
before its session started reads the fetch token only after a new login
(`sg fabriek` works meanwhile).

