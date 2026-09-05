---
id: ADR-018
title: The factory becomes cageworks, a separate project that depends on nixcage
status: proposed
date: 2026-09-05
status_date: 2026-09-05
summary: the factory leaves nixcage to become cageworks, which pins nixcage as a flake input and uses four exported primitives
depends_on: [ADR-002, ADR-004, ADR-010, ADR-017]
supersedes: []
superseded_by: []
---

## Context

nixcage was a tool that ran one container per project. PRD-003 grew a second
thing inside it: a factory of named roles working one repository, with tasks,
workflows, capabilities, a record, and a supervisor. The two now share a
repository, a CLI, a NixOS module, an option namespace and a guest script, and
they are not the same tool. A person who wants an isolated shell for one
project carries the whole factory to get it, and every factory change is a
change to the thing that isolates unrelated projects.

The coupling is not only aesthetic. `modules/container.nix` sources fourteen
shell modules, nine of which exist only for the factory, and its dispatch table
has five `factory-*` and six `task-*` verbs beside `enter`. The factory reaches
into cage internals directly: it writes nspawn arguments, runs `zfs`, and
allocates uids out of nixcage's own range. Nothing marks where one ends and the
other begins, so nothing stops the next factory feature from reaching further
in.

Extending nixcage further is the alternative to this document, and it is what
has been happening. It fails on the same point each time: the factory needs a
cage to be parameterized, and the cheapest way to parameterize it is to add
another factory-shaped special case to the cage.

## Decision

**1. This repository becomes cageworks. nixcage becomes a dependency.**
nixcage stays at `github:hamidr/nixcage` and continues as its own project.
cageworks takes it as a flake input pinned in `flake.lock`, from that remote.
Not a path input, not a subtree, not vendored: a path input would make the two
one repository again with extra steps.

**2. The line between them is a person entering one project by hand.**
Everything such a session needs is nixcage's: isolation and uid mapping, binds,
environment selection, git worktree resolution, secrets, the VM on macOS,
storage provisioning. Everything that only exists because several named workers
share one repository is cageworks': roles, capabilities, tasks, workflows,
stage policies, the git-bug record, integration, and the supervisor.

By that test the `nixcage` CLI, `modules/container.nix`, `modules/nixcage.nix`,
`modules/host.nix`, `modules/dev-shell.sh` and `modules/git-worktree.sh` leave.
So do `modules/role-uid.sh` and `modules/storage.sh`, which need the host's uid
space and its pool and become the primitives of point 3 with their factory
vocabulary stripped. `factory-*.sh`, `workflow-config.sh`, `task-store.sh`,
`caps.sh`, `record.sh`, `integrate.sh`, `role-worktree.sh`, `signing.sh`,
`role-guidance.*`, `models/` and `examples/factory-project/` stay. The CLI
leaves as a file, not as a whole: its `role`, `task` and `factory` verbs are
what a person does to a factory rather than to a cage, and they stay as the
`cageworks` CLI of point 4.

Signing is the one that looks like it belongs upstream and does not. ADR-009
puts a key in the cage instead of forwarding the agent, and the cage's whole
part in that is refusing to forward one, which is `--no-agent`. That the key is
per role, where it lives and what it signs are facts about a role.

**3. nixcage exports four primitives, and cageworks uses nothing else.**
Each is argv on a program, because argv is what `flake.lock` can pin and what a
test can stub:

- *A parameterized session.* `nixcage-container enter <name> <path> [cmd...]`
  gains `--uid`, `--user`, `--home`, `--bind SRC:DST`, `--bind-ro SRC:DST`,
  `--setenv K=V`, `--shell NAME` and `--no-agent`. Every role-specific special
  case in `container.nix` becomes one of these flags, passed by cageworks.
- *A principal's uid.* `nixcage-container uid <name>` allocates from the range
  nixcage declares, monotonically, never reissuing a number. The word "role"
  leaves it: it allocates for a named principal, and what a role is stays
  cageworks'.
- *Owned, bounded storage.* `nixcage-container storage ensure <path> <uid>
  [quota]` gives a dataset where the host has a pool and an ordinary directory
  where it does not (ADR-017). Which of the two it is stays nixcage's decision;
  that a role's worktree gets one, and with which quota, stays cageworks'.
- *A way to reach the cage host.* `nixcage exec [--tty] [--agent] -- <argv...>`
  runs argv as root wherever the cages are: on the invoking machine on Linux,
  and inside the shared VM over its SSH on macOS. Every word is passed through
  as argv, so nothing a caller hands it is re-split by a remote shell.

The fourth is on the `nixcage` CLI rather than on `nixcage-container`, because
it is what carries a caller to `nixcage-container` in the first place. Without
it the other three are only reachable on Linux, and cageworks would have to
read nixcage's SSH key, port and state layout to reach a macOS VM -- which is
the coupling this document exists to remove, relocated to a worse place. It
grants no authority a caller lacks: `nixcage enter` already runs argv in the VM
as root for anyone who can run the CLI at all.

cageworks writes no nspawn arguments, runs no `zfs`, allocates no uid and opens
no SSH connection itself. When it needs something it cannot express through
these four, the interface changes in nixcage first.

**4. cageworks ships its own two programs.** `cageworks-container`, installed
by cageworks' own NixOS module, holds the `task-*`, `role-*` and `factory-*`
verbs and calls `nixcage-container` as a subprocess. The `cageworks` CLI is
what an operator types, and holds what `nixcage role`, `nixcage task` and
`nixcage factory` hold today; it reaches its guest program through
`nixcage exec` and knows nothing else about how a cage host is reached.

The alternative was for nixcage to export a sourceable shell library that
cageworks sources by store path, the way `container.nix` sources its modules
today. Rejected: that is the current coupling with a flake input added. It
binds cageworks to nixcage's internal function names, gives the boundary no
version to break at, and lets a renamed helper break a dependant silently.

**5. The option namespace moves wholesale, with no alias.**
`nixcage.factories.*` and `nixcage.supervisor.*` become `cageworks.factories.*`
and `cageworks.supervisor.*`, and the rendered declaration moves from
`/etc/nixcage/factories` to `/etc/cageworks/factories`.
`nixcage.workspaceRoots`, `secretEnv`, `git.*`, `storage.dataset`, `vm.*`,
`authorizedKeys`, `sshPort` and `shareProto` stay where they are. The
operator's config flake is edited once; no compatibility alias is kept, because
an alias would leave two names for one option and no date on which the old one
dies.

**6. The documents stay here and nothing is renumbered.** ADR-001 through
ADR-008 describe code that now lives upstream. They remain as the record of why
the cage is shaped as it is, and are historical rather than authoritative here:
a change to cage behaviour is proposed in nixcage's repository, not in this
tracker. Moving them was considered and is impossible as things stand, because
`depends_on` does not cross repositories -- `docmeta-check` on a document
citing an absent ADR reports `depends_on references unknown ADR-004` and exits
1. Numbering continues at ADR-018.

**7. The models stay, unchanged.** `factory-structure.als` and
`factory-lifecycle.qnt` constrain the factory, which is what cageworks keeps.

## Consequences

nixcage's input surface widens. `--bind` on the guest entry point maps any host
path into a cage, where previously only code that knew about roles could add a
bind. It grants no authority the caller lacks, since that caller already runs
as root outside every cage and could invoke nspawn directly, but the check that
was implicit in "only factory code adds binds" is now explicit and has to be
written: nixcage validates destinations and refuses a bind over `/etc/nixcage`
or over the store.

`nixcage exec` widens it in the same shape and for the same reason. It runs
argv as root on the cage host, which `nixcage enter` already did for anyone who
could run the CLI; what changes is that the capability is now named, so it can
be reasoned about instead of being a side effect of entering a project. It is
not a shell: argv is passed through word for word, and on macOS every word is
quoted for the remote shell exactly as `enter` quotes a session command today.

A cageworks change that needs a new nixcage flag becomes two commits in two
repositories and a lock bump. That cost is the boundary; paying it is how the
interface stays small. Bisecting a regression across the seam gets harder for
the same reason.

The test suite splits along the same line. `tests/unit/{cache,container_name,
dev_shell_detection,direnv_session,git_worktree_binds,vm_attr,workspace_root}`
and `tests/command/{cli_dispatch,enter,down,rm,rm_validation,status,linux_mode,
macos_enter}` go upstream; the factory tests stay. cageworks' command tests
stub `nixcage-container` on `PATH` exactly as they stub `ssh` and `sudo` today,
which makes the seam something the suite asserts on rather than something it
crosses.

Sequencing is forced: cageworks does not build until nixcage ships the four
primitives. The exports land and are tagged upstream first, then this
repository drops the cage files and pins the input.

The interface is guessed once and lived with. The mitigation is that every flag
in point 3 exists today as a special case inside `container.nix`, so what is
being exported is a description of working code rather than a design.

The Formal Modeling Gate does not fire. No invariant changes: the permission
model of ADR-010 and the cross-entity invariants of ADR-014 and ADR-015 keep
their content, and only the program enforcing the primitives underneath them
moves. Should the exported interface change what a role may own or write,
`models/factory-structure.als` changes in that commit.

## Verification

The split is done when these pass in cageworks with nixcage as an input, and
not before:

```bash
nix develop --command shellcheck modules/*.sh          # no nixcage script here
nix develop --command bats --recursive tests/
docmeta-check docs && docmeta-tracker --check docs
alloy6 exec models/factory-structure.als
quint run models/factory-lifecycle.qnt --invariant=allInvariants --max-steps=60
```

One gate is specific to the seam and is written before the move: a role session
started through `cageworks-container` produces the same `nixcage-container`
invocation, flag for flag, as the arguments `container.nix` builds today. The
stub on `PATH` records its argv, and the recorded line is the assertion. A
migration that cannot show this has changed what a role session is while
claiming to have moved it.
