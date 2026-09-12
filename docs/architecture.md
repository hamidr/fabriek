# Architecture, as built

What cageworks is at commit `4aed0f4` (2026-09-12), read from the code rather
than from the decisions. Where an ADR's status and the code disagree, this
file says what the code does and names the ADR. `REDESIGN-LOG.md` at the
repository root describes a design that is agreed and not built; nothing here
comes from it.

This file carries no docmeta frontmatter on purpose: it is not a decision and
`docmeta-tracker` should not index it. Regenerate it by hand when the
architecture changes, and say which commit it describes.

## What it is

A factory is one git repository worked by a set of declared roles at the same
time, each in a cage of its own. A role is a worker, not a project: it has a
permanent uid, a permanent worktree, a home and a signing key (ADR-010,
ADR-009). The repository declares its own factory (ADR-020), the operator
keeps one file saying what a factory may cost on this host, and cageworks
builds one virtual machine per factory to run it in (ADR-019).

Cages are nixcage's. cageworks holds only what exists because several named
workers share one repository: roles, capabilities, tasks, workflows, stage
policies, the record, integration and the supervisor (ADR-018).

## The boundary with nixcage

Three primitives, and nothing else, cross it:

| Primitive | Used for |
| --- | --- |
| `nixcage-container enter [flags] <name> <project> [cmd]` | every role session |
| `nixcage-container uid <principal> [subject]` | a role's uid and its agent's, allocated once |
| `nixcage-container storage ensure <path> <uid> [quota]` | a role's worktree, owned and bounded |

`tests/command/seam.bats` stubs `nixcage-container` on `PATH`, records the
argv a role session produces and asserts the whole line. Anything cageworks
needs that these cannot express is an interface change in nixcage first.

`nixcage exec` is no longer used. Since PRD-004 phase 3 the operator's CLI
reaches the guest over ssh with the machine's own key and forwarded port, as
`root@localhost`, with the argv NUL-framed through `xargs -0` so nothing a
declaration wrote is re-split.

## Two programs

Both are bash, dispatching from `main()` at the bottom to `cmd_*` handlers.
There is no build step. Shared logic lives in `modules/*.sh`, sourced by
store path, so `shellcheck` reads it and `bats` sources it.

**`cageworks`** runs on the operator's host. Verbs: `up`, `down`, `vm status`,
`role`, `task file|list|show|thread|run|answer`, `factory
status|sync|resume|reports|integrate`. Every role, task and factory verb is
forwarded to the guest over ssh; the CLI knows a machine's key, port and disk
directory and nothing about where the cages are. For `role` and the first
`task file` it also reads the origin URL off the operator's checkout named in
`config.toml` and passes it as `--repository`, because a machine cannot clone
a path on the operator's host.

**`cageworks-container`** runs on the machine the cages are on. Verbs:
`role-enter`, `role-worktree`, `task-file|list|show|thread|run|answer`,
`factory-sync|integrate|resume|reports|status`. It calls `nixcage-container`
as a subprocess. It is not offered as a package on darwin, because it needs
`setfacl`.

## The machine

`cageworks up <factory>` builds a NixOS microVM from `modules/vm.nix`
(nixpkgs, microvm.nix, nixcage's host module, `modules/vm-guest.nix` and the
guest program built from this repository) and starts it detached in a session
of its own. The machine's directory on the operator's host holds its disk,
its keypair, its forwarded port, its spec and its console log
(`modules/machine.sh`). One machine per factory; no factory can read
another's way in because the directories are separate.

Inside the guest (`modules/vm-guest.nix`):

- a ZFS pool named `cageworks-<factory>`, found by disk serial, so a disk
  attached to the wrong machine refuses to import (ADR-017, ADR-019);
- nixcage's state directory `/var/lib/nixcage` on that pool, unchanged by
  the split (ADR-017);
- egress dropped by nftables for every uid but the proxy's, and the proxy
  (nginx) holding the model credential and injecting it per host on the
  factory's `egress` allowlist (ADR-025). The credential is piped in over
  ssh after boot and read from stdin, never argv;
- a journald namespace per factory with its own dataset and quota
  (`journalQuota`), the proxy's metadata-only access log, and bpftrace
  probes on `sched_process_exec`, `sched_process_exit` and socket connect
  (ADR-027);
- sshd on the forwarded port, reached with the machine's own key.

`tests/manual/stop-and-start.sh` and `tests/manual/egress.sh` are the checks
that need a real machine.

## Declaration and operator configuration

A repository declares its factory as the `cageworks` output of its own flake,
read from the commit and not the working tree (`modules/repo-declaration.sh`,
one `nix eval`). The schema is closed: an unknown key is refused by name
(`modules/schema.sh`). `examples/factory-project/cageworks.nix` is the
reference shape: `name`, `roles.<r>.{command,provides,shell}`,
`workflows.<w>.{stages,budget,consults}`, `resources`.

A role's `command` is argv, one word per element, never re-split. Its
`shell` names a devShell of the same flake, which is that role's toolchain
(ADR-016). Names that reach a path, a ref, a uid or a flake reference are
validated where declared (`modules/names.sh`).

The operator's file is `~/.config/cageworks/config.toml`: `[caps]` ceilings,
`[factories.<name>] path`, and credentials keyed by host
(`modules/operator-config.sh`). `modules/resources.sh` clamps every declared
resource to the ceiling and reports which field it clamped. `egress` is a
permission: it meets its ceiling by intersection and an absent ceiling as an
empty one (ADR-025).

## A role

A role is a nixcage principal with two uids: the base of the block its cage
maps, and the agent's subject inside it (ADR-028). Both are asked for once
and never reissued. Its worktree at `worktrees/<factory>/<role>` is a git
worktree of the factory's clone at `factories/<factory>`, asked for through
`storage ensure` with `roleQuota`, and its uid is granted exactly the git
directories it needs by ACL (`modules/role-worktree.sh`, ADR-010). The clone
is of the repository's own origin, not the operator's checkout (ADR-032;
`modules/factory-clone.sh`); the origin URL is read from that checkout and
handed over.

A session is one `nixcage-container enter` line composed in `cmd_role_enter`
in a fixed order: `--uid`, `--user`, `--subject`, `--home` under the state
directory, `--shell` if declared, then either `--auth-sock` (an operator
entering by hand, forwarding their own agent) or `--no-agent` (a supervised
run), the journal binds, the guidance bind (`modules/role-guidance.md`,
read-only), the task directory bind and `CAGEWORKS_TASK`, and the signing
binds. A
supervised run gets a key of its own so it can sign but cannot push, pull a
private repository or authenticate anywhere (ADR-009; `modules/signing.sh`).
`--auth-sock` and `--signing-key` together are refused.

The agent a role runs is the repository's business; `pi --mode rpc` is the
one the example declares and ADR-029 (proposed) names.

## Work

A task is a directory under the guest's task root, one file per field,
written by rename (`modules/task-store.sh`, ADR-014). States: `proposed`,
`ready`, `running`, `blocked`, `awaiting-review`, `done`, `failed`,
`cancelled`. Scalars (`state attempts role workflow stage parent seq item
gate`) share one file rewritten whole.

A workflow is a list of stages. A stage names a capability (`needs`), lists
the fields a task must carry before it is taken (`ready`, enforced as
presence), states what finishing means (`done`, prose handed to the role and
never checked), and may name a gate (ADR-015; `modules/workflow-config.sh`).
`consults` says who may ask whom. `budget.runs` bounds the workflow.

`cageworks task file <factory> <workflow>` creates a task at the first stage
and opens its item in the record. `cageworks task run <factory> <id>` is one
run, typed by a person:

1. Refuse if the factory is halted.
2. Resolve the taker: the role already on the task, else the first idle role
   in declaration order providing the stage's capability. The task then
   sticks to that role, because its branch is in that role's namespace.
3. Claim a concurrency slot (`concurrency`, machine-wide) and spend one run
   of the workflow's budget (`modules/caps.sh`). Both are files, because the
   supervisor is not a daemon.
4. Count an attempt against `taskAttempts`.
5. Write the brief into a run directory: task, role, acceptance, the stage's
   `done`, the body, the factory's own guidance from the clone, the record
   so far and what is new since this role last looked. The brief is
   read-only to the role; `outcome`, `mentions` and `comments/` are owned
   by the role's uid.
6. `role-enter` with `--task-dir` and `--signing-key`, under
   `runTimeoutSeconds`.
7. Ingest what the role wrote into the record, as that role. Settle on the
   outcome, or fail the task back to `ready` while attempts remain.
8. At a gated stage stop in `awaiting-review` for `cageworks task answer`.
   Otherwise advance: open a child task at the next stage, seeded with the
   parent's thread, or finish the pipeline.

Nothing a role writes reaches a command line: brief, outcome, mentions and
comments are files.

## The record

git-bug inside the factory's clone (ADR-013, ADR-022; `modules/record.sh`).
The supervisor is the only writer and acts as each role in turn, one git-bug
identity per role. No git-bug call is trusted bare: each is confirmed by
reading back what landed, within a bound (ADR-024). Mentions are labels.
`cageworks task thread` reads it; `cageworks factory reports` lists what
needs a person.

ADR-023 (superseded) and ADR-024 (accepted) describe a leased claim by which
a role would take its own work. No code implements a claim; PRD-005 is
proposed and not started.

## Integration

`cageworks factory integrate <factory> <commit>` fast-forwards the shared
branch `main` in the clone to that commit, refusing anything else, then
syncs. `cageworks factory sync` pushes the clone's `main` to the operator's
repository, and halts the factory instead when the two histories have
diverged, until `cageworks factory resume` (`modules/integrate.sh`,
ADR-011). Deciding what to merge is content and
stays in a cage.

## Console and observation

`cageworks role --pane` runs a session in a herdr pane and reports state to
herdr's socket. ADR-026 (proposed) replaces this with a unix socket per role
relayed by the loop and removes herdr; neither is built.

Three sources record a factory (ADR-027): the journald namespace stamped
with `_UID` off `SO_PEERCRED`, which a role can write and cannot edit
(`modules/journal.sh`); the proxy's access log; and the kernel probes. The
ledger is queried by exporting NDJSON.

## State on the guest

Under `/var/lib/nixcage` (`CAGEWORKS_STATE` overrides it for the suite):
`factories/<factory>` (the clone), `worktrees/<factory>/<role>`,
`homes/<factory>-<role>`, `tasks/<factory>/<id>`, `runs/<factory>/<id>`
(brief, outcome, mentions, comments, seed), `seen/<factory>/<role>`,
`halted/<factory>`, `keys/<role>` and `keys/allowed_signers`.

## The invariants

1. The supervisor is uncaged and content-blind. It reads declarations and
   metadata, never a task body, a comment or a document.
2. Nothing a role writes ever reaches a command line.
3. A role session's cage is composed of nixcage flags and nothing else.

## Tests and models

```
nix develop --command shellcheck -x cageworks cageworks-container modules/*.sh
nix develop --command bats --recursive tests/
docmeta-check docs && docmeta-tracker docs
alloy6 exec models/factory-structure.als
quint run models/factory-lifecycle.qnt --invariant=allInvariants --max-steps=60
```

`tests/unit/` sources a module and calls it. `tests/command/` drives a
program with its dependency stubbed on `PATH`. `models/` holds
`factory-structure.als`, `egress-authority.als`, `factory-lifecycle.qnt`,
`vm-lifecycle.qnt`, `task-claim.qnt` and `ledger-tap.qnt`.

## Not built, and status drift

- Nothing dispatches. A person types every `task run`.
- PRD-004 phases 4 and 5 are open; phases 1 to 3 are done.
- ADR-021 (accepted): no loop exists. ADR-024 (accepted): no claim exists.
- ADR-026, ADR-029, ADR-031 (proposed): none built. ADR-032 (proposed) is
  what the clone does; its status lags the code.
- herdr is still in `cageworks` although ADR-026 point 8 removes it.
