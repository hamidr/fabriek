# CLAUDE.md

This file provides guidance to Claude Code when working with code in this repository.

## What is cageworks

cageworks runs a factory: one git repository assigned to a set of declared
roles that work it at the same time, each in a cage of its own. A role is a
worker, not a project -- it has its own uid, its own permanent worktree, its
own home and its own signing key (ADR-010, ADR-009).

It does not run cages. [nixcage](https://github.com/hamidr/nixcage) does, and
is a flake input pinned in `flake.lock`. The line between them is a person
entering one project by hand: everything such a session needs is nixcage's
(isolation, uid mapping, binds, environment selection, git worktree
resolution, secrets, storage, the macOS VM), and everything that exists only
because several named workers share one repository is ours (roles,
capabilities, tasks, workflows, stage policies, the git-bug record,
integration, the supervisor). ADR-018 is that decision;
`docs/PRD-003-software-factory.md` is what was built; `docs/TRACKER.md`
indexes the rest.

## The interface with nixcage

cageworks uses four exported primitives and nothing else. It writes no nspawn
arguments, runs no `zfs`, allocates no uid and opens no SSH connection.

| Primitive | Used for |
| --- | --- |
| `nixcage-container enter [--uid n] [--user name] [--home path] [--shell name] [--bind SRC:DST] [--bind-ro SRC:DST] [--setenv K=V] [--no-agent\|--auth-sock path] <name> <project> [cmd]` | Every role session |
| `nixcage-container uid <principal>` | A role's uid, allocated once and never reissued |
| `nixcage-container storage ensure <path> <uid> [quota]` | A role's worktree, owned and bounded |
| `nixcage exec [--tty] [--agent] -- <cmd>` | Reaching the other three from the operator's machine |

When something is needed that these cannot express, **the interface changes in
nixcage first**: two commits in two repositories and a lock bump. Reaching
around them -- reading nixcage's state directory, its SSH key, its port, its
internal function names -- is the coupling ADR-018 exists to remove.

`tests/command/seam.bats` is the gate on this. It stubs `nixcage-container` on
`PATH`, records the argv a role session produces, and asserts the whole line.
A change to what a role session is shows up there as a diff.

## Repository layout

- `cageworks` -- the operator's CLI: `role`, `task`, `factory`. Reaches the
  guest program through `nixcage exec` and knows nothing else about where the
  cages are.
- `cageworks-container` -- the guest program, on the machine the cages are on.
  Holds the `role-*`, `task-*` and `factory-*` verbs and calls
  `nixcage-container` as a subprocess. A real script rather than a Nix string
  so shellcheck reads it and bats drives it.
- `modules/names.sh` -- the names cageworks accepts, checked where they are
  declared. A factory, role or capability name reaches a path, a ref and a
  container name; a devShell name reaches someone else's flake.
- `modules/*.sh` -- everything the guest program sources by store path.
  `role-worktree.sh` gives a role its worktree and the ACLs it needs;
  `signing.sh` gives it an identity; `factory-config.sh`,
  `workflow-config.sh`, `factory-clone.sh` read the declaration and the clone;
  `task-store.sh`, `caps.sh`, `record.sh`, `integrate.sh` are the supervisor's
  mechanics. Shell files rather than inline strings so the suite can source
  them.
- `modules/role-guidance.md` -- what every role is told about working in a
  cage, bound read-only into a role session.
- `modules/cageworks.nix` -- the NixOS module: `cageworks.factories.*` and
  `cageworks.supervisor.*`, rendered as `/etc/cageworks/{factories,supervisor}`.
  Needs nixcage's own module beside it.
- `modules/package.nix` -- the two programs, wrapped with the module directory
  they source and the tools they run.
- `models/` -- the Alloy and Quint models the design gate requires. They
  describe the factory, and change in the same commit as the invariants they
  constrain.
- `examples/config/` -- a complete machine running a factory.
- `examples/factory-project/` -- a repository worked by a factory: one devShell
  per specialist, which is what a role's `shell` names (ADR-016).
- `docs/` -- ADRs, PRDs and generated TRACKER.md.

## Development

```bash
nix develop                          # bash, jq, shellcheck, bats, git, git-bug
nix develop --command shellcheck cageworks cageworks-container modules/*.sh
nix develop --command bats --recursive tests/       # ~240 tests, a few minutes
nix develop --command bats tests/unit/task_store.bats
nix develop --command bats -f "sticks to the role" tests/unit/task_store.bats
```

There is no build step -- both scripts run directly (`bash cageworks help`).

`tests/unit/` sources a shell module and calls its functions. `tests/command/`
drives a program with its dependency stubbed on `PATH`: the CLI tests stub
`nixcage`, and `seam.bats` stubs `nixcage-container`. Both stubs are the seam,
which is what makes it something the suite asserts on rather than something it
crosses.

Documents and models have their own checks:

```bash
docmeta-check docs                   # frontmatter is valid
docmeta-tracker docs                 # regenerate docs/TRACKER.md, never by hand
alloy6 exec models/factory-structure.als
quint run models/factory-lifecycle.qnt --invariant=allInvariants --max-steps=60
```

## Architecture

Both programs follow a command-dispatch pattern: `main()` at the bottom
dispatches to `cmd_*` functions.

### Key subsystems

**A role session** (`cmd_role_enter`) -- resolves the role's declaration, asks
nixcage for its uid, prepares its worktree, and composes one
`nixcage-container enter` invocation out of flags. Each flag was a special
case inside the cage before ADR-018; the order they are built in is fixed,
because `seam.bats` asserts the whole line.

An operator entering by hand forwards their own agent (`--agent`, which
carries `SSH_AUTH_SOCK` across `sudo` and is read on the far side because on
macOS the socket is the VM's). A supervised run gets `--no-agent` and a key of
its own instead, so it can sign but cannot push, pull a private repository, or
authenticate anywhere (ADR-009).

**A role's worktree** (`role-worktree.sh`) -- taken from the factory's own
clone rather than the operator's repository, because role ownership needs a
filesystem carrying ownership and ACLs and a macOS operator's share has
neither; the supervisor syncs the two (ADR-011). The directory is asked for
through `storage ensure` rather than made: whether it becomes a dataset with a
quota on it is nixcage's decision and cageworks is not told which it got
(ADR-017).

**Work** -- a task, one file per field, written by rename (ADR-014). A
pipeline's stage names a capability rather than a role, roles declare what they
provide, and taking a task resolves the first idle capable role in declaration
order; after that the task sticks to it, because the branch is in that role's
namespace. Each stage states its own `ready` (enforced, presence only) and
`done` (prose, handed to the role, never checked) -- ADR-015. A role's
toolchain is a devShell of the project's own flake that its declaration names
(ADR-016).

**The record** -- git-bug inside the repository, so there is no shared database
anywhere (ADR-013). The supervisor is the only writer and acts as each role in
turn.

**State** -- `/var/lib/nixcage`, unchanged by the split. ADR-017 puts that
directory on nixcage's pool, and the storage primitive can only name a dataset
for a path the pool already mounts, so a state root of our own would have
bought a tidier name and cost every existing factory its datasets.

### Two invariants hold the design up

The supervisor is uncaged and content-blind: it reads declarations and
metadata, never a task body, a comment or a document, and mentions are labels
rather than parsed prose. And nothing a role writes ever reaches a command
line -- briefs, bodies and outcomes are files.

### What is not built

Nothing dispatches: `cageworks task run <factory> <id>` starts one run and a
person types it. A loop that picks ready work is what remains of PRD-002.

## Conventions

- `cageworks_*` prefix for shell-module functions, `cmd_*` for command
  handlers.
- Guest-side logic goes in `cageworks-container` or a `modules/*.sh` file it
  sources, never inline in a command string.
- A declared command is argv, one word per element, never a shell line: the
  declaration is data and nothing in it is re-split on the way.
- Names that reach a path, a ref, a uid or a flake reference are validated
  where they are declared (`cageworks_name_ok`, `cageworks_shell_name_ok`),
  not where they are used.
- A role session's cage is composed of nixcage flags and nothing else. Reaching
  for anything outside the four primitives means the interface is wrong, and
  the fix is upstream.
- ADR-001 through ADR-008 describe code that now lives in nixcage. They are
  historical here: a change to cage behaviour is proposed in nixcage's
  repository, not in this tracker. Numbering continues at ADR-018.
