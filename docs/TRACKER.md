# ADR & PRD Tracker

GENERATED FILE -- do not edit. Rebuild with `docmeta-tracker <docs-root>`.
Every fact here comes from the frontmatter of the document it names; change the
document, then regenerate.

**Generated:** 2026-09-06

**Next PRD number:** 006

**Next ADR number:** 026

## PRDs

| # | Title | Status | Phases | Depends On | Summary | Flags |
| --- | --- | --- | --- | --- | --- | --- |
| [PRD-001](PRD-001-actor-mailbox.md) | A mailbox that lets project containers exchange messages | proposed | 0/4 | -- | give each project actor a durable mailbox so agents in separate containers can signal, delegate, and share findings |  |
| [PRD-002](PRD-002-autonomous-workflow-supervisor.md) | A supervisor that runs declared workflows across cages | superseded | 0/5 | PRD-001 | declared workflows dispatch caged agent runs under gates and caps, so runs start without a human |  |
| [PRD-003](PRD-003-software-factory.md) | A software factory of caged roles working one repository | implemented | 8/8 | PRD-002 | named roles in cages work one assigned repository, delegating tasks through the supervisor with herdr as the console |  |
| [PRD-004](PRD-004-a-factory-of-its-own.md) | A factory brings its own machine and declares itself | implementing | 2/5 | PRD-003 | a factory is declared in the repository it works and runs in a VM cageworks builds for it on either platform |  |
| [PRD-005](PRD-005-agents-that-take-their-own-work.md) | Agents that take their own work from the record | proposed | 0/5 | PRD-004 | agents poll the record, take work by leased claim and run until stopped; the dispatching supervisor is not built |  |

## ADRs

| # | Title | Status | Phases | Depends On | Summary | Flags |
| --- | --- | --- | --- | --- | --- | --- |
| [ADR-001](ADR-001-vm-microvm-architecture.md) | NixOS microVM as the sole execution model | superseded | -- | -- | Replace bwrap/Seatbelt process sandboxing with one per-project NixOS microVM managed by nixcage |  |
| [ADR-002](ADR-002-shared-vm-project-containers.md) | One shared VM with per-project containers; plain flake devShell as the interface | implemented | -- | -- | Replace per-project microVMs with one shared VM running imperative nspawn containers driven by plain devShells |  |
| [ADR-003](ADR-003-native-containers-on-linux.md) | Containers run natively on Linux; the VM becomes a macOS kernel shim | implemented | -- | ADR-002 | Linux hosts run project nspawn containers directly; the shared VM remains only where a Linux kernel is missing |  |
| [ADR-004](ADR-004-container-uid-mapping.md) | Container sessions run under the project owner's uid, not real root | implemented | -- | ADR-003 | nspawn maps the container onto the project owner's uid instead of running sessions as real root |  |
| [ADR-005](ADR-005-optional-dev-shell.md) | A project without a devShell enters the base container shell | implemented | -- | ADR-002 | sessions probe the flake and fall back to the base container shell when it defines no devShell |  |
| [ADR-006](ADR-006-direnv-project-environments.md) | A project with an .envrc is entered through direnv | implemented | -- | ADR-005 | sessions run direnv when the project has an .envrc, so those projects get the same environment as on the host |  |
| [ADR-007](ADR-007-worktree-git-directory-bind.md) | A linked git worktree binds its git directory into the session | implemented | -- | ADR-002 | sessions bind the git directories a linked worktree points at, so git works in a worktree instead of failing outright |  |
| [ADR-008](ADR-008-session-git-identity-and-signing.md) | Sessions commit under a declared identity and sign through the forwarded ssh-agent | implemented | -- | ADR-007 | sessions get a declared git identity and sign through the forwarded ssh-agent, holding no key of their own |  |
| [ADR-009](ADR-009-unattended-run-signing-key.md) | Unattended runs sign with a per-role cage key, not the forwarded agent | superseded | -- | ADR-008 | a supervisor-started run gets a per-role signing key in the cage and no forwarded agent, so it cannot reach a remote |  |
| [ADR-010](ADR-010-role-cage-identity.md) | A factory role cage runs under its own uid, name, and signing key | implemented | -- | ADR-004, ADR-007, ADR-009 | factory role cages get an allocated uid and a named user, own their worktree, and write only their own refs |  |
| [ADR-011](ADR-011-factory-repository-placement.md) | A factory works a clone on nixcage's own storage, synced with the operator's checkout | implemented | -- | ADR-010 | a factory works a clone on nixcage storage that the supervisor syncs with the operator's checkout |  |
| [ADR-012](ADR-012-sqlite-for-mutable-state.md) | A factory's mutable state lives in SQLite; the declaration stays files | withdrawn | -- | ADR-011 | tasks, runs and uid allocations move into SQLite, while the Nix-rendered declaration stays a directory tree |  |
| [ADR-013](ADR-013-git-bug-as-the-factory-record.md) | The factory's shared record is git-bug, carried in the repository it works | superseded | -- | ADR-011, ADR-014 | issues and comments live in git-bug under refs/bugs, so roles collaborate through git rather than a shared database |  |
| [ADR-014](ADR-014-one-file-per-task.md) | A task's mutable fields live in one file, written by rename | superseded | -- | ADR-011 | every mutable field of a task is written together in one file, so a change cannot half-happen without a database |  |
| [ADR-015](ADR-015-capabilities-and-stage-policies.md) | A stage needs a capability and states its own policy; roles provide capabilities | superseded | -- | ADR-010, ADR-011 | stages name a capability, roles declare what they provide, and each stage states its own entry and exit policy |  |
| [ADR-016](ADR-016-specialist-toolchains.md) | A specialist role works in a devShell the project's own flake names | implemented | -- | ADR-005, ADR-010, ADR-015 | a role declares which devShell of the assigned repository it enters, so specialists get different toolchains |  |
| [ADR-017](ADR-017-zfs-storage-for-factory-state.md) | The VM keeps nixcage's state on ZFS, one dataset per role worktree | implemented | -- | ADR-010, ADR-011 | factory state moves to a ZFS pool with a dataset and quota per role worktree; worktrees stay, clones are refused |  |
| [ADR-018](ADR-018-cageworks-depends-on-nixcage.md) | The factory becomes cageworks, a separate project that depends on nixcage | superseded | -- | ADR-002, ADR-004, ADR-010, ADR-017 | the factory leaves nixcage to become cageworks, which pins nixcage as a flake input and uses four exported primitives |  |
| [ADR-019](ADR-019-cageworks-owns-a-factory-vm.md) | cageworks builds and runs one NixOS VM per factory, on every platform | accepted | -- | ADR-010, ADR-011, ADR-017 | cageworks owns a per-factory microVM on Linux and macOS alike, with nixcage caging roles inside it |  |
| [ADR-020](ADR-020-a-factory-declares-itself.md) | A factory declares itself in the repository it works | accepted | -- | ADR-015, ADR-016, ADR-019 | roles and workflows move into the worked repository's flake output; the operator keeps only caps and a register |  |
| [ADR-021](ADR-021-the-agent-is-a-loop.md) | A role's agent is a loop that takes its own work | accepted | -- | ADR-009, ADR-010, ADR-016 | each role runs a long-lived agent that polls the record and takes its own work, bounded by its queue not by dispatch |  |
| [ADR-022](ADR-022-the-task-is-a-git-bug-issue.md) | The task is a git-bug issue and nothing else | accepted | -- | ADR-011, ADR-021 | tasks move into git-bug with their state as labels, every role writes the record itself, and the file store is deleted |  |
| [ADR-023](ADR-023-a-leased-claim-takes-a-task.md) | A task is taken by a leased claim on a ref | superseded | -- | ADR-010, ADR-021, ADR-022 | capable agents race to create a claim ref, git's ref lock decides the winner, and the claim is a lease that expires |  |
| [ADR-024](ADR-024-a-take-is-a-claim-and-a-revalidation.md) | A take is a claim and a revalidation, and every git-bug call retries the repository lock | accepted | -- | ADR-021, ADR-022 | winning the claim ref is not taking a task, and git-bug locks the whole repository for reads as well as writes |  |
| [ADR-025](ADR-025-the-machine-holds-the-model-credential.md) | The machine holds the model credential and injects it at egress | accepted | -- | ADR-019, ADR-021 | the model credential lives on the factory's machine and is injected at egress; a cage reaches it and nothing else |  |
