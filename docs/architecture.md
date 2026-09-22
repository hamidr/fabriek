# Architecture, as built

What fabriek is on `main` as of 2026-09-21, read from the code rather than
from the decisions. Where an ADR's status and the code disagree, this file
says what the code does and names the ADR. The decisions are ADR-033
through ADR-044, ADR-067 and PRD-006; `docs/roadmap.md` says what of them
is built and what is not.

This file carries no docmeta frontmatter on purpose: it is not a decision and
`docmeta-tracker` should not index it. Regenerate it by hand when the
architecture changes, and say which commit it describes.

## What it is

A factory is one git repository worked by a set of declared roles at the same
time, each in a cage of its own, on a NixOS host that runs several
factories. A role is a worker: a permanent uid, a permanent home and
dataset, a signing key, a forge account with an issue-scoped token, a bus
user (ADR-010, ADR-009, ADR-036, ADR-033). The repository declares its own
factory (ADR-020, ADR-058), the operator declares the factory on the host
and says what it may cost there, and fabriek gives it a set of service
instances of its own and a cage per role (ADR-067). A role that must not
share the host's kernel asks for `substrate = "microvm"` and nixcage runs
its cage in a kernel of its own (nixcage ADR-019).

Nothing a cage does is trusted. A host-provided decider judges, an uncaged
executor acts, the host's forge holds each factory's board and record
under an account of its own, its bus
carries pointers and events, one proxy holds the model credentials and
counts each factory's spend, and a cage has one address on its factory's
bridge with no route off the host.

## The boundary with nixcage

Six primitives, and nothing else, cross it:

| Primitive | Used for |
| --- | --- |
| `nixcage-container enter [flags] <name> <project> [cmd]` | every role session, `--substrate nspawn\|microvm` per role |
| `nixcage-container uid <principal>` | a role's uid, allocated once; the principal is `<factory>-<role>` |
| `nixcage-container storage ensure <path> <uid> [quota]` | a factory's state, a role's worktree and the forge's dataset |
| `nixcage-container status <name>`, `stop <name>` | whether a cage runs and its scope; `stop -k` |
| `nixcage-container exec <name> [-- cmd]` | a person entering a role whose actor runs |
| `nixcage-container rm <name>` | a role whose declared substrate changed, so the next enter may choose again |

Two options on `enter` were added upstream for this design (nixcage
ADR-011): `--network <bridge>:<addr>/<prefix>` gives a cage one veth on the
factory's bridge and no other interface, or `--network ns:<path>` joins the
network namespace of a cage already running; and `--no-nix-daemon` leaves
the daemon socket unbound and runs the command in the base userland with
`NIXCAGE_PATH_PREFIX` on the front of `PATH`.

`tests/command/seam.bats` stubs `nixcage-container` on `PATH`, records the
argv a role session produces and asserts the whole line. The operator's CLI
reaches the machine program as root on this host through `sudo`, for that
one program and the `fabriek` group, with the factory named in the
environment and argv passed as argv (ADR-067).

## Two programs and one package

**`fabriek`** (bash) is the launcher, `fabriek [-f FACTORY] VERB [ARGS]`
(ADR-047): `up`, `down`, `fetch`, `ps`, `check`, `ls`, `show`, `enter` by
hand, `stop`, `steer`, `log`, `file`, `board`, `watch`, `send`, `mirror`.
The factory is `-f`, else `FABRIEK_FACTORY`, else the one declared. Every
verb but its own reading of the operator's file goes to the machine
program through `sudo`; what it does itself is the operator's side of the
checkout (below).

**`fabriek-container`** (bash) is the machine program, on the host as
root: `factory-up`, `factory-down`, `factory-status`, `role-enter`,
`role-worktree`, `factory-render`, `factory-prepare`, and the operator's
interventions `task-file`, `role-stop`, `role-steer`, `factory-mirror`,
`factory-send`, `factory-watch`, `factory-roles`. The factory it acts for
is `FABRIEK_FACTORY`, whose facts it loads from
`/etc/fabriek/factories/<name>.env`, so one program serves every factory
on the host. It composes sessions and writes the operator stream; it
decides nothing and runs no loop.

**`factory/`** (TypeScript, one package, no runtime dependency) holds the
executor, the extension that is the loop, the decider, the relay and the
TUI. It is built by the flake with `tsc` and tested with node's own runner;
pi's types are linked in from the pi in the closure. `nix build .#factory`
runs its 136 scenarios.

**`catalogue/`** is what a role can be (ADR-042): one directory per
specialist (`PROMPT.md` and a `default.nix` naming its tools, its parents
and its skills as values) and one per skill (`SKILL.md` in the Agent Skills
format and a `default.nix` naming its tools). A directory is a catalogue
when its own `default.nix` calls `fabriek.catalogue { version = 1; }`, the
constructor `modules/catalogue.nix` hands it (ADR-066); one without it, or
at another version, is refused by name rather than read as empty. The
shipped one is the base: a specialist declared anywhere else reaches one
of its specialists through `extends` or is refused naming `committer`. A
repository may carry a second one with the same layout, named by
`catalogue` in its `fabriek.toml`.
A role names its specialists in `fabriek.toml` and nothing else; `command`
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
(`modules/host.nix`, ADR-048, ADR-067): the operator's `config.toml`
rendered to `/etc/fabriek/config.toml`, read by the CLI when no personal
file exists; `services.fabriek.factories.<name>` with the checkout's path
and `autoStart`; and from those, per factory, everything that was a
machine's:

- A bridge `fb-<idx>` at `10.77.<idx>.1/24` (`modules/host/bridge.nix`),
  `<idx>` the factory's position among the declared names, configured
  without carrier so its address is there before the first cage, and named
  to the host's firewall with the three ports a cage may reach. A forward
  chain drops anything from or to an `fb-*` interface, so a cage has no
  route off the host whatever else set `ip_forward` (`modules/host/proxy.nix`).
- A facts file `/etc/fabriek/factories/<name>.env`: the bridge, the
  address, the ports, `FABRIEK_STATE` (`/var/lib/nixcage/fabriek/<name>`),
  `FABRIEK_ETC` (`/var/lib/fabriek/<name>`), `FABRIEK_RUN`
  (`/run/fabriek/<name>`), the floor, and what render evaluates a profile
  from. The units load it; the CLI hands it over by naming the factory.
- A slice `fabriek-<name>.slice` and under it: `fabriek-<name>-state`
  (the factory's dataset through the storage primitive), `-bus` (Valkey on
  the bridge, no persistence), `-bus-acl` (the machine program's rules
  from the password files), `-egress-credentials` (the proxy's header
  lines for this factory), and `-executor`, waiting on
  `/run/fabriek/<name>/prepared` (`modules/host/state.nix`, `bus.nix`,
  `executor.nix`).
- Outside every slice, one board for the host (ADR-068):
  `fabriek-forge-storage` (its dataset at `/var/lib/nixcage/fabriek-forge`
  through the storage primitive, bounded by the host's `recordQuota`) and
  `fabriek-forge` (Forgejo as a unit of ours, since the NixOS module is
  one instance per host: `app.ini` generated, secrets made in that dataset
  on first start, read back through `environment-to-ini`). It binds every
  address and the firewall opens its port on the bridges and loopback
  alone (`modules/host/board.nix`).
- With `autoStart`, `fabriek-<name>.service`, which runs `factory-up` at
  boot and `factory-down` at stop in the slice.

Once on the host: nginx with a server per factory on its bridge, an njs
dictionary and a ceiling per factory, the locations render writes under
the factory's directory (`modules/host/proxy.nix`, `spend.js`); one
bpftrace reader publishing each kernel line to the bus of the factory
whose cage the cgroup is (`modules/host/probes.nix`, `modules/probes.sh`);
the floor, one store path every role's pi directory is composed from
(`modules/host/floor.nix`); a sudoers rule for `fabriek-container` and the
`fabriek` group; and `nixcage.nixosModules.host` beside it all, with
`microvm.enable` where any role wants a kernel.

## Up

`fabriek up <name>` runs `fabriek-container factory-up` under a flock on
the factory's directory held for the whole run, so the boot unit and a
hand never render at once and the pin never moves under an up in flight
(`models/factory-lifecycle.qnt`, ADR-067). It writes the credential
`fabriek.toml` under the factory's directory (`modules/credential.sh`:
the operator's config projected for the factory plus `[pin]` at the
checkout's HEAD, kept on a second up and moved by `-u`), starts the
factory's state unit, clones the checkout as a local path with its objects
hardlinked (`modules/factory-clone.sh`), renders
(`factory-render`: the declaration read from the clone at the pin,
clamped against the caps in `modules/machine-spec.sh`, and under the
factory's directory `declaration.json`, `rev`, `notes.json`,
`bridge.json`, `proxy/endpoints.conf`, `endpoints.json`, `model.json`,
`decider-policy.md`, `pi-decider/`, and per role `roles/<role>/profile`,
built by the host's daemon from the repository at the pin under
`--restrict-eval`, and `roles/<role>/pi`; then `profiles.json`), removes
the cage of any role whose declared substrate changed, starts the rest
of the factory's units (after render, since the bus's ACL unit applies
the plan it finds), files each model
credential the rendered factory reaches under the factory's state for the
proxy's user (`modules/factory-up.sh`), prepares, and writes the mark
last. What the clamp changed is printed, and a substrate raised to the
operator's floor is among it.

Then the CLI does the operator's side (ADR-067 point 5): a remote
`fabriek-<name>` at the factory's clone in the checkout, fetched as the
operator into `refs/heads/fabriek/<name>/*` and
`refs/fabriek/<name>/*`, so the factory's branches, merged `main` and
the record are seen with `git branch` and `git log` in the operator's own
repository. `ps`, `watch`, `board` and `mirror` fetch again; `fetch` does
only that. Nothing in the factory writes the checkout: the executor's
`mirror` brings `main` and `refs/fabriek/record` into the clone and pushes
nowhere. `down` is refused while a role's cage runs, then stops the
executor, removes the mark and stops the units; the datasets stay and the
remote leaves the checkout.

## Prepare

After render, `up` runs `factory-prepare` (`modules/forge.sh`,
`modules/bus.sh`). Once and then confirmed: a password
per bus user and the ACL applied; the operator's account and token; the
repository `<factory>-operator/<factory>`, owned by an ordinary account
and not an admin's (ADR-068); per role an account `<factory>-<role>` with
read on it, a `write:issue` token and a pinned `memory` issue opened as
that account; for the decider `<factory>-decider` and a `read:issue`
token; a label per stage's capability
plus `blocked` and `memory`. Tokens and passwords are files under the state
directory, owned by the role's uid, and reach the API as a header read from
a file.

## A role session

`cmd_role_enter` composes one `nixcage-container enter` line in a fixed
order, asserted whole by `seam.bats`: `--uid`, `--user`, `--home`,
`--network` (the plan's placement for a supervised run; for a person, the
running actor's namespace when there is one, found through the nspawn
that holds it, so a hand beside an actor takes no second veth),
`--no-nix-daemon`, `--substrate` (the role's, raised to the operator's
floor by the clamp; the decider's is `nspawn`), the profile on
`NIXCAGE_PATH_PREFIX` when render realised one, then `--auth-sock` (by
hand) or `--no-agent` (supervised), the task bind if given, the signing binds, and for a supervised run the actor's part: the
role's own pi directory bound at `PI_CODING_AGENT_DIR` and `PI_AGENT_DIR`, the bus password
and forge token bound read-only, and the `FABRIEK_*` environment naming the
role, its capabilities, its specialists, the bus, the forge, the repository
and the proxy, and `--memory` and `--cpus` sized from the declaration's
resources over its concurrency, set on the cage's scope (nixcage ADR-012).
The cage is named `<factory>-<role>`, a machine name of at most
sixty-four characters, and so is its uid's principal, since one host runs
several factories; its veth carries a hash of that name (nixcage
ADR-013). A
person entering a role whose actor is running is put inside its cage with
`nixcage-container exec`, not beside it. The decider's session is the same
line with the machine's own loop, the declaration and the policy bound in,
and `pi --mode rpc` as its command. A role declared `microvm` is the
same line with `--substrate microvm`, and nixcage boots it under
`systemd-vmspawn` in a kernel of its own (nixcage ADR-019).

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
`mirror` fetches `main` from the forge into the clone and writes the
issues as `refs/fabriek/record` there, pushing nowhere; the operator's
fetch carries both into the checkout. `factory-prepare` reads the record
back on a host whose board is empty (`fabriek_forge_restore_record`):
each issue opened again in number order with its labels and state, memory
issues excepted, a label the declaration lost named and dropped. The export
carries no comments, so neither does the restored board.

## The decider

`factory/src/decider/core.ts` (ADR-034): the prompt is the factory's rules,
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
Forgejo's UI; nothing merges by verb. `fabriek board` prints that UI's
address on the factory's bridge, which the host reaches, and a password
the machine program set fresh on the operator's account (`factory-board`),
since the account was made with one nothing kept.

## The invariants

1. The executor is uncaged and content-blind; the decider is caged and reads
   everything. Nothing a role or the decider writes reaches a command line:
   titles and bodies are files, commands are typed JSON on a stream.
2. A cage holds no credential that reaches off the host, and no route.
3. A role session's cage is composed of nixcage flags and nothing else.
4. What a role can run is what its specialists declared, built by the
   host: tools, language servers and the runner the guard trusts come
   from the catalogue and the repository's own, never from anything found
   in the tree or installed in a home (ADR-031, ADR-042, ADR-043).

## Tests

```
nix develop --command shellcheck -x fabriek fabriek-container modules/*.sh
nix develop --command bats --recursive tests/       # ~470 scenarios, minutes
nix build .#factory                                  # 185 scenarios
quint run models/factory-lifecycle.qnt --invariant=allInvariants --max-steps=60 --max-samples=10000
quint run models/tdd-guard.qnt --invariant=allInvariants --max-steps=40 --max-samples=10000
nix develop --command tests/system/journey.sh        # the factory on this host
FABRIEK_PROOF_DIR=... tests/manual/isolation.sh    # needs a NixOS host
FABRIEK_PROOF_DIR=... tests/manual/parity.sh       # needs a NixOS host
FABRIEK_PROOF_DIR=... tests/manual/specialist.sh   # needs a NixOS host
```

`tests/command/catalogue.bats` evaluates and builds `lib.catalogue` for
real over the shipped catalogue and one each scenario writes: the flattening,
every refusal, and what a built role carries (`bin/`, `APPEND_SYSTEM.md`,
`skills/`, `lsp.json`, `tests.json`). `host_module.bats` evaluates
`services.fabriek` for real with two factories declared: the bridges, the
facts files, the slices and units, the proxy's servers and dictionaries,
the forward chain, the sudoers rule; `factory_up.bats` drives `factory-up`
and `factory-down` whole with the forge, `nix build`, `systemctl` and
`nixcage-container` stubbed and real git; `up.bats` drives the CLI's side
with `sudo` stubbed and real git on the checkout; `render.bats` drives
`factory-render`; `probes.bats` drives the one reader over two factories;
`factory_render.bats` and `credential.bats` drive the renderers and the
credential writer.

`tests/system/journey.sh` runs the factory as a system with no cage and no
model: Valkey and a forge on localhost, `factory-prepare` and `bus-acl` on
them, the executor with `FABRIEK_SESSION_COMMAND` naming a session that
runs `fabriek-fake-actor` or `fabriek-fake-decider` where a cage would
run pi. The scripted actor is the extension's own actor, bus and board
(`extension/bind.ts`) driven by a script; the scripted decider is the
decider's own binding (`decider/bind.ts`) judged by `fake-decider/policy.ts`.
Every command still passes the core's gate and the executor's. What the
journey proves is everything but the model and the cage, including the
checkout's refs and its untouched branch and tree; what needs a NixOS
host is the cage, the bridge, the proxy's count, the substrate and pi.

## Not built, and known gaps

- The record's comments: the export is the issue list, so a restored board
  has the issues and not what was said under them.
- The TUI's memory view and pull request list, which are the forge's and
  not on the bus.
- The spend count lives in the proxy's memory and starts at zero when it
  restarts.
- `tests/manual/parity.sh` passes up to the first assignment and is gated
  there on a credential the endpoint accepts; see `docs/roadmap.md` 5.1.
  Everything after the assignment is proved on this host by
  `tests/system/journey.sh` with scripted actors, on Gitea on a Mac.
- Which model a session starts on is the operator's, per endpoint in
  their config (`[models]`), with a table in `modules/factory-render.sh`
  standing when they name none; a declaration cannot name one.
- A cage has no network, and sbt, Maven, pnpm and Metals fetch dependencies
  over one. A language specialist works only when the project's devShell
  carries the cache; otherwise the first build is a blocked outcome. No
  per-factory artifact cache exists.
- The guard's verdict is pi's bash error flag, not an exit code; `sbt`
  counts any invocation as a run because its verbs sit inside one quoted
  argument. `tests/manual/specialist.sh` has not run on a host.
- The manual proofs under `tests/manual/` still reach a factory over the
  machine's ssh; they are rewritten against the host with ADR-067's
  measurement plan.
