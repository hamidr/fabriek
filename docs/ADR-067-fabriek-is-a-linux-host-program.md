---
id: ADR-067
title: fabriek is a Linux-host program, a factory is a set of service instances on it, and a role's kernel boundary is nixcage's
status: implemented
date: 2026-09-21
status_date: 2026-09-22
summary: no machine per factory; factories declared on a NixOS host; enter --substrate per role; the operator fetches the clone
depends_on: [ADR-020, ADR-032, ADR-036, ADR-037, ADR-047, ADR-048, ADR-058]
supersedes: [ADR-019, ADR-057, ADR-063]
superseded_by: []
---

## Context

fabriek was designed while macOS was a host it had to run on. macOS runs no
cage natively and binds no host directory into one, so nixcage put every cage
inside one shared VM, and fabriek inherited the shape and then made it
universal: ADR-019 gave every factory a VM of its own on Linux too, justified
as a kernel boundary around unattended agents. Everything after it is a
consequence of the factory living on an island the operator cannot mount
into. ADR-032 clones origin because the checkout cannot be shared in. ADR-036
puts Forgejo in the guest and copies the record out with `mirror`. ADR-047
reaches every verb over ssh with argv NUL-framed, a keypair and a port per
factory. ADR-057 hands the factory in as `fw_cfg` credentials, shares the
host's store over 9p or virtiofs under an overlay on `store.img`, needs a
Linux builder on macOS, and carries `microvm-run`, `runtime.json` and
`models/vm-lifecycle.qnt`. Each factory pays a boot, a second store and a
memory reservation, and "one machine, one factory" let every name (`fabriek0`,
pool `fabriek`, `/var/lib/fabriek/factory/`) be a constant, so two factories
on one host were never possible.

The VM was never the point. The point was the boundary between a role and
the operator's machine, and macOS was the reason a VM was the only way to
get it. nixcage ADR-019 (implemented 2026-09-17, in the pin at `c2a5e78`)
changes that: `nixcage-container enter --substrate microvm` runs one cage in
a kernel of its own on a Linux host, behind the same primitives fabriek
already calls. The project is bound read-write over virtiofs, the store
read-only, there is no daemon inside, `status`, `stop` and `exec` are
unchanged, `--network BRIDGE:ADDR` still places the cage on a bridge, and
the substrate is fixed at the first `enter`. It is refused on macOS, since
the shared VM cannot nest another.

Two needs stated when this was decided: several factories on one host, and
the operator observing a factory's work in their own checkout, without a
forge login. macOS as a host is set aside; nothing here prevents the same
program running inside nixcage's macOS VM later, and nothing here designs
for it.

## Decision

**1. fabriek runs on a NixOS host and owns no machine.** The host carries
`nixcage.nixosModules.host` (with `microvm.enable` where any role wants a
kernel) and `services.fabriek`. `fabriek VERB` runs
`sudo fabriek-container VERB` with argv passed as argv, where ssh and
`xargs -0` ran it before; `services.fabriek` installs a sudoers rule for
that one program and the `fabriek` group, not for wheel. A person beside
the unit is a member of that group; ADR-063's operator keys have nothing to
open.

**2. A factory is declared on the host, and its services are NixOS
configuration.** `services.fabriek.factories.<name>` (ADR-048) now declares
the whole factory's presence: its checkout path, its `autoStart`, and from
those `modules/machine/*.nix` re-homed as host configuration with `<name>`
where a constant was. Adding a factory is a `nixos-rebuild`, which ADR-019's
context counted against; it is accepted here because the host is the
factory's machine now and a machine is built, and because it keeps
`board.nix`, `bus.nix`, `proxy.nix` and `bridge.nix` on the NixOS modules
they use. Per factory: a bridge `fb-<idx>` at `10.77.<idx>.0/24` from
`systemd.network`, `<idx>` the factory's position in the sorted declared
names; Forgejo as a template instance on the bridge address; Valkey as
`services.redis.servers.<name>`; the executor and the loops under
`fabriek-<name>.slice`. On the host once: one nginx with a server block per
bridge address and an njs dictionary and a ceiling per factory; one
bpftrace reader that publishes each event to the bus of the factory its uid
belongs to. Every service listens on a bridge and on no host port; the
operator reaches the board at the bridge address. `fabriek up` starts the
slice, clones, renders and prepares, under a flock on the state directory
held for its whole run, and `-u` moves the pin under that lock; `down`
stops the slice and keeps the datasets.

**3. Every constant becomes a function of the factory name.** The cage and
the uid principal are `<name>-<role>`; `fabriek_role_name_ok` checks the sum
against nixcage's sixty-four, and reserves `main` beside `decider` since a
role's branch lands under `fabriek/<name>/` next to it (point 5). The
current `fabriek-<name>` interface name capped a factory name at seven
characters and goes with `fb-<idx>`. Datasets are
`<pool>/fabriek/<name>/<role>` under `storage ensure`. The state directory
is `/var/lib/fabriek/<name>/` (`FABRIEK_ETC`), and what arrived as
credentials is written there by `up` from `config.toml`, root-only.

**4. A role's substrate is declared, clamped, and passed through the seam.**
`[roles.<role>] substrate = "nspawn" | "microvm"`, default `nspawn`. The
operator's `config.toml` gains `substrate.floor`, default `nspawn`, and
`machine-spec.sh` clamps upward, printing the change with the others: the
factory asks, the operator bounds, as with memory and cores. `role-enter`
emits `--substrate <s>` after `--no-nix-daemon` and nothing else in the line
changes; `--memory` stays fabriek's word, and for a microVM it is the guest's
reservation rather than a cgroup cap, which `resources` says. nixcage fixes
the substrate at the first `enter`, so a changed declaration is applied by
`up -u` as `nixcage-container rm <cage>` then enter; `rm` is the sixth
primitive, and it clears nixcage's record only, never the role's dataset,
home, key or forge account. nixcage's refusals (no `/dev/kvm`, vmspawn
below 261, `microvm.enable` unset) are printed by `up`; `check` stays
evaluation-only. `--disk` is not emitted until a role needs it.

**5. The operator's checkout is the factory's origin, and the operator is
its only writer.** `up` clones the checkout onto the factory's dataset as
git clones a local path: objects hardlinked, so a repack or prune on either
side unlinks a name and never the data, and nothing borrows through
alternates (`--shared` and `--reference` would, and would corrupt the clone
under a rebase and a `gc` on the operator's side). `factory-clone.sh` drops
`--no-hardlinks`, which existed because the source was a URL. `origin` is
the path; `fabriek.toml` and `[pin]` are read from the checkout as ADR-058
does, and `-u` fetches from the path. ADR-032 stands with one word changed.

Nothing in the factory writes the checkout. `up` adds to the checkout a
remote `fabriek-<name>` at the clone's path with the refspec
`+refs/heads/*:refs/heads/fabriek/<name>/*` and
`+refs/fabriek/*:refs/fabriek/<name>/*`, and `down` removes it. `fabriek
ps`, `watch`, `board` and `mirror` run `git fetch fabriek-<name>` as the
operator's own uid before they answer, and `fabriek fetch` does only that.
The clone's dataset is readable by the `fabriek` group so the fetch can
read it. Observation is `git branch` and `git log fabriek/<name>/<role>` in
the checkout, refreshed on every fabriek verb; a role's branch reaches the
clone on every stage move as it reaches the forge today, and merged `main`
and the record (`refs/fabriek/record`) reach the clone on `mirror`, so
ADR-036 point 7 keeps its promise in a narrower form: nothing leaves the
host until the operator pushes their own checkout, and its point 8
credential is gone. The checked-out branch and the working tree are never
touched by anything but the operator. A live view of a role's uncommitted
files is not part of this.

**6. What goes.** `modules/vm.nix`, `modules/appliance.nix`,
`modules/machine.sh`, `modules/credential.sh`, the keypair and port,
`runtime.json`, `store.img`, the overlay store, virtiofsd for the store,
`microvm-run`, the microvm.nix input, `fabriek console`, the Linux-builder
requirement, and their tests: `vm_up.bats`, `credential.bats`,
`machine_services.bats` (its assertions move to `host_module.bats`).
Permission to replace is permission to remove: no fallback to a machine
path is kept. `models/vm-lifecycle.qnt` is not removed but renamed
`factory-lifecycle.qnt` and adapted (Consequences).

## Consequences

Two factories on one host share the host's kernel for their services and,
for `nspawn` roles, for the roles too; ADR-019's factory as the isolation
unit is given up. The executor was uncaged by design. A role that must not
share the operator's kernel says `substrate = "microvm"` and gets a boundary
finer than ADR-019 gave: per role, not per factory.

ADR-037's "no route off the machine" becomes "no route off the host", and
the host is a machine with other rules on it: `ip_forward` set by docker or
libvirt, a VPN, a foreign nftables table. `bridge.nix`'s rules must hold
beside them and are measured on such a host, not assumed.

Memory per factory is a Forgejo and a Valkey idle instead of a booted guest
and a second store; the number is measured, not claimed. A microVM role
reserves its memory rather than sharing it, and pays nixcage's measured
seven seconds a session for `true`.

`services.fabriek` grows from a unit per factory into the whole of the
machine's configuration, and NixOS is the only host: nixcage's host module
and this one are both NixOS modules. The host's nix daemon builds profiles
under `--restrict-eval`, as the machine's did. Forgejo's NixOS module is
single-instance, so the board is a template unit of ours; nginx, Valkey
and bpftrace stay on their modules.

The Formal Modeling Gate fires as it did for ADR-019, on the same lifecycle
with the machine's states replaced: absent, declared (rebuilt in), started
(the slice is up), cloned, rendered, prepared, running, stale (the pin or
the declaration moved under a running factory), stopping. `up` interleaves
with `fabriek-<name>.service` at boot and with a manual `down`, and can
fail after the clone or after the units are up. `models/vm-lifecycle.qnt`
becomes `models/factory-lifecycle.qnt` with its five invariants kept and a
sixth, one `up` at a time, run before the implementation of point 2. Run
2026-09-21 with two callers (the unit and a hand): without the lock the
prepared mark is written for a pin one profile no longer carries, in 60
steps; with it, no violation in 10000 traces of 60 steps, and every
witness reached.

ADR-047 keeps its grammar and loses its transport section; ADR-048's unit
per factory is now the slice per factory; ADR-032, ADR-036 and ADR-064 are
amended as stated, not superseded. `docs/architecture.md`'s "The host" and
"The machine" become one section. `roadmap.md` 6.8 becomes the primary
proof and 6.9 closes with ADR-057. CLAUDE.md's primitive table gains `rm`
and `--substrate`.

## Measurement plan

Four claims, each on a NixOS host with `/dev/kvm`, in `tests/manual/`.

Two factories on one host, `two-factories.sh`: `a` and `b` declared in
`services.fabriek.factories` from two checkouts, `fabriek up a` and
`fabriek up b`; `systemctl list-units 'fabriek-*'` shows both slices; `ip
link` shows `fb-0` and `fb-1`; a role in `a` reaches `10.77.0.1:6379` and
not `10.77.1.1:6379` (the connect probe on the bus refuses, as ADR-064
promises); `fabriek down a` leaves `b` running. `systemd-cgtop -1
fabriek-a.slice` after `up` is the memory number.

No route off the host, in `isolation.sh`, run once with `docker` enabled on
the host so `ip_forward` is set and its FORWARD chain present: a cage's
connect to an address outside `10.77.<idx>.0/24` is refused, and the
`fabriek` nftables table is listed after docker's.

The substrate, in `isolation.sh`: for a role declared `microvm`,
`nixcage-container exec <name>-<role> -- uname -r` differs from the host's
and `nixcage-container status` names a `machine-*.scope`; for an `nspawn`
role it matches. A role declared `nspawn` under `substrate.floor = "microvm"`
runs as microVM and `up` prints the clamp.

The checkout, in `journey.sh`: after one attempt moves a stage and `fabriek
ps` runs, `git -C <checkout> rev-parse refs/heads/fabriek/<name>/<role>` is
the signed commit; before `mirror`, `refs/heads/fabriek/<name>/main` is
absent; after, it is the merge and `refs/fabriek/<name>/record` exists; the
checked-out branch's hash and `git status --porcelain` are unchanged
throughout; `stat -c %h` on a pack the clone shares reads 2, and `git -C
<clone> count-objects -v` after the clone shows no `size-pack` beyond the
checkout's.

## Verification

Implemented 2026-09-21 in thirteen commits from `d6b36fd` (the lifecycle
model) to `ee1f0f7` (the manual proofs), on this Mac, where everything
but the measurement plan is asserted:

- `models/factory-lifecycle.qnt`: the mutant without the lock violates
  `runningMeansEveryProfile` within 60 steps; the model finds no
  violation in 10000 traces of 60 steps and reaches every witness.
- `tests/command/host_module.bats` evaluates `services.fabriek` with two
  factories: bridges `fb-0` and `fb-1`, the facts files, the slices and
  their units, one nginx with a dictionary per factory, the forward
  chain, the sudoers rule. `factory_up.bats` drives `factory-up` and
  `factory-down` whole; `up.bats` the CLI's side on a real checkout;
  `seam.bats` both substrates on the whole line; `probes.bats` one reader
  over two factories; `resources.bats` and `repo_declaration.bats` the
  substrate, its floor and the reserved names. 440 of 442 bats scenarios
  pass; the two that do not predate this ADR (`catalogue_cli.bats`'s
  restricted-mode path on this Mac, and none else).
- `factory/`: 185 of 185.
- `tests/system/journey.sh`: every check, the checkout's refs and its
  untouched branch and tree among them.

The measurement plan ran on the NixOS host `pc` on 2026-09-22, against
this tree at `45d07b8` with `hardware/pc/system/fabriek.nix` in the nixos
repository declaring two factories, `widgets` giving its `backend` role
`substrate = "microvm"`. Transcripts are under `/tmp/fabriek-proof/`.

- Two factories on one host, `two-factories.sh` (`two-factories.txt`):
  every check. `example` and `widgets` each hold their slice's units,
  `fb-0` is up at 10.77.0.1 and `fb-1` at 10.77.1.1, example's architect
  connects to its own bus and is refused at widgets's, and `down example`
  leaves widgets's executor active. Idle, with no task filed,
  `MemoryCurrent` of `fabriek-example.slice` is 454332416 bytes, 433 MiB.
- No route off the host, `isolation.sh` on `widgets`, run plain and again
  with docker enabled (`isolation.txt`,
  `isolation-widgets-forward.txt`): every check. A cage sees `host0` and
  `lo` and nothing else, resolves nothing, reaches neither 192.168.1.242
  on another interface of the host nor a peer cage, and reaches the
  proxy. With `ip_forward` at 1 and docker's FORWARD chain present, the
  `fabriek` table still drops what comes from or goes to an `fb-*`
  bridge. Spend moves for the sender alone, a forged source address at
  reviewer's veth moves nobody's count, the proxy answers 429 at the
  declared ceiling of 15000 tokens, and the executor holds the decider
  there and is still running forty-five seconds later.
- The substrate, in the same run: `reviewer` sees the host's 6.18.49,
  `backend` a kernel that is not the host's, and nixcage names a
  `machine-*.scope` for its cage. Gated, not failed: the clamp a floor
  prints wants `caps.substrate = "microvm"` in the operator's
  configuration on `pc`, which `pc` does not declare; the clamp itself is
  asserted by `resources.bats` and `seam.bats`.
- The checkout, `parity.sh` on `example` (`parity.txt`), which is
  PRD-006's journey with real models rather than `journey.sh`'s stand-ins
  and so proves the same refs the harder way: a goal filed with `fabriek
  file` became issue 8, labelled `design` and assigned with no second
  command; the five stages each moved on their own with an outcome
  comment, and the executor closed the issue; the executor opened the
  pull request, whose branch is in a role's namespace and which the
  checkout carries under `fabriek/example/` and under no bare name; the
  operator merged it, and the checkout's own branch and working tree were
  as the operator left them throughout. The proxy counted tokens and the
  executor is routing.

That parity run's last three checks failed on the proof and not on the
host, and `45d07b8` fixes both causes: it wanted exactly one open pull
request where the decider had legitimately pushed the architect's and the
manager's branches beside the builder's, and it read the mirror and the
record at once where `mirror` is asked on the bus, answered when the
executor next comes round, and reaches the checkout only on the
operator's next `fetch`. Point 5 was then confirmed by hand on the same
factory: after `up`, `mirror` and `fetch`, the checkout's
`fabriek/example/main` is `7f1ed9b8`, which is Forgejo's main, and
`refs/fabriek/example/record` is present.

The host found what no test on a Mac could, and this tree carries the
fix for each: a factory's clone and its forge seed named safe to git,
which a checkout owned by the operator and read as root needs; an nginx
include per factory rather than one shared name; the state unit started
before render, since the bus ACL is applied against a running bus; a
cage's running read from what `nixcage-container status` says and not
from its exit code; `sudo systemctl` in the proofs, so a unit does not
ask the operator for a password per call; and the CLI reaching the
machine program by the sudoers path. A microvm role also found a gap in
the cage itself, closed upstream by nixcage's ADR-020 (a file asked as a
bind is staged into a microVM, `exec` reads the session's home from the
record, and a session without a tty reads a pipe that waits) and pinned
here by the lock.

Status 2026-09-22: ADR-068 is implemented, and with it two of the units
this ADR declares are gone. `fabriek-<name>-record` and
`fabriek-<name>-board` are replaced by `fabriek-forge-storage` and
`fabriek-forge`, one board for the host outside every factory's slice,
on its own dataset; a factory's slice holds its state, its bus, its
egress credentials and its executor, and its cost on the host falls with
the Forgejo that left it. Point 2 is amended in that: a factory's
services are still NixOS units, and the board is the host's rather than
the factory's. Everything else of this ADR stands, the measurement
plan's four claims included.

ADR-069 is implemented too, and takes the bus the same way: one
`nats.service` for the host with an account per factory, in place of
`fabriek-<name>-bus` and `fabriek-<name>-bus-acl`. Sharing one Valkey
between factories was examined under ADR-069 and refused. What is left
in a factory's slice is its state, its egress credentials and its
executor, and `fabriek_up_units` is gone with the units it listed: up
starts the state unit, renders, and prepares, and down stops the
executor.

Point 2 is amended twice over, then: a factory's services are still
NixOS units, and the board and the bus are the host's rather than the
factory's.

Amended by ADR-070 (implemented 2026-09-25): every factory runs in a nixcage
machine of its own, so point 4's per-role substrate and floor are gone, point
5's remote is the forge rather than the clone, and "the factory as the
isolation unit is given up" is taken back: a factory is one again.

