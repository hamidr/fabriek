# CLAUDE.md

This file provides guidance to Claude Code when working with code in this repository.

## What is fabriek

fabriek runs a factory: one git repository assigned to a set of declared
roles that work it at the same time, each in a cage of its own, on a NixOS
host that runs several factories (ADR-067). A role is a worker, not a
project: its own uid, its own dataset and home, its own signing key, its
own forge account and bus user (ADR-010, ADR-009, ADR-033, ADR-036).

It does not run cages. [nixcage](https://github.com/hamidr/nixcage) does, and
is a flake input pinned in `flake.lock`. Everything a single session needs is
nixcage's (isolation, uid mapping, binds, a private network per cage,
storage); everything that exists only because several named workers share one
repository is ours (the factory's services on the host, the board and the
record on a forge, the bus, the executor, the decider, the loop, the relay,
the TUI). ADR-018 is that decision; ADR-033 through ADR-040, ADR-067 and
PRD-006 are the design; `docs/architecture.md` is what is built;
`docs/roadmap.md` is what is left; `docs/TRACKER.md` indexes the rest.

A factory is declared in the repository it works (ADR-020, ADR-058, as
`fabriek.toml`) and on the host that runs it (`services.fabriek`,
ADR-048, ADR-067); `fabriek up` renders it there and the host's daemon
builds each role's toolchain. The operator keeps one plain file saying
what a factory may cost here, and the factory's branches appear in the
operator's own checkout under `fabriek/<name>/`. Nothing a cage does is
trusted: the executor validates every verb, the proxy counts the spend,
and a cage has no route off the host (ADR-037).

## The interface with nixcage

fabriek uses nixcage's exported primitives and nothing else. It writes no
nspawn arguments, runs no `zfs`, allocates no uid and reads no process table.
It opens no SSH connection: the machine program runs on this host as root
through `sudo`, for that one program and the `fabriek` group (ADR-067).

| Primitive | Used for |
| --- | --- |
| `nixcage-container enter [--uid n] [--user name] [--home path] [--network BRIDGE:ADDR/PREFIX] [--no-nix-daemon] [--substrate nspawn\|microvm] [--memory SIZE] [--cpus N] [--bind SRC:DST] [--bind-ro SRC:DST] [--setenv K=V] [--no-agent\|--auth-sock path] <name> <project> [cmd]` | Every role session, bounded on its scope from the declaration; the cage is `<factory>-<role>` |
| `nixcage-container uid <principal>` | A role's uid, allocated once and never reissued; the principal is `<factory>-<role>` |
| `nixcage-container storage ensure <path> <uid> [quota]` | A factory's state, a role's worktree and the record's dataset, owned and bounded |
| `nixcage-container status <name>`, `stop <name>` | Whether a role's cage runs and its scope's cgroup (the probes' key); `stop -k` |
| `nixcage-container exec <name> [-- cmd]` | A person entering a role whose actor is running, inside its cage |
| `nixcage-container rm <name>` | A role whose declared substrate changed, at `up -u`, so the next enter may choose again |

When something is needed that these cannot express, **the interface changes in
nixcage first**: two commits in two repositories and a lock bump. Reaching
around them, reading nixcage's state directory, its SSH key, its port, its
internal function names, is the coupling ADR-018 exists to remove.

`tests/command/seam.bats` is the gate on this. It stubs `nixcage-container` on
`PATH`, records the argv a role session produces, and asserts the whole line.
A change to what a role session is shows up there as a diff.

## Repository layout

- `fabriek`: the operator's launcher, `fabriek [-f FACTORY] VERB` (ADR-047):
  `up`, `down`, `fetch`, `ps`, `check`, `ls`, `show`, `enter`, `stop`,
  `steer`, `log`, `file`, `board`, `watch`, `send`, `mirror`.
  Reaches the machine program through `sudo` with the factory in the
  environment, and knows nothing else about where the cages are; what it
  does itself is add a remote at the factory's clone to the operator's
  checkout and fetch it into `refs/heads/fabriek/<name>/*` (ADR-067).
- `fabriek-container`: the machine program, on the host as root, serving
  the factory named by `FABRIEK_FACTORY` from its facts file under
  `/etc/fabriek/factories/`. Brings a factory up and down (`factory-up`
  under a lock, `factory-down`, `factory-status`), composes a role session
  (`role-enter`, `role-worktree`), renders and prepares the factory
  (`factory-render`, `factory-prepare`), and writes the operator's interventions to the bus
  (`task-file`, `role-stop`, `role-steer`, `factory-mirror`, `factory-send`,
  `factory-watch`) and reads a role's transcript (`role-transcript`,
  `modules/transcript.sh`). A real script rather than a Nix string so
  shellcheck reads it and bats drives it.
- `factory/`: the TypeScript package, one for all of the executor
  (`src/executor`), the loop as a pi extension (`src/extension`), the decider
  (`src/decider`), the relay (`src/relay`), the TUI (`src/tui`) and the two
  scripted stand-ins for pi (`src/fake-actor`, `src/fake-decider`), so the
  vocabulary (`src/vocabulary.ts`), the bus messages (`src/messages.ts`) and
  the thread's attempt lines (`src/thread.ts`) are defined once. `src/bus`
  and `src/forge` are the two adapters (RESP over a socket, Forgejo over
  HTTP); `src/declaration.ts` reads the declaration the build put on the
  host. No runtime dependency and no npm: built with `tsc`, tested
  with node's own runner, pi's types linked in from the pi in the closure
  (`factory/default.nix`).
- `catalogue/`: what a role can be (ADR-042). `specialists/<name>/` is a
  `PROMPT.md` and a `default.nix` (a function of `pkgs`, `specialists`,
  `skills`) naming tools, parents and skills as values; `skills/<name>/` is
  a `SKILL.md` in the Agent Skills format and a `default.nix` naming its
  tools. A role names specialists in `fabriek.toml`; `modules/catalogue.nix`
  composes them into one derivation per role at render, and
  `floor.nix` puts the result where pi reads it. A repository may add a
  catalogue of its own with the same layout. Adding a specialist is adding
  a directory. A specialist's `lsp` servers reach the `pi-lsp` extension
  (`modules/pi-lsp/`, built from npm with a lockfile of ours, ADR-043).
  `developer` carries `codegraph` (`modules/codegraph/`, the release
  tarball wrapped to reach nothing off the host); the `pi-codegraph`
  extension (`modules/pi-codegraph/`, the npm tarball, no dependencies)
  gives every role's pi the `codegraph_*` tools over the index the machine
  program builds at the worktree (ADR-049).
- `modules/names.sh`: the names fabriek accepts, checked where they are
  declared. A role's cage is `<factory>-<role>`, a machine name to nspawn,
  so the sum is at most sixty-four characters; `decider` and `main` are
  reserved.
  `factory/src/names.ts` mirrors it: a change to the alphabet lands in both.
- `modules/*.sh`: what the two programs source by store path.
  `machine-spec.sh` clamps a declaration against the caps at render, the
  substrate floor included; `factory-render.sh`
  renders the plan, the proxy, the models and the pi directories from the
  declaration and builds a profile per role; `credential.sh` writes the
  factory's credential, the operator's config projected for it plus the
  pin; `factory-up.sh` is what `factory-up` does around render (the
  credential, the operator's files in the store, the model credentials
  filed for the proxy);
  `machine-plan.sh` reads the plan and the profiles render put under the
  factory's directory and composes the actor's part of a session; `forge.sh` and
  `bus.sh` prepare the forge and the bus once and confirm them after;
  `operator.sh` writes the operator stream; `probes.sh` writes the kernel's
  lines to the bus with the role each uid belongs to; `role-worktree.sh`, `signing.sh`,
  `factory-clone.sh`, `factory-config.sh` are a role's worktree, key, clone
  and command; `repo-declaration.sh`, `schema.sh`, `resources.sh`, `sizes.sh`,
  `operator-config.sh` are the declaration's and the operator's schemas and
  the clamp between them;
  `check.sh` is `fabriek check`, `ls` and `show`:
  the declaration and every specialist resolved at the commit, evaluation
  only.
- `modules/host.nix`, `modules/host/*.nix`: `nixosModules.host`,
  `services.fabriek` on a NixOS host (ADR-048, ADR-067): the operator's
  `config.toml` rendered to `/etc`, read by the CLI when no personal file
  exists; per declared factory a bridge `fb-<idx>`, a facts file under
  `/etc/fabriek/factories/`, a slice with its state, bus, record, board,
  egress credentials and executor units (`state.nix`, `bridge.nix`,
  `bus.nix`, `board.nix`, `executor.nix`), and with `autoStart` a unit
  that runs `factory-up` at boot; once on the host, nginx with a server
  and a spend dictionary per factory and a forward chain that drops
  anything from or to a factory's bridge (`proxy.nix`, `spend.js`, driven
  by `spend.test.mjs` through `tests/unit/proxy_spend.bats`), one bpftrace
  reader over every factory (`probes.nix`), the floor (`floor.nix`), and
  a sudoers rule for the machine program.
  `modules/profile.nix`: one role's profile, built by the host's daemon
  at render from the repository at the pin. `modules/catalogue.nix`:
  `lib.catalogue`, the specialists and skills of every catalogue and
  `compose` for one role (ADR-042).
- `modules/role-guidance.md`: what every role is told about working in a
  cage, the front of every role's system prompt (`host/floor.nix`, ADR-054).
- `modules/package.nix`: the two programs, wrapped with the module directory
  they source and the tools they run.
- `tests/system/journey.sh`: the whole factory on this host with no cage
  and no model: Valkey and a forge for real on localhost, the real machine
  program, executor and relay, and the scripted actor and decider
  (`factory/src/fake-actor`, `factory/src/fake-decider`) where the cages
  would run pi. PRD-006's journey from a filed goal to a mirrored record,
  with the refusals along the way and the bus ACL asked with DRYRUN.
- `tests/manual/`: what cannot be a bats test because it needs a NixOS host.
  `isolation.sh` is ADR-037's measurement plan; `parity.sh` is PRD-006's first
  success criterion; `stop-and-start.sh` is PRD-004 phase 2's;
  `specialist.sh` is ADR-042's; `lib.sh` is what they share.
- `models/factory-lifecycle.qnt`: a factory's lifecycle on its host; `models/tdd-guard.qnt`:
  the loop's test-first guard (ADR-044).
- `examples/factory-project/`: a repository worked by a factory.
- `docs/`: ADRs, PRDs, the generated TRACKER.md, `architecture.md`,
  `roadmap.md`.

## Development

```bash
nix develop                          # bash, jq, shellcheck, bats, git, node
nix develop --command shellcheck -x fabriek fabriek-container modules/*.sh
nix develop --command bats --recursive tests/       # ~340 scenarios, minutes
nix develop --command bats -f "one invocation" tests/command/seam.bats
nix develop --command bats tests/command/catalogue.bats      # the catalogue, evaluated and built for real
nix build .#factory                  # compiles and runs its ~145 scenarios
nix develop --command bash -c 'cd factory && npm test'
nix develop --command bash -c 'cd factory && tsc -p . && cp src/relay/fixtures.json dist/relay/ \
  && node --test --test-name-pattern="refuses" dist/vocabulary.test.js'   # one TS scenario
nix fmt                              # nixfmt, Nix files only
nix develop --command tests/system/journey.sh              # the factory on this host, ~4 minutes
FABRIEK_PROOF_DIR=/tmp/proof tests/manual/isolation.sh   # needs a NixOS host
```

Run `nix develop` from the repository root: its shellHook puts the root on
`PATH` and links `factory/node_modules` relative to `$PWD`, and bats finds
bats-support and bats-assert only through the `BATS_LIB_PATH` it exports.

There is no build step for the shell programs; both run directly. The
TypeScript package is built with `tsc` and nothing else; a test file is run
by its compiled path under `factory/dist`.

`tests/unit/` sources a shell module and calls its functions. `tests/command/`
drives a program with its dependency stubbed on `PATH`: the CLI tests stub
`sudo` (`up.bats` with real git on the checkout), `seam.bats` stubs
`nixcage-container`, `prepare.bats` stubs the forge, `factory_up.bats`
stubs all of those around `factory-up` whole, `operator.bats`,
`bus_acl.bats` and `probes.bats` stub `valkey-cli`; `render.bats` stubs
`nix build` and `systemctl` around the real TOML reader;
`host_module.bats` evaluates `nixosModules.host` for real with two
factories declared, and `catalogue.bats` evaluates and builds
`lib.catalogue` for real. The stubs several files share are in
`tests/test_helper/stubs.bash`.
The package's tests
drive each core against fakes of its interfaces and each adapter against a
local fake server. Every test name reads as a scenario.

Documents have their own checks:

```bash
docmeta-check docs                   # frontmatter is valid
docmeta-tracker docs                 # regenerate docs/TRACKER.md, never by hand
quint run models/factory-lifecycle.qnt --invariant=allInvariants --max-steps=60 --max-samples=10000
quint run models/tdd-guard.qnt --invariant=allInvariants --max-steps=40 --max-samples=10000
```

## Architecture

`docs/architecture.md` describes the branch as built, component by component.
The short form:

**A role session** (`cmd_role_enter`) composes one `nixcage-container enter`
line in a fixed order that `seam.bats` asserts whole: the cage on the bridge
at its planned address with no daemon, its profile on `PATH`, and for a
supervised run the loop, its two credentials and the environment the loop
reads.

**The loop** (`factory/src/extension`) announces ready, takes an assignment
pointer, works the issue in a fresh process, comments its outcome under its
own token, and ends so the next process is a fresh session. Blocked holds.
Its test-first guard (`guard.ts`, ADR-044, modeled in
`models/tdd-guard.qnt`) refuses production edits and done by the order of
test edits, runs and code edits the specialists' `tests.json` lets it see.

**The executor** (`factory/src/executor`) is uncaged and content-blind: it
validates the six verbs against the declaration and the board, writes
`assigning` before it sends and `assigned` on the ack, reconciles on start
without ever creating an assignment from an actor's answer, and moves a
stage only on a signed commit.

**The decider** (`factory/src/decider`) is a cage that reads everything and
asks in six verbs. **The relay and the TUI** (`factory/src/relay`,
`factory/src/tui`) are the operator's one face over one channel.

### The invariants

1. The executor is uncaged and content-blind; the decider is caged and reads
   everything. Nothing a role or the decider writes reaches a command line.
2. A cage holds no credential that reaches off the host, and no route.
3. A role session's cage is composed of nixcage flags and nothing else.

### What is not built

`docs/roadmap.md` keeps the list beside each item. The record's comments
and the TUI's forge-side views are open. ADR-067's measurement plan ran
on the host on 2026-09-22 and is recorded in its verification.

## Conventions

- `fabriek_*` prefix for shell-module functions, `cmd_*` for command
  handlers.
- Machine-side logic goes in `fabriek-container` or a `modules/*.sh` file it
  sources, never inline in a command string.
- A declared command is argv, one word per element, never a shell line: the
  declaration is data and nothing in it is re-split on the way.
- Names that reach a path, a ref, a uid, an interface or a flake reference are
  validated where they are declared (`fabriek_name_ok`,
  `fabriek_role_name_ok`, `fabriek_shell_name_ok`), not where they are
  used.
- A role session's cage is composed of nixcage flags and nothing else. Reaching
  for anything outside the three primitives means the interface is wrong, and
  the fix is upstream.
- Every component is built behaviour first: scenarios written and seen failing
  before code, in the runner the component already has (`docs/roadmap.md`,
  Method).
- ADR-001 through ADR-008 describe code that now lives in nixcage. They are
  historical here: a change to cage behaviour is proposed in nixcage's
  repository, not in this tracker. Numbering continues at ADR-018.
- `SPEC.md` is nixcage's specification, kept from before ADR-018 for the
  same reason ADR-001 through ADR-008 are: historical, not this program's.
