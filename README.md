# fabriek

A factory of named roles working one git repository, each in a cage of its own.

A role is a worker, not a project: it has its own uid, its own permanent
worktree, its own home and its own signing key. Roles share the repository's
object database and are partitioned by ref: a role writes only
`refs/heads/<role>/*`, and `main` is writable by no cage at all. Work reaches a
role as files and its outcome leaves as files, so nothing a role writes ever
becomes part of a command line. Who a role is, its tools, its prompt, its
skills and its language servers, is declared in a catalogue and built into
the machine; nothing is installed or found in the tree.

fabriek runs on [nixcage](https://github.com/hamidr/nixcage), which owns the
cages. Everything about isolation, uid mapping, binds, secrets and storage
is nixcage's; everything that exists only because several named workers
share one repository is here.

The machine is fabriek' own. A factory runs in a NixOS VM of its own on
Linux and macOS alike, so the isolation a factory gets does not depend on
which laptop is open and two factories share no kernel, store or uid space
(ADR-019). Inside it, nixcage is on an ordinary Linux host running cages
natively.

## How it works

```
fabriek up acme                  builds and boots the factory's machine from
     |                             a lock that pins the repository's commit
fabriek -f acme file ship "Add an importer" -m "handles empty files"
     |
     +-- an issue on the machine's forge, labelled with the first stage
     +-- the decider, a cage of its own, chooses a ready role and asks
     +-- the executor validates the ask and sends a pointer on the bus
     +-- the role's cage acks and runs pi as who its specialists say, with
     |     their tools, skills and language servers; the loop refuses code
     |     before a failing test; it commits on its branch, comments its outcome
     +-- the executor checks the commit and moves the label; the decider goes on
     |
fabriek -f acme console         one screen: roles, board, activity, a role's stream
fabriek -f acme board           Forgejo's UI on a local port, to merge
fabriek -f acme mirror          merged main and the record reach origin,
                                   on your word and never before
```

The executor is uncaged and content-blind: it validates every verb against
the declaration and the board, and acts. The decider is caged and reads
everything, and can only ask. Nothing a cage writes reaches a command line,
and a cage has no route off the machine.

## Install

fabriek is two programs. There is no NixOS module to import and no rebuild to
run: a repository declares the factory that works it, and the operator keeps one
file saying what a factory may cost here.

The repository's own flake gains a `fabriek` output. The shortest one that
works:

```nix
fabriek = {
  name = "acme";
  roles.backend = { provides = [ "build" ]; specialists = [ "django" ]; };
  roles.reviewer = { provides = [ "review" ]; specialists = [ "reviewer" ]; };
  workflows.ship.stages = [ { needs = "build"; } { needs = "review"; } ];
};
```

A role is what it provides and who it is. It runs pi (ADR-029) unless it
declares a `command`; it may name a devShell of the same flake (`shell`)
for the project's own build environment. It is read from the commit rather
than from the working tree, so the factory working a repository is the one
its history declares. `examples/factory-project` is a complete one, with
its declaration in `fabriek.nix` beside the devShells its roles name and a
catalogue of its own.

## Who a role is

`specialists` names entries of the catalogue (ADR-042): fabriek's own
under `catalogue/`, and the repository's under the directory its
`catalogue` field names. A specialist is a directory: a `PROMPT.md`, the
tools it brings, the skills it knows (Agent Skills format, the same
`SKILL.md` pi, Claude Code and Codex read), the language servers it runs
(ADR-043, through `pi-lsp`), and what a test is in its language (ADR-044).
Every role queries its worktree as a graph, symbols and calls and blast
radius, through `codegraph` (ADR-049, through `pi-codegraph`).
Specialists compose: `[ "springboot" "python" ]` is one role with both
kits, each prompt once, in that order. Adding a specialist is adding a
directory; nothing else lists them.

Shipped: `committer` (the root: whoever works in a worktree, with the
tools to read it), `developer` (a builder, held to test first; every
language specialist extends it), `python`, `flask`, `django`, `java`,
`springboot`, `scala`, `frontend`, `react`, `architect` (the glossary, the
decision records and the overview of the product, with Quint, Alloy 6 and
Lean 4 to check a design), `manager` (the decider's policy, the factory's
guidance and the repository's own skills and script tools; splits a goal
into tasks the decider files), `reviewer`.

Every specialist is held to test first, domain placement, one reason to
change and a pure core: as skills it reads, as a review that blocks, and
as the loop's guard, which refuses production code before a failing test
and done before a passing run (ADR-044).

A role with `replicas = N` is N roles, `backend-1` to `backend-N`, each
with a cage, a worktree, a key and an account of its own (ADR-053); the
decider spreads a stage's tasks across them.

The operator's side is `~/.config/fabriek/config.toml`, the same file on Linux
and on macOS:

```toml
[caps]
memory = "16G"
cores = 8
roleQuota = "50G"
concurrency = 4

[credentials."api.anthropic.com"]
header = "x-api-key"
file = "/home/me/.secrets/anthropic"

[credentials."api.deepseek.com"]
header = "Authorization"
file = "/home/me/.secrets/deepseek"   # holds the whole header value: "Bearer sk-..."

[models]
"api.anthropic.com" = "claude-opus-5"

[factories.acme]
path = "/home/me/Src/acme"
```

On NixOS the same file is declared instead of kept, and a factory can be
brought up at boot (ADR-048):

```nix
services.fabriek = {
  enable = true;
  caps = { memory = "16G"; cores = 8; egress = [ "api.anthropic.com" ]; };
  credentials."api.anthropic.com" = { header = "x-api-key"; file = "/run/secrets/anthropic"; };
  factories.acme = { path = "/srv/acme"; autoStart = true; };
};
```

The module renders `/etc/fabriek/config.toml`, which the CLI reads when no
personal file exists, and `fabriek-acme.service` runs `fabriek up acme` at
boot. A repository states what it needs and this caps it; fabriek says
which field it clamped rather than sizing down quietly. Which endpoints a factory may
reach, which credential opens each, and which model a session starts on are
the operator's alone; a declaration names none of them (ADR-025, ADR-029). Both files are closed schemas: a key
fabriek does not recognise is refused with its own name rather than ignored,
which is what stops a repository reaching the machine it is given.

nixcage still needs `principalUidRange` set where it declares your cages, because
a range of the host's uid space is a fact about the machine and the program
handing numbers out is the only one that can promise never to reissue one.

## Commands

`fabriek [-f FACTORY] VERB [ARGS]`. The factory a verb is about is `-f`,
else `FABRIEK_FACTORY`, else the one factory registered here. Every verb
takes `-h`; a usage error is one line on stderr and exit 2; `ls`, `ps`,
`show` and `check` take `--json`; colour appears only on a terminal.

| Command | Description |
|---|---|
| `fabriek check [REPO]` | What `up` would refuse, in seconds: the declaration at its commit and every specialist each role names |
| `fabriek ls [REPO]`, `fabriek show NAME [REPO]` | Every specialist and skill, and what one brings: order, tools, skills, servers, tests, prompt; no build |
| `fabriek -f FACTORY show ROLE` | The same for a registered factory's role at its commit |
| `fabriek up [-u] [FACTORY]` | Build and boot the machine that factory runs in; -u moves the pin to HEAD |
| `fabriek down [FACTORY]` | Shut it down, reporting a stop that cannot complete rather than forcing one |
| `fabriek ps [--json]` | The machines on this host, what each is doing, and the port it answers on |
| `fabriek enter ROLE [-- CMD...]` | Enter a role by hand, in its own worktree and uid; inside its cage when its actor runs |
| `fabriek stop [-k] ROLE` | End a role's running turn through the executor; -k ends the cage at its scope |
| `fabriek steer ROLE [TEXT]` | Speak into a role's running turn; TEXT or stdin |
| `fabriek log [-t] ROLE [SESSION]` | The sessions pi kept for a role, or one of them as it is or as the turns' text |
| `fabriek file [-m BODY] WORKFLOW TITLE` | File a goal, the body from -m or stdin; the decider assigns it and nothing is typed after |
| `fabriek console` | The one face: roles with one selected, board, activity, that role's stream, keys |
| `fabriek board` | Forgejo's UI on a local port, for merging; prints the URL and the login |
| `fabriek watch [--from ID]` | The factory's bus as JSON lines, for any client |
| `fabriek send [JSON]` | A command in the decider's vocabulary, from you or stdin |
| `fabriek mirror` | Push merged main and the record to the repository's origin |

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

`docs/roadmap.md` keeps the list. The record is exported to origin and read
back on a fresh machine without its comments; the TUI shows what the bus
carries and not yet the forge's own views; the real-machine proofs, the
specialists' among them, have not yet passed. A cage has no network, so a
language whose build tool fetches dependencies (sbt, Maven, pnpm) works
only when the project's devShell carries the cache; no per-factory
artifact cache exists.

## Development

```bash
nix develop
nix develop --command shellcheck -x fabriek fabriek-container modules/*.sh
nix develop --command bats --recursive tests/
nix build .#factory
nix develop --command bats tests/command/catalogue.bats   # the catalogue, built for real
nix develop --command tests/system/journey.sh   # the whole factory on this host, no model
docmeta-check docs && docmeta-tracker --check docs
quint run models/vm-lifecycle.qnt --invariant=allInvariants --max-steps=60
quint run models/tdd-guard.qnt --invariant=allInvariants --max-steps=40 --max-samples=10000
```

`docs/TRACKER.md` indexes every decision. ADR-001 through ADR-008 describe code
that now lives in nixcage; they remain as the record of why the cage is shaped
as it is, and a change to cage behaviour is proposed there rather than here.

## License

GPL-3.0-only.
