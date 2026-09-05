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
secrets, storage and the macOS VM is nixcage's; everything that exists only
because several named workers share one repository is here (ADR-018).

## How it works

```
cageworks task file acme ship --acceptance "the importer handles empty files"
     |
     +-- the workflow's first stage says what the work needs: "design"
     +-- the first idle role providing "design" takes it, in declaration order
     |
cageworks task run acme task-0001
     |
     +-- brief written to a directory the role's cage gets read-only
     +-- nixcage-container enter --uid ... --user architect --bind ... --no-agent
     +-- the role writes an outcome; the supervisor reads it and moves the work on
     |
cageworks factory sync acme        hands the shared branch back to you
```

The supervisor is uncaged and content-blind. It reads declarations and
metadata, never a task body, a comment or a document, and mentions are labels
rather than parsed prose. Judging whether work meets a bar is reading content,
which is what a cage is for.

## Install

cageworks is two programs and a NixOS module. The module goes beside nixcage's
in the configuration that declares your cages -- on macOS the VM flake at
`~/.config/nixcage`, on Linux the host's own configuration.

`examples/config/flake.nix` is a complete machine; copy the cageworks parts of
it. The shortest declaration that works:

```nix
nixcage.principalUidRange = { base = 700000; size = 64; };

cageworks.factories.acme = {
  repository = "/home/me/Src/acme";
  roles.builder = { command = [ "claude" ]; provides = [ "build" ]; };
  workflows.ship.stages = [ { needs = "build"; } ];
};
```

The uid range is nixcage's because a range of the host's uid space is a fact
about the machine, and the program handing numbers out is the only one that can
promise never to reissue one.

## Commands

| Command | Description |
|---|---|
| `cageworks role [--pane] <factory> <role> [-- cmd]` | Enter a role by hand, in its own worktree and uid (`--pane`: in a herdr pane of its own) |
| `cageworks task file <factory> <workflow> [--acceptance <text>]` | File a goal. It enters at the workflow's first stage; you never name a role |
| `cageworks task list <factory> [state]` | What is filed, and who holds it |
| `cageworks task show <factory> <id>` | One task's fields |
| `cageworks task thread <factory> <id>` | The discussion of one task |
| `cageworks task run <factory> <id>` | Run one task in the cage of whoever takes it |
| `cageworks task answer <factory> <id> approve\|reject [reason]` | Answer a gate |
| `cageworks factory status\|sync\|resume\|reports <factory>` | What a factory is doing, and handing its work to you |
| `cageworks factory integrate <factory> <commit>` | Advance the shared branch to a commit a role produced |

## How work moves

A pipeline's stage names a **capability** rather than a role, roles declare what
they **provide**, and taking a task resolves the first idle capable role in
declaration order. After that the task sticks to it, because the branch is in
that role's namespace and no peer can write it. Adding a second backend adds
capacity without touching the pipeline.

Each stage states its own `ready` -- the fields a task must carry before the
stage will take it, checked for presence and nothing else -- and its own `done`,
which is prose handed to the role and never checked (ADR-015).

Discussion lives in [git-bug](https://github.com/git-bug/git-bug) inside the
repository, so there is no shared database anywhere (ADR-013). The supervisor is
the only writer and acts as each role in turn.

Roles work a clone on nixcage's own storage rather than your checkout, because
role ownership needs a filesystem carrying ownership and ACLs and a macOS
operator's share has neither. `cageworks factory sync` keeps the two in
agreement, in the only direction each is allowed to move (ADR-011).

## What is not here yet

Nothing dispatches. `cageworks task run <factory> <id>` starts one run and a
person types it. A loop that picks ready work is what remains of PRD-002.

## Development

```bash
nix develop
nix develop --command shellcheck cageworks cageworks-container modules/*.sh
nix develop --command bats --recursive tests/
docmeta-check docs && docmeta-tracker --check docs
alloy6 exec models/factory-structure.als
quint run models/factory-lifecycle.qnt --invariant=allInvariants --max-steps=60
```

`docs/TRACKER.md` indexes every decision. ADR-001 through ADR-008 describe code
that now lives in nixcage; they remain as the record of why the cage is shaped
as it is, and a change to cage behaviour is proposed there rather than here.

## License

GPL-3.0-only.
