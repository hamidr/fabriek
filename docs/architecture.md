# Architecture, as built

What fabriek is on `main` as of 2026-09-14, read from the code rather than
from the decisions. Where an ADR's status and the code disagree, this file
says what the code does and names the ADR. The decisions are ADR-033
through ADR-044 and PRD-006; `docs/roadmap.md` says what of them is built
and what is not.

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
fabriek builds one virtual machine per factory to run it in (ADR-019).

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

**`fabriek`** (bash) is the launcher on the operator's host, `fabriek [-f
FACTORY] VERB [ARGS]` (ADR-047): `up`, `down`, `ps`, `check`, `ls`, `show`,
`enter` by hand, `stop`, `steer`, `log`, `file`, `console`, `board`, `watch`,
`send`, `mirror`. The factory is `-f`, else `FABRIEK_FACTORY`, else the one
registered. Every verb but the machine's own goes to the machine over ssh.

**`fabriek-container`** (bash) is the machine program: `role-enter`,
`role-worktree`, `factory-prepare`, and the operator's interventions
`task-file`, `role-stop`, `role-steer`, `factory-mirror`, `factory-send`,
`factory-watch`, `factory-roles`. It composes sessions and writes the
operator stream; it decides nothing and runs no loop.

**`factory/`** (TypeScript, one package, no runtime dependency) holds the
executor, the extension that is the loop, the decider, the relay and the
TUI. It is built by the flake with `tsc` and tested with node's own runner;
pi's types are linked in from the pi in the closure. `nix build .#factory`
runs its 136 scenarios.

**`catalogue/`** is what a role can be (ADR-042): one directory per
specialist (`PROMPT.md` and a `default.nix` naming its tools, its parents
and its skills as values) and one per skill (`SKILL.md` in the Agent Skills
format and a `default.nix` naming its tools). A repository may carry a
second one with the same layout, named by `catalogue` in its `fabriek.nix`.
A role names its specialists in `fabriek.nix` and nothing else; `command`
defaults to pi. A role may declare `replicas = N` (ADR-053): the shell
validator expands it into `<role>-1` to `<role>-N`, each the same
declaration, before anything else reads the file, so the build, the
machine and the executor see N roles and no `replicas`; a hand-declared
role under a replica's name is refused. `modules/catalogue.nix` reads both, flattens what a role
names once per name, parents first, and builds one derivation per role. A
specialist may declare language servers (`lsp`), unioned by id into the
role's `lsp.json` for the `pi-lsp` extension (`modules/pi-lsp/`, ADR-043),
and what a test is (`tests`: test files, source files, runner commands),
unioned into `tests.json` for the loop's test-first guard (ADR-044). The
`developer` specialist carries `codegraph` (`modules/codegraph/`,
ADR-049): the worktree is indexed by the machine program before it is
handed to the role, and the `pi-codegraph` extension
(`modules/pi-codegraph/`) in every role's pi spawns the binary from `PATH`
to answer `codegraph_explore` and its siblings. The tree is rooted in
`committer` (whoever works in a worktree: the reading kit and the commit
discipline, ADR-050); `developer` is the builder every language
specialist extends, and `architect`, `reviewer` and `manager` extend
`committer` directly. `manager` tunes the workflow through the decider's
policy, `docs/factory-guidance.md` and the repository's own catalogue,
and assigns nothing; at an `inspect` verdict stage after review it reads
each attempt's trace (ADR-051).

## The host

A NixOS host declares its factories with `services.fabriek`
(`modules/host.nix`, ADR-048): the operator's `config.toml` rendered to
`/etc/fabriek/config.toml`, read by the CLI when no personal file exists,
and `fabriek-<name>.service` for each factory with `autoStart`, running
`fabriek up` at boot and `down` at stop under `/var/lib/fabriek`. Every
other host keeps the file by hand.

## The machine

`fabriek up <factory>` writes a flake under the machine's directory whose
inputs are this fabriek and the worked repository, pinned by rev in a lock
that `--update` moves, plus `local.json` with the port, the key, both
systems, the operator's ceilings and which header carries which endpoint's
credential (`machine_flake` in `fabriek`). `lib.factory`
(`modules/factory.nix`) validates and clamps the declaration inside a
derivation by the same shell modules the CLI uses (`modules/machine-spec.sh`),
composes each role's specialists from the catalogues into one derivation
(`modules/catalogue.nix`, ADR-042) and realises it with the role's devShell
inputs into a profile, bakes the decider's policy file, and hands the spec
to `modules/vm.nix`. A bad declaration fails
the build with its own message; what the clamp changed rides in the spec and
is printed by `up`.

The machine (`modules/machine/default.nix` and `modules/machine/`):

- `bridge.nix`: `fabriek-<factory>` at 10.77.0.1/24, configured without
  carrier; the decider at .2, roles at .10 onward in declaration order;
  `/etc/fabriek/bridge.json` is the plan. A bridge-family nftables table
  drops a packet whose source is not its port's address, drops IPv6 and ARP
  claims, and drops cage to cage (ADR-037).
- `board.nix`: Forgejo on the bridge, on a dataset bounded by `recordQuota`,
  its tmpfiles rules re-run after the mount; a `forgejo` wrapper for the
  machine program (ADR-036).
- `bus.nix`: Valkey on the bridge, no persistence; `fabriek-bus-acl`
  runs `fabriek-container bus-acl`, whose rules (`modules/bus.sh`) make
  default-deny users from password files under the state directory, read
  and write patterns kept apart per role (ADR-033).
- `proxy.nix`: nginx with njs on the bridge, injecting the credential per
  allowed host, counting tokens per source address in memory, answering
  `/status`, refusing with 429 at `tokenCeiling` (ADR-037).
- `probes.nix`: bpftrace exec, exit and connect events, through
  `fabriek-container probes-publish` (`modules/probes.sh`), which names
  the role each uid belongs to by the uid primitive, to a capped `probes`
  stream, written as a user that can write nothing else (ADR-038).
- `floor.nix`: pi on every cage; one pi directory per role under
  `/etc/fabriek/roles/<role>/pi`, a store path carrying the loop, the
  `pi-lsp` and `pi-codegraph` extensions, a `models.json` pointing pi at
  the proxy, and from the role's profile the `APPEND_SYSTEM.md`, `skills/`
  and `lsp.json` of its specialists; the decider's loop under
  `/etc/fabriek/pi-decider`, one store path the same way (ADR-030,
  ADR-035, ADR-042, ADR-043, ADR-049). A session names its profile and
  its pi directory as store roots, so the cage sees their closure and
  nothing else of the store (nixcage ADR-014).
- `executor.nix`: the `fabriek-executor` unit, as root, restarted always.

Egress for the machine's own processes is still by uid (ADR-025's chain):
root and the proxy may leave. The clamped declaration is at
`/etc/fabriek/declaration.json`; the machine program reads it there and
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
hand) or `--no-agent` (supervised), the task bind if given, the signing binds, and for a supervised run the actor's part: the
role's own pi directory bound at `PI_CODING_AGENT_DIR` and `PI_AGENT_DIR`, the bus password
and forge token bound read-only, and the `FABRIEK_*` environment naming the
role, its capabilities, its specialists, the bus, the forge, the repository
and the proxy, and `--memory` and `--cpus` sized from the declaration's
resources over its concurrency, set on the cage's scope (nixcage ADR-012).
The cage is named after the role, a machine name of at most sixty-four
characters; its veth carries a hash of that name (nixcage ADR-013). A
person entering a role whose actor is running is put inside its cage with
`nixcage-container exec`, not beside it. The decider's session is the same
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

`guard.ts` is the test-first guard (ADR-044), the machine in
`models/tdd-guard.qnt`: from `tests.json` in the pi directory it
classifies every `write` and `edit` path as test, source or free and every
`bash` command as a test run or not; a source edit is refused before any
run, after a test edit without a run, and as a second edit after a passing
run without a run between; `report_outcome` with done is refused until
the last run after the last edit passed. A refusal is the tool's result
and a `guard_refused` event. A run's verdict is the bash tool's error
flag. Empty lists mean no guard.

## The executor

`factory/src/executor/core.ts` (ADR-034): reconciles on start by asking each
actor with an `assigning` row what it holds and resolving those rows from
the answers, never creating one; applies the six verbs after validating each
against the declaration and the board; writes `assigning` and the attempt
line (`thread.ts`: the stage and where the role's branch stood) before
sending, `assigned` on the ack; reads outcomes off the board, comments a
`trace:` of the attempt first (`trace.ts`, ADR-051: turns, tools,
commands, executables, skills and refusals cut from `events:<role>` and
`probes` between the actor's `task_started` and `task_ended` brackets),
then moves the stage label only when the role's branch has a commit
since the attempt began, unless the stage is declared `verdict`, closes
at the last stage, labels `blocked`, frees the role on failed; counts
attempts per stage; refuses an assignment when as many roles hold work
as `resources.concurrency` allows (ADR-055); stops routing at ninety
percent of the ceiling. It reads the control streams from where they are before it
starts the sessions, so no ready is missed. `main.ts` connects as the executor's bus
user, starts every role's session and the decider's through the machine
program, reads `control:*`, `commands` and `operator`, checks outcomes every
ten seconds, and publishes the board and the spend, named by role from the
plan, to `events:executor`.
`mirror` fetches `main` from the forge, writes the issues as
`refs/fabriek/record`, and pushes both to origin. `factory-prepare` reads
it back on a machine whose board is empty (`fabriek_forge_restore_record`):
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
`relay/fixtures.json` being the contract; `fabriek watch` carries
it over ssh. When the bus goes away the relay waits, connects again and
reads on from the last id it printed (`relay/tail.ts`). The TUI
(`factory/src/tui/`) folds those lines into one state and renders it in
panes: the roles with one selected (`j`/`k`), the board by stage, the
factory's activity (commands and findings in bus-id order), and the
selected role's own stream, its turns, tools, words and refusals in the
operator's terms. It writes through the CLI (`tui/cli.ts`): file, retry,
block, mirror, and steer, stop and push aimed at the selected role. The
watch asks from `0-0`, so
what the bus still holds is replayed and the board, which reaches the TUI
only as the executor's periodic event, is on screen at open. A watch that
ends is started again after a pause and the picture begins over
(`tui/watch.ts`). Merging is a click in
Forgejo's UI; nothing merges by verb. `fabriek board` tunnels a
local port to that UI over the factory's own ssh and prints the URL with
a password the machine set fresh on the operator's account
(`factory-board`), since the account was made with one nothing kept.

## The invariants

1. The executor is uncaged and content-blind; the decider is caged and reads
   everything. Nothing a role or the decider writes reaches a command line:
   titles and bodies are files, commands are typed JSON on a stream.
2. A cage holds no credential that reaches off the machine, and no route.
3. A role session's cage is composed of nixcage flags and nothing else.
4. What a role can run is what its specialists declared, built into the
   machine: tools, language servers and the runner the guard trusts come
   from the catalogue and the repository's own, never from anything found
   in the tree or installed in a home (ADR-031, ADR-042, ADR-043).

## Tests

```
nix develop --command shellcheck -x fabriek fabriek-container modules/*.sh
nix develop --command bats --recursive tests/       # 376 scenarios, minutes
nix build .#factory                                  # 136 scenarios
quint run models/vm-lifecycle.qnt --invariant=allInvariants --max-steps=60
quint run models/tdd-guard.qnt --invariant=allInvariants --max-steps=40 --max-samples=10000
nix develop --command tests/system/journey.sh        # the factory on this host
FABRIEK_PROOF_DIR=... tests/manual/isolation.sh    # needs a machine
FABRIEK_PROOF_DIR=... tests/manual/parity.sh       # needs a machine
FABRIEK_PROOF_DIR=... tests/manual/specialist.sh   # needs a machine
```

`tests/command/catalogue.bats` evaluates and builds `lib.catalogue` for
real over the shipped catalogue and one each scenario writes: the flattening,
every refusal, and what a built role carries (`bin/`, `APPEND_SYSTEM.md`,
`skills/`, `lsp.json`, `tests.json`). `factory_flake.bats` and
`machine_services.bats` evaluate `lib.factory` on fixture repositories.

`tests/system/journey.sh` runs the factory as a system with no cage and no
model: Valkey and a forge on localhost, `factory-prepare` and `bus-acl` on
them, the executor with `FABRIEK_SESSION_COMMAND` naming a session that
runs `fabriek-fake-actor` or `fabriek-fake-decider` where a cage would
run pi. The scripted actor is the extension's own actor, bus and board
(`extension/bind.ts`) driven by a script; the scripted decider is the
decider's own binding (`decider/bind.ts`) judged by `fake-decider/policy.ts`.
Every command still passes the core's gate and the executor's. What the
journey proves is everything but the model and the cage; what needs a
machine is the cage, the bridge, the proxy's count and pi.

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
  Everything after the assignment is proved on this host by
  `tests/system/journey.sh` with scripted actors, on Gitea on a Mac.
- Which model a session starts on is the operator's, per endpoint in
  their config (`[models]`), with a table in `modules/machine/floor.nix`
  standing when they name none; a declaration cannot name one.
- A cage has no network, and sbt, Maven, pnpm and Metals fetch dependencies
  over one. A language specialist works only when the project's devShell
  carries the cache; otherwise the first build is a blocked outcome. No
  per-factory artifact cache exists.
- The guard's verdict is pi's bash error flag, not an exit code; `sbt`
  counts any invocation as a run because its verbs sit inside one quoted
  argument. `tests/manual/specialist.sh` has not run on a machine.
