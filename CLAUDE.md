# CLAUDE.md

This file provides guidance to Claude Code when working with code in this repository.

## What is nixcage

nixcage is a single-file Bash tool that runs one systemd-nspawn container per
project. On Linux the containers run natively on the host (config via
`nixosModules.host` in the host's NixOS configuration). On macOS they run in
one shared NixOS microVM (microvm.nix + qemu) that exists to provide a Linux
kernel. A project is any flake directory under a configured workspace root
(`devShells.default` is optional; see ADR-005) -- there are no
nixcage-specific files in projects. The primary use case is running AI coding
agents in isolation, one per project or a factory of them working one
repository. Architecture: `docs/ADR-002-shared-vm-project-containers.md`,
`docs/ADR-003-native-containers-on-linux.md` and
`docs/PRD-003-software-factory.md`; `docs/TRACKER.md` indexes the rest.

## Repository layout

- `nixcage` -- the entire host-side tool: a single self-contained Bash script.
  All commands, the platform transport seam, and VM lifecycle logic live here.
- `modules/container.nix` -- the shared container layer: the minimal userland
  profile and the `nixcage-container` script owning all nspawn mechanics.
  Used unchanged by both platform modules.
- `modules/dev-shell.sh` -- guest-side environment selection, sourced into the
  session by store path: direnv when the project has an `.envrc`, else the
  devShell, else the base userland. A shell file rather than an inline string
  so shellcheck reads it and bats sources it.
- `modules/*.sh` -- the guest-side logic, sourced by store path into
  `nixcage-container`. `git-worktree.sh` resolves a linked worktree's git
  directories; `storage.sh` gives a role's worktree its dataset and quota;
  `role-uid.sh`, `role-worktree.sh`, `signing.sh` give a role its identity;
  `factory-config.sh`, `workflow-config.sh`, `factory-clone.sh` read the
  declaration and the clone; `task-store.sh`, `caps.sh`, `record.sh`,
  `integrate.sh` are the supervisor's mechanics. Shell files rather than
  inline strings for the reason `dev-shell.sh` is one.
- `modules/role-guidance.md` -- what every role is told about working in a
  cage, bound read-only into a role session.
- `models/` -- the Alloy and Quint models the design gate requires. They
  describe the factory, and change in the same commit as the invariants they
  constrain.
- `modules/nixcage.nix` -- the VM module (macOS path): nixcage options
  (`workspaceRoots`, `authorizedKeys`, `sshPort`, `shareProto`, `secretEnv`,
  `git.*`, `vm.*`, `factories.*`, `supervisor.*`) and the VM base config.
- `modules/host.nix` -- the Linux host module: the same factory and supervisor
  options plus `workspaceRoots`, `secretEnv`, `git.*` and `storage.dataset`;
  renders `/etc/nixcage/config` and the factory declaration for the CLI, and
  installs the container layer on the host.
- `templates/config/` -- the flake template users instantiate at
  `~/.config/nixcage` (their VM configuration; sops-nix wired in).
- `examples/project/` -- an ordinary project flake showing the devShell
  interface.
- `examples/factory-project/` -- a repository worked by a factory: one devShell
  per specialist, which is what a role's `shell` names (ADR-016).
- `flake.nix` -- packages nixcage, exports `nixosModules.nixcage` and
  `templates.config`, defines the dev shell.
- `docs/` -- ADRs and generated TRACKER.md.

## Development

```bash
nix develop                          # bash, jq, shellcheck, bats, git, git-bug
nix develop --command shellcheck nixcage modules/*.sh
nix develop --command bats --recursive tests/       # ~340 tests, a few minutes
nix develop --command bats tests/unit/task_store.bats
nix develop --command bats -f "sticks to the role" tests/unit/task_store.bats
```

There is no build step -- the script runs directly (`bash nixcage help`).

`tests/unit/` sources a shell module and calls its functions; `tests/command/`
drives the CLI with `ssh`, `sudo` and `ps` stubbed on `PATH`. Guest logic that
lives inside the Nix string in `container.nix` cannot be sourced, so a few
tests assert against its source text instead -- prefer moving such logic into
a `modules/*.sh` file over adding another of those.

Anything the VM actually does is verified by building a probe VM from
`templates/config` with the nixcage input pointed at the working tree, since
the guest script only exists once a VM is built.

Documents and models have their own checks:

```bash
docmeta-check docs                   # frontmatter is valid
docmeta-tracker docs                 # regenerate docs/TRACKER.md, never by hand
alloy6 exec models/factory-structure.als
quint run models/factory-lifecycle.qnt --invariant=allInvariants --max-steps=60
```

## Architecture

The script follows a command-dispatch pattern: `main()` at the bottom
dispatches to `cmd_*` functions (`enter`, `down`, `rebuild`, `rm`, `status`).

### Key subsystems

**Config flake resolution** -- `--flake` > `NIXCAGE_FLAKE` > `~/.config/nixcage`.
`resolve_vm_attr` picks `nixosConfigurations."nixcage-<hostname -s>"` when the
flake has it, else `nixosConfigurations.nixcage` (nixos-rebuild hostname
convention; lets one flake serve several machines). The CLI never writes into
the flake; `check_flake` errors with template guidance when it is missing.

**Build cache** (`vm_build`, `vm_read_cache`) -- `rebuild` runs `nix build` on
`...microvm.declaredRunner` into `$STATE/result`, then `nix eval`s `sshPort`
and `workspaceRoots` into `$STATE/cache` so `enter` never pays an eval.
`STATE` is `${XDG_STATE_HOME:-~/.local/state}/nixcage`; it also holds the
lazily generated SSH keypair (public key must be pasted into
`nixcage.authorizedKeys`), known_hosts, pid, and log files.

**VM lifecycle** (`vm_start`, `cmd_down`) -- launches the runner in the
background from `$STATE` (virtiofsd and qemu talk over a relative socket
path, so they must share a CWD), waits for SSH, records the pid.
`vm_start_virtiofsd` bypasses the supervisord wrapper microvm.nix generates
(it insists on root) and execs the individual virtiofsd commands.

**Enter** (`cmd_enter`) -- validation order matters: flake.nix present, path
under a workspace root, then boot the VM. Derives the container name
(`container_name_for`: sanitized basename + 8-char path hash) and runs
`sudo nixcage-container enter <name> <path> [cmd...]` over SSH (`-t` when
interactive). A factory role enters through `role-enter`, which adds the
role's uid, its worktree, its signing key and the devShell its declaration
names.

**Guest container script** -- lives in `modules/container.nix` as a
`writeShellApplication`, shared unchanged by both platform modules; the host
script contains zero nspawn logic. Everything it does beyond nspawn mechanics
is a shell module sourced by store path, so shellcheck reads it and bats
sources it directly. Per
session it builds a throwaway rootfs skeleton (nspawn locks its directory,
so concurrent sessions need separate ones), binds the store read-only plus
the nix-daemon socket (`NIX_REMOTE=daemon`), the project dir at `/workspace`,
and the persistent home at `/root`, then execs `nix develop`.

**Git in a session** -- an ordinary repository needs nothing beyond the
project bind, but a linked worktree keeps its git directory inside the primary
repository: `nixcage_git_binds` (`modules/git-worktree.sh`) resolves the
administrative and common directories and they are bound at the exact path git
recorded (ADR-007). Identity comes from `nixcage.git.{userName,userEmail}`
rendered to `/etc/nixcage/gitconfig`, and signing goes through the user's
ssh-agent: `enter` forwards `SSH_AUTH_SOCK` (`ssh -A` on macOS, an explicit
`--auth-sock` past sudo on Linux) and the guest binds it at
`/run/ssh-agent.sock`. No key material enters a container (ADR-008).

**Storage** -- the VM keeps `/var/lib/nixcage` on a ZFS pool of its own
(`nixcage-pool.img`, created on first boot by `nixcage-storage.service`), with
one dataset per role worktree so a role can carry a `refquota` and an unclean
stop cannot truncate its work (ADR-017). `acltype=posixacl` and `xattr=sa` are
load-bearing: without them ZFS refuses the ACLs ADR-010 grants. On Linux the
admin says whether there is a dataset (`nixcage.storage.dataset`); unset means
ordinary directories.

**The factory** (PRD-003) -- one git repository assigned to a set of declared
roles that work it at the same time. A role is a worker, not a project: it has
its own uid, its own permanent worktree, its own home, and its own signing key
(ADR-010, ADR-009). Roles work a clone on nixcage's own storage rather than the
operator's checkout, because role ownership needs a filesystem carrying
ownership and ACLs and a macOS operator's share has neither; the supervisor
syncs the two (ADR-011). They share the clone's object database through a POSIX
ACL and are partitioned by ref: a role writes only `refs/heads/<role>/*`, and
`main` is writable by no cage at all.

Work is a task, one file per task written by rename (ADR-014). A pipeline's
stage names a capability rather than a role, roles declare what they provide,
and taking a task resolves the first idle capable role in declaration order;
after that the task sticks to it, because the branch is in that role's
namespace. Each stage states its own `ready` (enforced, presence only) and
`done` (prose, handed to the role, never checked) -- ADR-015. A role's
toolchain is a devShell of the project's own flake that its declaration names
(ADR-016).

Discussion lives in git-bug inside the repository, so there is no shared
database anywhere (ADR-013). The supervisor is the only writer and acts as each
role in turn.

Two invariants hold the design up. The supervisor is uncaged and
content-blind: it reads declarations and metadata, never a task body, a comment
or a document, and mentions are labels rather than parsed prose. And nothing a
role writes ever reaches a command line -- briefs, bodies and outcomes are
files.

Nothing dispatches yet: `nixcage task run <factory> <id>` starts one run and a
person types it. A loop that picks ready work is what remains of PRD-002.

**Secrets** -- sops-nix in the user's config flake; age key generated on the
VM data volume at first boot; `nixcage.secretEnv` maps env vars to secret
names, injected per session by the guest script from `/run/secrets`. The
host environment is never read.

### Platform branching

`detect_os()` (overridable with `NIXCAGE_OS` for tests) selects the
transport: Linux executes `sudo nixcage-container` locally and reads
`/etc/nixcage/config` (`NIXCAGE_HOST_CONFIG` override for tests);
macOS goes over SSH into the VM and reads the build-time cache. `cfg_read`
is the dispatch point. `rebuild`/`down` are macOS-only
(`require_vm_platform`); on Linux the host owns the lifecycle via
nixos-rebuild. The macOS hypervisor is qemu because microvm.nix supports
`forwardPorts` (our SSH path) only with qemu user-mode networking.

## Conventions

- `VM_*` prefix for globals set by `vm_read_cache`.
- `vm_*` prefix for VM lifecycle/SSH helpers, `cmd_*` for command handlers.
- Guest-side container logic goes in `nixcage-container` inside
  `modules/container.nix`, never inline in SSH command strings.
- Workspace roots mount at identical absolute paths in the VM, so the same
  project path is valid on host and guest -- code may rely on this.
- A declared command is argv, one word per element, never a shell line: the
  declaration is data and nothing in it is re-split on the way.
- Names that reach a path, a ref, a uid or a flake reference are validated
  where they are declared (`nixcage_role_name_ok`, `nixcage_shell_name_ok`),
  not where they are used.
- The container profile is bash, coreutils, nix, git, cacert, direnv, openssh
  and git-bug. No grep, no sed: guest code that runs before a devShell is
  entered must not shell out to one.
