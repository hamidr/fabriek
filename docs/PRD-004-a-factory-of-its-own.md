---
id: PRD-004
title: A factory brings its own machine and declares itself
status: implementing
date: 2026-09-06
status_date: 2026-09-12
summary: a factory is declared in the repository it works and runs in a VM cageworks builds for it on either platform
depends_on: [PRD-003]
supersedes: []
superseded_by: []
phases_total: 5
phases_done: 4
---

## Problem

A factory today is a property of the operator's workstation. Its roles and
workflows are options in that machine's NixOS configuration, and on Linux its
cages run on that machine's kernel. Three people are hurt by this, in three
different ways.

The operator, when they want a factory at all. Starting one means editing the
configuration of the computer they use for everything else, running
`nixos-rebuild`, and doing it again to add a role or change what finishing a
stage means. The edits that happen weekly cost a machine rebuild, so they do not
happen.

The operator again, at rest. On Linux the roles are nspawn cages on their own
kernel, and the agents inside them run unattended for hours on work nobody is
watching. On macOS the same roles sit behind a hypervisor. The strength of the
boundary between an unsupervised agent and the operator's mail, keys and other
projects is decided by which laptop is open, which is not a decision anybody
made.

Anyone handed the repository, when they want to work it the same way. The half
of a role that says which devShell it enters is versioned with the code; the
half that says the role exists is on one person's machine. They drift, nothing
notices, and a second person cannot run the factory without being handed a
fragment of somebody's NixOS configuration to splice into their own.

The way out is not new. The VM exists, has worked since ADR-002, and is used on
one platform out of two by the project that does not own it.

## Users

- **The operator.** One person, one machine, several repositories they might
  want worked. They decide what a factory may cost on their hardware and which
  repositories are allowed to run one here. They are still the only trust
  domain.
- **The role.** Unchanged from PRD-003: a caged agent with a name, a job, a
  worktree and its own state. It does not know it is in a VM.
- **The reader of the repository.** Anyone who clones it and wants to see, or
  run, the way it is worked. New in this document, and the reason the
  declaration moves.

## Goals

1. The same factory gets the same isolation whichever platform it runs on, and
   that isolation includes a boundary toward the operator's own machine.
2. Two factories on one host cannot reach each other at all.
3. Starting a factory does not touch the operator's machine configuration, and
   changing a role does not rebuild anything.
4. Cloning a repository is enough to see who works it and how, and enough to
   run it that way on a second machine.
5. What a factory may spend on the operator's hardware is the operator's to
   state, and is stated once for all factories.
6. A repository that declares a factory cannot thereby declare anything about
   the machine it is given.

## Non-goals

- **A VM per role.** Roles are separated by the cage, uid and ref partition
  PRD-003 built, and that is unchanged. Multiplying VMs by role would make the
  cage layer redundant and the boot cost linear in the team.
- **Sharing a store between factories.** Disjoint machines mean disjoint
  stores. Deduplication across factories is not attempted here.
- **A migration path.** The NixOS options and the rendered declaration are
  deleted rather than deprecated, and existing factories are rewritten by hand
  once. There is no reader that falls back to the old placement.
- **Running an untrusted repository.** Evaluating a declaration evaluates that
  repository's Nix. This document bounds what the declaration can say, and does
  not claim a hostile repository is safe to point a factory at.
- **Remote or multi-machine factories.** One host, one operator, as in PRD-002
  and PRD-003. The VM is local and its port is on loopback.
- **Replacing nixcage's own paths.** nixcage keeps its shared macOS VM and its
  native Linux cages for the single-project case. This document changes only
  what cageworks uses.
- **Dispatch.** What remains of PRD-002 remains there. A factory with its own
  machine still starts runs only when a person types the command.

## Success criteria

- A repository is cloned onto a second machine, and the factory it declares runs
  there with no configuration beyond that machine's caps file.
- A role gains, loses or changes its devShell, its capabilities or a stage's
  policy, and takes effect on the next run with nothing rebuilt and no session
  killed.
- The operator's NixOS configuration and `~/.config/nixcage` contain nothing
  about any factory, on either platform.
- A factory started on Linux and the same factory started on macOS put the same
  boundary between a role and the operator's home directory, and the difference
  between the platforms is visible nowhere above the hypervisor.
- A declaration naming a key outside the schema is refused, by name, before
  anything is built.
- A `resources` value above the operator's cap is clamped, and the operator is
  told which field was clamped and to what, rather than finding out from
  `free`.
- A factory's VM is stopped and started ten times in a row while roles hold
  worktrees, and no worktree, ref or task file is left truncated or empty.
- Boot to a usable role session is measured on both platforms and written down,
  so the cost this document accepts is a number rather than a claim.

## Requirements

### The declaration

- A repository states the factory that works it, in its own flake, against a
  schema cageworks defines and closes. What is read is what the repository has
  committed, so the factory working a repository is the one its history
  declares, and which declaration a run used stays reconstructable. Nothing outside that schema is accepted,
  and an unknown key is an error naming the key rather than a value ignored.
- The schema carries roles, what they provide, the devShell each enters, the
  workflows and their stages, and what the factory asks of the machine. It
  carries no NixOS: a repository cannot add a package, a service, a bind or a
  kernel setting to the VM it is given.
- A repository that declares no factory is not one, and is refused with that
  sentence rather than given a default.
- The declaration is read when it is needed, not built into anything. Only what
  the factory asks of the machine can require the machine to change.
- The operator states, once, the ceiling any factory on this host may reach for
  memory, cores, worktree quota and concurrency, and which repositories are
  registered here. This lives in one plain file the operator owns, the same file
  on both platforms, and requires no Nix, no module and no scaffold.
- Where the repository asks for more than the ceiling allows, it gets the
  ceiling and the operator is told.

### The machine

- Each factory runs in a machine of its own, built by cageworks from the same
  description on Linux and on macOS. A person cannot tell from inside which
  platform they are on.
- Two factories share no kernel, no store, no uid space and no filesystem.
- The machine has persistent storage of its own, and everything mutable the
  factory owns lives on it: the clone, the worktrees, the homes, the tasks, the
  keys and the record. It survives stopping the machine, rebooting the host and
  rebuilding the machine's configuration.
- Stopping a factory shuts its machine down rather than ending it, and a stop
  that cannot complete cleanly is reported rather than forced silently. Work in
  flight has been lost to an abrupt stop before, and the storage that made that
  recoverable is inside the machine now being stopped.
- The operator can see which factories exist here, which are running, and what
  each is holding, without entering one.
- Reaching into a factory's machine is cageworks' own business, since cageworks
  made the machine. No factory reads another factory's way in.

### Roles, unchanged

- Everything PRD-003 requires of a role holds without amendment: its uid, its
  permanent worktree, its own home, its own signing key, its ref namespace, and
  the guidance it is given. A role's session is composed the same way and
  produces the same invocation as it does today.
- A role reaches its toolchain by naming a devShell of the repository, as
  ADR-016 has it. That the declaration now sits beside those shells is the point
  of moving it, and changes nothing about how one is entered.

## Constraints

- Hardware virtualisation is required wherever a factory runs: KVM on Linux,
  Hypervisor.framework on macOS. Before this document each platform needed only
  one of the two.
- macOS still needs a Linux builder to build the guest, as it does today for
  nixcage's own VM.
- The operator's path contains no `nixos-rebuild`. Anything that would need one
  is out of scope by construction.
- The guest is nixcage in the situation ADR-003 built for it, a Linux host
  running cages natively. Nothing in the guest is written to work only under a
  hypervisor.
- One repository per factory, as PRD-003 has it. Two repositories are two
  factories, and now two machines.

## Risks

- **Evaluation is execution.** Reading a declaration runs the repository's Nix.
  The schema bounds what the declaration can say, not what evaluating it can do.
  Mitigation is a bound, `--no-allow-import-from-derivation`, and a statement in
  ADR-020 that this is accepted rather than solved.
- **The machine is written twice.** nixcage's own VM module already carries
  the volumes, the pool, the shares and the networking, per machine. ADR-019
  gives the VM to cageworks, so this is a second implementation of that
  scaffolding, per factory. It was weighed against importing nixcage's module
  and parameterising it, which is cheaper and is the split ADR-019 rejected.
  The cost is that a fix upstream does not arrive here, and the mitigation is
  that the two have different shapes and will diverge anyway.
- **The cost is per factory now.** A store, a disk image and a boot each. An
  operator running four factories pays four times, where they paid once. If this
  is what stops it being used, the answer is fewer factories rather than a
  shared machine, and that trade is stated rather than engineered around.
- **Latency at first contact.** A role session behind a cold boot feels slower
  than one behind a running cage. Measured in phase 2 rather than assumed, and
  if it is bad the answer is keeping the machine up rather than removing it.
- **The storage disaster is inherited.** ADR-017 exists because a VM was killed
  rather than shut down and worktrees came back empty. cageworks now owns the
  stopping, so it owns that failure mode; the requirement above is the mitigation
  and the phase 2 exit test is the evidence.
- **Two ways to declare, briefly.** Between phases the declaration moves before
  the machine does. The old placement is deleted in the phase that replaces it,
  not later, so the window is a phase boundary rather than a release.

## Open questions

- **Does an idle machine stop?** Nothing here says a factory shuts down when no
  role is working, and nothing says it stays up. Both are defensible and the
  answer changes what latency the operator feels.
- **What happens to work in flight when `resources` change?** Resizing means
  restarting the machine, and roles may be mid-task. Refusing, queueing until
  idle, and restarting anyway are all plausible; none is chosen here.
- **How does the repository reach the machine?** ADR-011 has roles work a clone
  the supervisor syncs with the operator's checkout. Whether that checkout is
  shared into the machine or fetched over the machine's own transport is not
  settled, and the two differ in what the guest can see of the host.
- **Where do secrets come from?** `secretEnv` resolves against the host's
  sops-nix today. A machine cageworks built has no such host, and nothing here
  says what replaces it.
- **Is concurrency per factory or per host?** The cap is stated per host and
  spent per factory, and with several factories running those are different
  numbers.

## Phases

Ordered so that each phase leaves a factory that works, and so that nothing is
deleted before the thing replacing it exists.

1. **The declaration moves into the repository.** The schema, its reader, its
   validation, the operator's caps file and the register, and the clamping being
   reported. Factories still run exactly where they run today. The NixOS module,
   the option namespace, the rendered declaration and the old example are deleted
   in this phase, because this is the phase that replaces them.
2. **A machine exists.** cageworks builds and boots one microVM per factory on
   both platforms, with its own disk, its pool, and nixcage's host module inside.
   `up`, `down` and a status that says which machines are here. No roles in it
   yet. Exits on the stop-and-start test, because the storage that phase 3
   depends on is only trustworthy if stopping is.

   Done. `tests/manual/stop-and-start.sh` ran ten cycles on an aarch64-darwin
   host with an aarch64-linux guest: three hundred files on the pool, every one
   checked against a manifest after every cycle, ten intact and none truncated.
   What it cost, from the same run: stopping three to ten seconds, starting six
   to eighty-six with a warm store, and three to four seconds from start to a
   usable session. A factory's disk grew to 1.6G of store and 560M of pool, and
   the runner's own closure is 3.2 GiB.

   Four faults were found by running it and none by reading it. The runner was
   built for the guest's system rather than the host's, so on macOS it reached
   for chattr and stopped. A machine ended with the command that started it,
   twice: backgrounding is not detaching, and setsid refuses when the caller
   already leads a process group. The guest generated SSH host keys on the
   rootfs, so it was a different machine every boot and cageworks refused the
   second one. And a successful shutdown looked like a refusal, because
   powering off takes the connection down with it.
3. **The factory moves in.** The transport, the clone on the machine's own pool,
   worktrees as datasets, and the three primitives called inside the guest.
   `cageworks role` and `cageworks task run` work against the machine on both
   platforms, and the recorded role-session invocation is unchanged. The
   transport of the previous arrangement stops being used here.

   Done. `tests/manual/moves-in.sh` is the exit condition and it holds: a clone
   from a remote onto the pool, a worktree owned by the agent's uid rather than
   root, a cage entered on it, and the repository visible inside. The uid is
   checked from both ends, because either alone is satisfied by a cage that maps
   nothing -- 1 inside, since nspawn maps container uid 0 upward onto the block,
   and the block's second number on the machine.

   Where the code comes from changed on the way. ADR-011 had the supervisor sync
   with the operator's checkout, which was free when a factory lived in
   nixcage's shared VM and that workspace was already mounted there. ADR-019
   ended that, and every way of making two directories on two machines agree
   cost more than it returned, so ADR-032 has the machine clone the repository's
   own origin instead.

   Four faults were found by running it and none by reading it, and all four
   were invisible to a suite of 431 passing tests, because the suite drives the
   guest program with the transport stubbed and the machine had been built and
   booted without either meeting the other. The guest program was not installed
   on the machine at all, so a factory answered "cageworks-container: command
   not found" to every verb the CLI sends. The machine's nix refused
   `nix-command` and `flakes`, so no declaration could be read and no role
   resolved. `git` was on no path but the wrapper's. And a clone that checks out
   nothing -- an origin whose HEAD names a branch it does not have -- left a
   directory that poisoned every later run and could not be recovered from
   without deleting it by hand.

   A fifth was not a fault in what ran but in what it said. Reading a
   declaration discarded nix's own complaint, so all four of the above reported
   as "its flake has no cageworks output". That message sent me to inspect a
   flake that was correct, three times, before I ran the evaluation by hand.

   Not done here, and not required by this phase: pushing role branches back to
   origin needs a forge credential on the machine, delivered the way the model
   credential is (ADR-025), plus a `GIT_SSH_COMMAND` and a `known_hosts`.
   ADR-032 point 2 wants it and integration cannot work without it.
4. **The machine is sized.** What the factory asks for meets what the operator
   allows, the machine is built to the result, and changing it takes effect
   without losing the disk. Sequenced after phase 3 because what to size for is
   only visible once roles are working in it.

   Done, by ADR-040: the clamp runs inside the image build
   (`modules/machine-spec.sh`), `cageworks up` prints what it changed, and
   `tests/manual/stop-and-start.sh` ran ten rebuild-and-boot cycles on
   2026-09-12 with the pool intact (docs/roadmap.md 2.5).
5. **First contact.** Running cageworks without installing it, an example
   repository carrying a real declaration, and the documents rewritten to
   describe what the thing now is. The phase that makes goal 4 true for somebody
   who did not build this.

## Design gates

The Formal Modeling Gate fires once, on the machine's lifecycle, and
`models/vm-lifecycle.qnt` is written and run before phase 2 is implemented.
Absent, built, booting, running, stale and stopping is more than three states,
and the host and the guest interleave across them: a boot can fail after the
disk exists, a stop can race a session, a resize can arrive while roles hold
worktrees. The invariant that matters is that no path reaches a state where the
disk is being written and the machine is being ended.

It does not fire on `models/factory-structure.als`. Per-factory machines make
factories disjoint; they do not change what a role owns, which ref it may write
or who takes a task. The model is unchanged, deliberately, and would be changed
in the same commit if that stopped being true.

It does not fire on resolving the declaration against the caps either. Config
resolution is a listed shape and this is its degenerate case: each field is
clamped against one ceiling, no field constrains another, and there is no
assignment to search for.
