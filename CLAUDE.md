# CLAUDE.md

This file provides guidance to Claude Code when working with code in this repository.

## What is fabriek

fabriek runs a factory: one git repository assigned to a set of declared
roles that work it at the same time, each in a cage of its own, on a machine
of its own. A role is a worker, not a project: its own uid, its own dataset
and home, its own signing key, its own forge account and bus user (ADR-010,
ADR-009, ADR-033, ADR-036).

It does not run cages. [nixcage](https://github.com/hamidr/nixcage) does, and
is a flake input pinned in `flake.lock`. Everything a single session needs is
nixcage's (isolation, uid mapping, binds, a private network per cage,
storage); everything that exists only because several named workers share one
repository is ours (the declaration built into a machine, the board and the
record on a forge, the bus, the executor, the decider, the loop, the relay,
the TUI). ADR-018 is that decision; ADR-033 through ADR-040 and PRD-006 are
the design; `docs/architecture.md` is what is built; `docs/roadmap.md` is
what is left; `docs/TRACKER.md` indexes the rest.

A factory is declared in the repository it works (ADR-020) and built into its
machine's image from a per-factory lock (ADR-040). The operator keeps one
plain file saying what a factory may cost here. Nothing a cage does is
trusted: the executor validates every verb, the proxy counts the spend, and a
cage has no route off the machine (ADR-037).

## The interface with nixcage

fabriek uses three exported primitives and nothing else. It writes no nspawn
arguments, runs no `zfs` and allocates no uid. The only SSH connection it opens
is to a machine it built itself, over the key and port it allocated for that
factory (ADR-019).

| Primitive | Used for |
| --- | --- |
| `nixcage-container enter [--uid n] [--user name] [--home path] [--network BRIDGE:ADDR/PREFIX|ns:PATH] [--no-nix-daemon] [--bind SRC:DST] [--bind-ro SRC:DST] [--setenv K=V] [--no-agent\|--auth-sock path] <name> <project> [cmd]` | Every role session |
| `nixcage-container uid <principal>` | A role's uid, allocated once and never reissued |
| `nixcage-container storage ensure <path> <uid> [quota]` | A role's worktree and the record's dataset, owned and bounded |

When something is needed that these cannot express, **the interface changes in
nixcage first**: two commits in two repositories and a lock bump. Reaching
around them, reading nixcage's state directory, its SSH key, its port, its
internal function names, is the coupling ADR-018 exists to remove.

`tests/command/seam.bats` is the gate on this. It stubs `nixcage-container` on
`PATH`, records the argv a role session produces, and asserts the whole line.
A change to what a role session is shows up there as a diff.

## Repository layout

- `fabriek`: the operator's launcher: `up`, `down`, `vm status`, `role`,
  `role stop`, `role steer`, `task file`, `factory mirror|watch|send|console|board`.
  Reaches the machine program over ssh to the factory's own machine, argv
  NUL-framed through `xargs -0`, and knows nothing else about where the cages
  are.
- `fabriek-container`: the machine program. Composes a role session
  (`role-enter`, `role-worktree`), prepares the factory on the machine
  (`factory-prepare`), and writes the operator's interventions to the bus
  (`task-file`, `role-stop`, `role-steer`, `factory-mirror`, `factory-send`,
  `factory-watch`). A real script rather than a Nix string so shellcheck reads
  it and bats drives it.
- `factory/`: the TypeScript package, one for all of the executor
  (`src/executor`), the loop as a pi extension (`src/extension`), the decider
  (`src/decider`), the relay (`src/relay`), the TUI (`src/tui`) and the two
  scripted stand-ins for pi (`src/fake-actor`, `src/fake-decider`), so the
  vocabulary (`src/vocabulary.ts`), the bus messages (`src/messages.ts`) and
  the thread's attempt lines (`src/thread.ts`) are defined once. No runtime dependency and no npm: built with `tsc`, tested
  with node's own runner, pi's types linked in from the pi in the closure
  (`factory/default.nix`).
- `modules/names.sh`: the names fabriek accepts, checked where they are
  declared. A role name is also its cage's, and nspawn names the veth after
  the cage, so it is at most twelve characters; `decider` is reserved.
- `modules/*.sh`: what the two programs source by store path.
  `machine-spec.sh` composes a machine's spec inside the build;
  `machine-plan.sh` reads the plan and the profiles the build put on the
  machine and composes the actor's part of a session; `forge.sh` and
  `bus.sh` prepare the forge and the bus once and confirm them after;
  `operator.sh` writes the operator stream; `probes.sh` writes the kernel's
  lines to the bus with the role each uid belongs to; `role-worktree.sh`, `signing.sh`,
  `factory-clone.sh`, `factory-config.sh` are a role's worktree, key, clone
  and command; `repo-declaration.sh`, `schema.sh`, `resources.sh`, `sizes.sh`,
  `operator-config.sh` are the declaration's and the operator's schemas and
  the clamp between them; `machine.sh` is where a machine lives on the host.
- `modules/factory.nix`: `lib.factory`, one factory's machine from the
  repository it works and the facts only the host knows (ADR-040). Validation
  and the clamp run inside a derivation by the same shell modules.
- `modules/vm.nix`, `modules/machine/default.nix`, `modules/machine/*.nix`: the machine
  (ADR-019): nixcage's host module inside it, a ZFS pool named after the
  factory, and one module per service: `bridge.nix` (the private network and
  its two rules), `board.nix` (Forgejo), `bus.nix` (Valkey and its ACL),
  `proxy.nix` (the counting proxy), `probes.nix`, `floor.nix` (pi and the
  loops), `executor.nix`.
- `modules/role-guidance.md`: what every role is told about working in a
  cage, bound read-only into a role session.
- `modules/package.nix`: the two programs, wrapped with the module directory
  they source and the tools they run.
- `tests/system/journey.sh`: the whole factory on this host with no cage
  and no model: Valkey and a forge for real on localhost, the real machine
  program, executor and relay, and the scripted actor and decider
  (`factory/src/fake-actor`, `factory/src/fake-decider`) where the cages
  would run pi. PRD-006's journey from a filed goal to a mirrored record,
  with the refusals along the way and the bus ACL asked with DRYRUN.
- `tests/manual/`: what cannot be a bats test because it needs a machine.
  `isolation.sh` is ADR-037's measurement plan; `parity.sh` is PRD-006's first
  success criterion; `stop-and-start.sh` is PRD-004 phase 2's; `lib.sh` is
  what they share.
- `models/vm-lifecycle.qnt`: the machine's lifecycle, the one model kept.
- `examples/factory-project/`: a repository worked by a factory.
- `docs/`: ADRs, PRDs, the generated TRACKER.md, `architecture.md`,
  `roadmap.md`.

## Development

```bash
nix develop                          # bash, jq, shellcheck, bats, git, node
nix develop --command shellcheck -x fabriek fabriek-container modules/*.sh
nix develop --command bats --recursive tests/       # ~310 scenarios, minutes
nix develop --command bats -f "one invocation" tests/command/seam.bats
nix build .#factory                  # compiles and runs its 125 scenarios
nix develop --command bash -c 'cd factory && npm test'
nix develop --command tests/system/journey.sh              # the factory on this host, ~4 minutes
FABRIEK_PROOF_DIR=/tmp/proof tests/manual/isolation.sh   # needs a machine
```

There is no build step for the shell programs; both run directly. The
TypeScript package is built with `tsc` and nothing else.

`tests/unit/` sources a shell module and calls its functions. `tests/command/`
drives a program with its dependency stubbed on `PATH`: the CLI tests stub
`nix` and `ssh`, `seam.bats` stubs `nixcage-container`, `prepare.bats` stubs
the forge, `operator.bats` stubs `valkey-cli`; `factory_flake.bats` and
`machine_services.bats` evaluate `lib.factory` for real. The package's tests
drive each core against fakes of its interfaces and each adapter against a
local fake server. Every test name reads as a scenario.

Documents have their own checks:

```bash
docmeta-check docs                   # frontmatter is valid
docmeta-tracker docs                 # regenerate docs/TRACKER.md, never by hand
quint run models/vm-lifecycle.qnt --invariant=allInvariants --max-steps=60
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
2. A cage holds no credential that reaches off the machine, and no route.
3. A role session's cage is composed of nixcage flags and nothing else.

### What is not built

`docs/roadmap.md` keeps the list beside each item. The record's comments,
the TUI's forge-side views, and the three real-machine proofs are open.

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
