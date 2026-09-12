# cageworks

A factory of named roles working one git repository, each in a cage of its own.

A role is a worker, not a project: it has its own uid, its own permanent
worktree, its own home and its own signing key. Roles share the repository's
object database and are partitioned by ref -- a role writes only
`refs/heads/<role>/*`, and `main` is writable by no cage at all. Work reaches a
role as files and its outcome leaves as files, so nothing a role writes ever
becomes part of a command line.

cageworks runs on [nixcage](https://github.com/hamidr/nixcage), which owns the
cages. Everything about isolation, uid mapping, binds, environment selection,
secrets and storage is nixcage's; everything that exists only because several
named workers share one repository is here.

The machine is cageworks' own. A factory runs in a NixOS VM of its own on
Linux and macOS alike, so the isolation a factory gets does not depend on
which laptop is open and two factories share no kernel, store or uid space
(ADR-019). Inside it, nixcage is on an ordinary Linux host running cages
natively.

## How it works

```
cageworks up acme                  builds and boots the factory's machine from
     |                             a lock that pins the repository's commit
cageworks task file acme ship "Add an importer" "handles empty files"
     |
     +-- an issue on the machine's forge, labelled with the first stage
     +-- the decider, a cage of its own, chooses a ready role and asks
     +-- the executor validates the ask and sends a pointer on the bus
     +-- the role's cage acks, works, commits on its branch, comments its outcome
     +-- the executor checks the commit and moves the label; the decider goes on
     |
cageworks factory console acme     one screen: roles, board, live stream, keys
cageworks factory mirror acme      merged main and the record reach origin,
                                   on your word and never before
```

The executor is uncaged and content-blind: it validates every verb against
the declaration and the board, and acts. The decider is caged and reads
everything, and can only ask. Nothing a cage writes reaches a command line,
and a cage has no route off the machine.

## Install

cageworks is two programs. There is no NixOS module to import and no rebuild to
run: a repository declares the factory that works it, and the operator keeps one
file saying what a factory may cost here.

The repository's own flake gains a `cageworks` output. The shortest one that
works:

```nix
cageworks = {
  name = "acme";
  roles.builder = { command = [ "claude" ]; provides = [ "build" ]; };
  workflows.ship.stages = [ { needs = "build"; } ];
};
```

It is read from the commit rather than from the working tree, so the factory
working a repository is the one its history declares. `examples/factory-project`
is a complete one, with its declaration in `cageworks.nix` beside the devShells
its roles name.

The operator's side is `~/.config/cageworks/config.toml`, the same file on Linux
and on macOS:

```toml
[caps]
memory = "16G"
cores = 8
roleQuota = "50G"
concurrency = 4

[factories.acme]
path = "/home/me/Src/acme"
```

A repository states what it needs and this caps it; cageworks says which field
it clamped rather than sizing down quietly. Both files are closed schemas: a key
cageworks does not recognise is refused with its own name rather than ignored,
which is what stops a repository reaching the machine it is given.

nixcage still needs `principalUidRange` set where it declares your cages, because
a range of the host's uid space is a fact about the machine and the program
handing numbers out is the only one that can promise never to reissue one.

## Commands

| Command | Description |
|---|---|
| `cageworks up <factory>` | Build and boot the machine that factory runs in |
| `cageworks down <factory>` | Shut it down, reporting a stop that cannot complete rather than forcing one |
| `cageworks vm status` | The machines on this host, what each is doing, and the port it answers on |
| `cageworks role <factory> <role> [-- cmd]` | Enter a role by hand, in its own worktree and uid |
| `cageworks role stop <factory> <role>` | End a role's running turn; its task stays with it |
| `cageworks role steer <factory> <role> <text>` | Speak into a role's running turn |
| `cageworks task file <factory> <workflow> <title> [body]` | File a goal; the decider assigns it and nothing is typed after |
| `cageworks factory console <factory>` | The one face: roles, board, live stream, and the keys |
| `cageworks factory watch <factory>` | The factory's bus as JSON lines, for any client |
| `cageworks factory send <factory> '<json>'` | A command in the decider's vocabulary, from you |
| `cageworks factory mirror <factory>` | Push merged main and the record to the repository's origin |

## How work moves

A pipeline's stage names a **capability** rather than a role, and roles declare
what they **provide**. A stage is a label on the issue. The decider chooses
among the ready roles that provide what the stage needs; after that the task
sticks to its role, because the branch is in that role's namespace. Adding a
second backend adds capacity without touching the pipeline (ADR-015).

The board and the record are a Forgejo on the factory's own machine
(ADR-036): every actor reads it, a role comments its outcome under a token
that can do that and nothing else, and the executor alone labels and closes.
Merging is your click in its web UI over the forwarded port; `factory mirror`
carries merged `main` and the record to origin afterwards.

The machine trusts no cage (ADR-033, ADR-037): each has one address on a
bridge with no route off the machine, the proxy holds the model credential
and counts every cage's spend, and an actor's word about what it holds is a
claim the executor checks against its own board.

## What is not here yet

`docs/roadmap.md` keeps the list. The record is exported to origin and not yet
read back on a fresh machine; the TUI shows what the bus carries and not yet
the forge's own views; the real-machine proofs have not yet passed.

## Development

```bash
nix develop
nix develop --command shellcheck -x cageworks cageworks-container modules/*.sh
nix develop --command bats --recursive tests/
nix build .#factory
docmeta-check docs && docmeta-tracker --check docs
quint run models/vm-lifecycle.qnt --invariant=allInvariants --max-steps=60
```

`docs/TRACKER.md` indexes every decision. ADR-001 through ADR-008 describe code
that now lives in nixcage; they remain as the record of why the cage is shaped
as it is, and a change to cage behaviour is proposed there rather than here.

## License

GPL-3.0-only.
