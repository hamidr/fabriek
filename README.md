# fabriek

You design the factory. fabriek runs it.

Name the trades. Write the pipeline. Say what done means at every stage.
fabriek hires a worker into a cage for every role on your NixOS host, runs
the line, counts every token, and hands you merge.

A factory is declared in the repository it works, so anyone who clones it
gets the same team. What a worker is, its tools, its prompt, its skills,
its language servers, is a directory you write. What a factory may cost on
your host is one file you keep. Everything between the two, the cages,
the board, the bus, the decider, the executor, the guard and the meter, is
fabriek's, and none of it trusts a cage.

## Build one

A Rust shop with two trades: a builder and a reviewer. Nothing below is
shipped; it is yours.

A trade is a specialist: a directory in a catalogue of the repository's
own. It says who the worker extends, what it carries, which language
server it runs and what a test is in its language.

```
fabriek/catalogue/specialists/rust/
  PROMPT.md       who this worker is, in prose
  default.nix     what it carries
```

```nix
{ pkgs, specialists, ... }:
{
  extends = [ specialists.developer ];
  tools = with pkgs; [ cargo rustc clippy ];
  lsp = [{
    id = "rust-analyzer";
    include = [ "**/*.rs" ];
    rootMarkers = [ "Cargo.toml" ];
    bin = "${pkgs.rust-analyzer}/bin/rust-analyzer";
    languageIdByExtension = { ".rs" = "rust"; };
  }];
  tests = {
    files = [ "tests/**" "**/*_test.rs" ];
    source = [ "**/*.rs" ];
    command = [ "cargo test" ];
  };
  prompt = ./PROMPT.md;
}
```

The factory is `fabriek.toml` at the root. Roles say what they provide and
who they are; a stage says what it needs and what done means there.

```toml
name = "knot"
catalogue = "fabriek/catalogue"

[roles.builder]
provides = ["build"]
specialists = ["rust"]
replicas = 2

[roles.reviewer]
provides = ["review"]
specialists = ["reviewer", "rust"]

[[workflows.ship.stages]]
needs = "build"
done = "cargo test passes and the change is reviewable"

[[workflows.ship.stages]]
needs = "review"
verdict = true

[resources]
memory = "8G"
cores = 4
egress = ["api.anthropic.com"]
```

Commit both. Then:

```
fabriek check                    what up would refuse, in seconds: the
                                 declaration at its commit, every specialist
                                 resolved and evaluated
fabriek up knot                  the factory's services come up on this host,
                                 on a bridge of its own; each role gets a uid,
                                 a worktree, a signing key, a forge account, a
                                 bus user and a toolchain the host built itself
fabriek -f knot file ship "Add an importer" -m "handles empty files"
     |
     +-- an issue on the factory's forge, labelled with the first stage
     +-- the decider, a cage of its own, picks a ready builder and asks
     +-- the executor validates the ask and sends a pointer on the bus
     +-- builder-1's cage acks and runs pi as the rust specialist says,
     |     with cargo, clippy and rust-analyzer; the loop refuses code
     |     before a failing test; it commits on refs/heads/builder-1/*
     |     and comments its outcome
     +-- the executor checks the signed commit and moves the label;
     |     the reviewer reads the diff and gives a verdict
     |
git branch                       the builder's work is in your own checkout
                                 as fabriek/knot/builder-1/*, refreshed by
                                 every verb; nothing in the factory writes
                                 your repository
fabriek -f knot board            Forgejo on the factory's bridge; merging is
                                 your click, and no cage can write main
fabriek -f knot mirror           merged main and the record reach your
                                 checkout as fabriek/knot/main and
                                 refs/fabriek/knot/record, on your word
```

Nobody typed anything after `file`. The decider chose, the executor
checked, the workers worked, and the proxy counted.
`examples/factory-project` is a fuller one: five trades, five stages,
consults between roles, a budget and a decider policy.

## What the floor gives every factory

### No agent has a route off the host

A factory runs on a NixOS host that runs several, each on a bridge, a
forge, a bus and a slice of its own (ADR-067). A cage has one address on
its factory's bridge, which leads to the proxy and nowhere else, and the
host forwards nothing from it. The proxy holds the model credentials,
reaches the endpoints the operator named, and nothing more (ADR-025,
ADR-037). A role that must not share the host's kernel asks for
`substrate = "microvm"` and nixcage boots its cage in a kernel of its own;
the operator may make that the floor for every role. A cage holds no
credential and no route; `tests/manual/isolation.sh` is the measurement.

### No test, no code

Every builder's loop carries a guard that refuses a production edit before
a test has been edited and seen failing, and refuses done before a run has
passed (ADR-044). What counts as a test is what the specialist's `tests`
says. The guard is modeled in `models/tdd-guard.qnt` and checked, not
promised in a prompt.

### Nothing a worker writes reaches a command line

The executor is uncaged and content-blind: it validates six verbs against
the declaration and the board and acts on nothing else. The decider is
caged, reads everything, and can only ask. A worker's word about what it
holds is a claim the executor checks against its own board (ADR-033).

### Merge is your click

A role writes only `refs/heads/<role>/*`. `main` is writable by no cage.
The board and the record are the factory's own Forgejo (ADR-036); a stage
moves only on a signed commit, and `main` moves only in its web UI, by
you. `mirror` brings it into the factory's clone afterwards, and your
checkout fetches it from there: nothing in the factory writes your
repository (ADR-067).

### Workers with keys, not sessions with prompts

A role is a worker: its own uid, its own worktree, its own home, its own
signing key, its own forge account and bus user (ADR-010, ADR-033).
`replicas = N` is N such workers, and a stage's tasks spread across them
(ADR-053). Adding a second builder adds capacity without touching the
pipeline, because a stage names a capability and never a role (ADR-015).

### Every token counted

The proxy counts each cage's spend against the factory's `tokens`; a
workflow's `budget.runs` caps what it may try; the operator's caps clamp
both, and fabriek says which field it clamped rather than sizing down
quietly (ADR-020, ADR-037).

## What you shape

**Workflows.** A pipeline of stages; each `needs` a capability, may name
what a task must carry before it is taken (`ready`), what finishing means
there (`done`, prose the role reads), whether the stage is a judgement
rather than a change (`verdict`), and a `gate`. `consults` says who may
ask whom; `budget` says what a run of the workflow may cost.

**Roles.** `provides`, `specialists`, optionally `shell` (a devShell of the
repository's flake, for the project's own build environment), `command`
(argv, for an actor other than pi), `replicas`.

**Catalogues.** fabriek ships `committer`, `developer`, the language and
framework specialists, `architect`, `manager` and `reviewer`
(`fabriek ls`, `fabriek show NAME`). A repository adds its own beside
them (ADR-042); the operator may add more that any factory on this host
may name (ADR-061). Specialists compose and extend; a skill is a
`SKILL.md` in the Agent Skills format; a language server reaches pi through
`pi-lsp` (ADR-043); every worker queries its worktree as a graph through
`codegraph` (ADR-049).

**The operator's side.** `~/.config/fabriek/config.toml`: caps, which
endpoints exist and which credential opens each, which model a session
starts on, and where each factory's repository is. On NixOS the same
file is `services.fabriek`, and a factory can come up at boot (ADR-048).
A declaration names no endpoint, credential or model; those are the
operator's alone.

Both files are closed schemas: a key fabriek does not recognise is refused
by name. `docs/architecture.md` is the whole floor as built;
`docs/TRACKER.md` indexes every decision.

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
| `fabriek up [-u] [FACTORY]` | Bring a factory up on this host, pinned to the checkout's commit; -u moves the pin to HEAD; its branches appear in the checkout as `fabriek/NAME/*` |
| `fabriek down [FACTORY]` | Stop it, refusing while a role's cage runs rather than forcing one |
| `fabriek fetch [FACTORY]` | The factory's branches into the checkout, now |
| `fabriek ps [--json]` | Every factory declared here, and what each is doing |
| `fabriek enter ROLE [-- CMD...]` | Enter a role by hand, in its own worktree and uid; inside its cage when its actor runs |
| `fabriek stop [-k] ROLE` | End a role's running turn through the executor; -k ends the cage at its scope |
| `fabriek steer ROLE [TEXT]` | Speak into a role's running turn; TEXT or stdin |
| `fabriek log [-t] ROLE [SESSION]` | The sessions pi kept for a role, or one of them as it is or as the turns' text |
| `fabriek file [-m BODY] WORKFLOW TITLE` | File a goal, the body from -m or stdin; the decider assigns it and nothing is typed after |
| `fabriek board` | Where Forgejo's UI is on the factory's bridge, and the login, for merging |
| `fabriek watch [--from ID] [--stream NAME]...` | The factory's bus as JSON lines, for any client; some streams or all |
| `fabriek send [JSON]` | A command in the decider's vocabulary, from you or stdin |
| `fabriek mirror` | Merged main and the record into the factory's clone, then your checkout |

## Not yet

`docs/roadmap.md` keeps the list. The record reaches origin without its
comments; the TUI shows what the bus carries and not yet the forge's own
views; the proofs on a NixOS host, the specialists' among them, have not
all passed. A cage has no network, so a language whose build tool fetches
dependencies works only when the project's devShell carries the cache.

## Development

fabriek runs on [nixcage](https://github.com/hamidr/nixcage), which owns
the cages: isolation, uid mapping, binds, secrets and storage are its;
everything that exists only because several named workers share one
repository is here (ADR-018).

```bash
nix develop
nix develop --command shellcheck -x fabriek fabriek-container modules/*.sh
nix develop --command bats --recursive tests/
nix build .#factory
nix develop --command bats tests/command/catalogue.bats   # the catalogue, built for real
nix develop --command tests/system/journey.sh   # the whole factory on this host, no model
docmeta-check docs && docmeta-tracker --check docs
quint run models/factory-lifecycle.qnt --invariant=allInvariants --max-steps=60 --max-samples=10000
quint run models/tdd-guard.qnt --invariant=allInvariants --max-steps=40 --max-samples=10000
```

ADR-001 through ADR-008 describe code that now lives in nixcage; a change
to cage behaviour is proposed there rather than here.

## License

GPL-3.0-only.
