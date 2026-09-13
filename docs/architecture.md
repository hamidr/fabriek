# Architecture, as built

What cageworks is on the `redesign` branch as of 2026-09-12, read from the
code rather than from the decisions. Where an ADR's status and the code
disagree, this file says what the code does and names the ADR. The decisions
are ADR-033 through ADR-040 and PRD-006; `docs/roadmap.md` says what of them
is built and what is not.

This file carries no docmeta frontmatter on purpose: it is not a decision and
`docmeta-tracker` should not index it. Regenerate it by hand when the
architecture changes, and say which commit it describes.

## What it is

A factory is one git repository worked by a set of declared roles at the same
time, each in a cage of its own, on a machine of its own. A role is a worker:
a permanent uid, a permanent home and dataset, a signing key, a forge
account with an issue-scoped token, a bus user (ADR-010, ADR-009, ADR-036,
ADR-033). The repository declares its own factory (ADR-020, ADR-040), the
operator keeps one file saying what a factory may cost on this host, and
cageworks builds one virtual machine per factory to run it in (ADR-019).

Nothing a cage does is trusted. A machine-provided decider judges, an uncaged
executor acts, the forge on the machine is the board and the record, the bus
carries pointers and events, the proxy holds the model credential and counts
spend, and a cage has one address on a bridge with no route off the machine.

## The boundary with nixcage

Three primitives, and nothing else, cross it:

| Primitive | Used for |
| --- | --- |
| `nixcage-container enter [flags] <name> <project> [cmd]` | every role session |
| `nixcage-container uid <principal>` | a role's uid, allocated once |
| `nixcage-container storage ensure <path> <uid> [quota]` | a role's worktree and the record's dataset |

Two options on `enter` were added upstream for this design (nixcage
ADR-011): `--network <bridge>:<addr>/<prefix>` gives a cage one veth on the
factory's bridge and no other interface, or `--network ns:<path>` joins the
network namespace of a cage already running; and `--no-nix-daemon` leaves
the daemon socket unbound and runs the command in the base userland with
`NIXCAGE_PATH_PREFIX` on the front of `PATH`.

`tests/command/seam.bats` stubs `nixcage-container` on `PATH`, records the
argv a role session produces and asserts the whole line. The operator's CLI
reaches the machine over ssh with the machine's own key and forwarded port,
argv NUL-framed through `xargs -0`.

## Two programs and one package

**`cageworks`** (bash) is the launcher on the operator's host: `up`, `down`,
`vm status`, `role <factory> <role>` to enter by hand, `role stop`, `role
steer`, `task file`, `factory mirror`, `factory watch`, `factory send`,
`factory console`. Every verb but the machine's own goes to the guest over
ssh.

**`cageworks-container`** (bash) is the guest program: `role-enter`,
`role-worktree`, `factory-prepare`, and the operator's interventions
`task-file`, `role-stop`, `role-steer`, `factory-mirror`, `factory-send`,
`factory-watch`, `factory-roles`. It composes sessions and writes the
operator stream; it decides nothing and runs no loop.

**`factory/`** (TypeScript, one package, no runtime dependency) holds the
executor, the extension that is the loop, the decider, the relay and the
TUI. It is built by the flake with `tsc` and tested with node's own runner;
pi's types are linked in from the pi in the closure. `nix build .#factory`
runs its 97 scenarios.

## The machine

`cageworks up <factory>` writes a flake under the machine's directory whose
inputs are this cageworks and the worked repository, pinned by rev in a lock
that `--update` moves, plus `local.json` with the port, the key, both
systems, the operator's ceilings and which header carries which endpoint's
credential (`machine_flake` in `cageworks`). `lib.factory`
(`modules/factory.nix`) validates and clamps the declaration inside a
derivation by the same shell modules the CLI uses (`modules/machine-spec.sh`),
realises each role's devShell inputs into a profile, bakes the decider's
policy file, and hands the spec to `modules/vm.nix`. A bad declaration fails
the build with its own message; what the clamp changed rides in the spec and
is printed by `up`.

The guest (`modules/vm-guest.nix` and `modules/guest/`):

- `bridge.nix`: `cageworks-<factory>` at 10.77.0.1/24, configured without
  carrier; the decider at .2, roles at .10 onward in declaration order;
  `/etc/cageworks/bridge.json` is the plan. A bridge-family nftables table
  drops a packet whose source is not its port's address, drops IPv6 and ARP
  claims, and drops cage to cage (ADR-037).
- `board.nix`: Forgejo on the bridge, on a dataset bounded by `recordQuota`,
  its tmpfiles rules re-run after the mount; a `forgejo` wrapper for the
  guest program (ADR-036).
- `bus.nix`: Valkey on the bridge, no persistence; `cageworks-bus-acl`
  applies default-deny users from password files under the state
  directory, read and write patterns kept apart per role (ADR-033).
- `proxy.nix`: nginx with njs on the bridge, injecting the credential per
  allowed host, counting tokens per source address in memory, answering
  `/status`, refusing with 429 at `tokenCeiling` (ADR-037).
- `probes.nix`: bpftrace exec, exit and connect events to a capped `probes`
  stream, written as a user that can write nothing else (ADR-038).
- `floor.nix`: pi on every cage, the extension and the decider's loop under
  `/etc/cageworks/pi` and `/etc/cageworks/pi-decider` with a `models.json`
  pointing pi at the proxy (ADR-030, ADR-035).
- `executor.nix`: the `cageworks-executor` unit, as root, restarted always.

Egress for the machine's own processes is still by uid (ADR-025's chain):
root and the proxy may leave. The clamped declaration is at
`/etc/cageworks/declaration.json`; the guest program reads it there and
evaluates nothing.

## Prepare

After boot and the credential, `up` runs `factory-prepare` on the machine
(`modules/forge.sh`, `modules/bus.sh`). Once and then confirmed: a password
per bus user and the ACL applied; the operator's account and token; the
repository `operator/<factory>`; per role an account with read on it, a
`write:issue` token and a pinned `memory` issue opened as the role; for the
decider an account and a `read:issue` token; a label per stage's capability
plus `blocked` and `memory`. Tokens and passwords are files under the state
directory, owned by the role's uid, and reach the API as a header read from
a file.

## A role session

`cmd_role_enter` composes one `nixcage-container enter` line in a fixed
order, asserted whole by `seam.bats`: `--uid`, `--user`, `--home`,
`--network` (the plan's placement for a supervised run; for a person, the
running actor's namespace when there is one, found through the nspawn
that holds it, so a hand beside an actor takes no second veth),
`--no-nix-daemon`, the profile on
`NIXCAGE_PATH_PREFIX` when the build realised one, then `--auth-sock` (by
hand) or `--no-agent` (supervised), the guidance bind, the task bind if
given, the signing binds, and for a supervised run the actor's part: pi's
directory bound at `PI_CODING_AGENT_DIR`, the bus password and forge token
bound read-only, and the `CAGEWORKS_*` environment naming the role, its
capabilities, the bus, the forge, the repository and the proxy. The cage is
named after the role, because nspawn names its veth after the cage, and a
role name is at most twelve characters. The decider's session is the same
line with the machine's own loop, the declaration and the policy bound in,
and `pi --mode rpc` as its command.

## The loop

`factory/src/extension/actor.ts` is the actor (ADR-033, ADR-035) against
three interfaces: the bus, the board, the agent. At start it reads its
memory issue and, unless the board says it is blocked, announces `ready`
with its capabilities on `control:<role>`. An `assignment` on
`mailbox:<role>` is acked and turned into a prompt from the issue, its
thread and the memory. The agent works, and calls `report_outcome` (done,
blocked or failed with a summary) and `update_memory`; on `agent_settled`
the outcome is commented under the role's token, with a note when no commit
is on the branch, and the process ends for done or failed so the next one is
a fresh session (ADR-035 point 4 as amended). Blocked keeps the process
alive and silent. `steer` and `abort` reach the running turn; `reconcile` is
answered with what is held; turn and tool events go to `events:<role>`,
findings to `findings:<role>`.

## The executor

`factory/src/executor/core.ts` (ADR-034): reconciles on start by asking each
actor with an `assigning` row what it holds and resolving those rows from
the answers, never creating one; applies the six verbs after validating each
against the declaration and the board; writes `assigning` and the attempt
comment before sending, `assigned` on the ack; reads outcomes off the board
and moves the stage label only when a commit is on the role's branch, closes
at the last stage, labels `blocked`, frees the role on failed; stops routing
at ninety percent of the ceiling. `main.ts` connects as the executor's bus
user, starts every role's session and the decider's through the guest
program, reads `control:*`, `commands` and `operator`, checks outcomes every
ten seconds, and publishes the board and the spend to `events:executor`.
`mirror` fetches `main` from the forge, writes the issues as
`refs/cageworks/record`, and pushes both to origin. `factory-prepare` reads
it back on a machine whose board is empty (`cageworks_forge_restore_record`):
each issue opened again in number order with its labels and state, memory
issues excepted, a label the declaration lost named and dropped. The export
carries no comments, so neither does the restored board.

## The decider

`factory/src/decider/core.ts` (ADR-034): the prompt is the machine's rules,
the declaration as data, the board with the ready set, and the policy file,
each labelled. Tool calls `assign`, `retry`, `block`, `file`, `push`, `stop`
and `wait` pass the vocabulary and the declaration before one entry lands on
`commands`; the executor validates again against the board. It thinks every
thirty seconds and whenever an actor says something.

## The operator

The relay (`factory/src/relay/`) prints every stream as JSON lines,
`relay/fixtures.json` being the contract; `cageworks factory watch` carries
it over ssh. When the bus goes away the relay waits, connects again and
reads on from the last id it printed (`relay/tail.ts`). The TUI
(`factory/src/tui/`) folds those lines into one state, renders roles,
board, commands, findings and spend, and writes through the CLI: file,
steer, stop, retry, block, push, mirror. The watch asks from `0-0`, so
what the bus still holds is replayed and the board, which reaches the TUI
only as the executor's periodic event, is on screen at open. A watch that
ends is started again after a pause and the picture begins over
(`tui/watch.ts`). Merging is a click in
Forgejo's UI; nothing merges by verb.

## The invariants

1. The executor is uncaged and content-blind; the decider is caged and reads
   everything. Nothing a role or the decider writes reaches a command line:
   titles and bodies are files, commands are typed JSON on a stream.
2. A cage holds no credential that reaches off the machine, and no route.
3. A role session's cage is composed of nixcage flags and nothing else.

## Tests

```
nix develop --command shellcheck -x cageworks cageworks-container modules/*.sh
nix develop --command bats --recursive tests/       # 310 scenarios, minutes
nix build .#factory                                  # 97 scenarios
quint run models/vm-lifecycle.qnt --invariant=allInvariants --max-steps=60
CAGEWORKS_PROOF_DIR=... tests/manual/isolation.sh    # needs a machine
CAGEWORKS_PROOF_DIR=... tests/manual/parity.sh       # needs a machine
```

## Not built, and known gaps

- The record's comments: the export is the issue list, so a restored board
  has the issues and not what was said under them.
- The TUI's memory view and pull request list, which are the forge's and
  not on the bus.
- The spend count lives in the proxy's memory and starts at zero when it
  restarts.
- The machine's erofs store image build is flaky on this host's linux
  builder; a retry has always succeeded.
- `tests/manual/parity.sh` passes up to the first assignment and is gated
  there on a credential the endpoint accepts; see `docs/roadmap.md` 5.1.
- Which model a session starts on is the machine's choice, a table in
  `modules/guest/floor.nix`; a declaration cannot name one.
