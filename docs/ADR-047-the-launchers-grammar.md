---
id: ADR-047
title: The launcher has one verb level, a factory option, and the conventions of a Unix tool
status: proposed
date: 2026-09-14
status_date: 2026-09-14
summary: fabriek [-f FACTORY] VERB; flags anywhere, -h per verb, stderr and exit 2 for usage, colour only on a tty, --json, stdin
depends_on: [ADR-019, ADR-039, ADR-042]
supersedes: []
superseded_by: []
---

## Context

The launcher grew a verb at a time and its surface shows it: `up acme`
is verb first, `role stop acme builder` is noun then verb, `factory
console acme` is noun then verb with the factory last, `task file` is a
noun for one verb, and `vm status` is a noun nixcage used. Flags sat in
three places: `role stop --now acme builder` before the factory, `up acme
--update` after it, `role transcript --text` before everything. Every
line it printed carried a coloured `[fabriek]` whether or not anyone was
looking, so nothing piped cleanly; usage errors and refusals both exited
1; a body reached `task file` as an argument or not at all.

A host runs one machine per factory (ADR-019), on NixOS beside other
microVMs, on macOS beside other VMs, and several at once. Which factory
a verb is about is ordinary, not assumed, and it wants saying once.

## Decision

**1. One verb level, the factory an option.** `fabriek [-f FACTORY]
VERB [ARGS]`. `-f` names the factory a verb is about; absent, the
`FABRIEK_FACTORY` environment, and absent that, the one factory the
config registers, with a refusal naming the choices when there are more.
`up` and `down` take the factory positionally as well, because the
machine is their object.

**2. The verbs.**

| Verb | Was |
| --- | --- |
| `up [-u] [FACTORY]` | `up <factory> [--update]` |
| `down [FACTORY]` | `down <factory>` |
| `ps` | `vm status` |
| `check [REPO]` | `check` |
| `ls [REPO]` | `catalogue list` |
| `show NAME [REPO]`, `show -f FACTORY ROLE` | `catalogue show`, `role show` |
| `enter ROLE [-- CMD...]` | `role <factory> <role>` |
| `stop [-k] ROLE` | `role stop [--now]` |
| `steer ROLE [TEXT]` | `role steer` |
| `log [-t] ROLE [SESSION]` | `role transcript [--text]` |
| `file [-m BODY] WORKFLOW TITLE` | `task file <factory> <workflow> <title> [body]` |
| `console`, `board`, `watch [--from ID]`, `send [JSON]`, `mirror` | `factory <verb> <factory>` |

Old spellings are removed, not aliased.

**3. Conventions, every verb.** Flags are accepted before or after
positionals; the machine program reads a verb's flags by name, never by
position. `-h` on any verb prints that verb's usage and exits 0. A usage
error exits 2 with one line on stderr; a refusal exits 1 the same way;
every line to stderr begins `fabriek: `. The coloured prefix on
informational lines appears only when stdout is a terminal; otherwise the
line is plain. `ls`, `ps`, `show` and `check` take `--json` and print the
structure their text is made from. `steer`, `send` and `file` read their
text from stdin when the argument is `-` or absent and stdin is not a
terminal. A verb with nothing to say on success says nothing.

**4. What does not change.** `fabriek-container`'s verbs are the machine's
and a person never types them; the transport (argv NUL-framed through
`xargs -0`) and the one ssh path are ADR-019's and stay.

## Consequences

`fabriek -f acme stop builder` and `fabriek stop builder` on a host with
one factory read like any tool; `fabriek ps | awk` and `fabriek ls --json
| jq` work. Every scenario naming a verb is rewritten; README, CLAUDE.md
and the architecture say the new names; ADR-039's verb list is what it
was when written.

`show` does two things by whether `-f` is given: a specialist of the
catalogue, or a role of a factory. The alternative was two verbs for one
question, "what is this composed of".

`-k` on `stop` is `kill`'s letter for the same reason: it ends the
process without asking it.

## Verification

```bash
nix develop --command bats tests/command/cli_dispatch.bats tests/command/role.bats tests/command/vm.bats
nix develop --command bats tests/command/vm_up.bats tests/command/factory_board.bats
nix develop --command bats tests/command/check.bats tests/command/catalogue_cli.bats
nix develop --command bats --recursive tests/
```

`cli_dispatch.bats` derives the verb list from the dispatcher and holds
the help to it; `role.bats` asserts `-f` before and after the verb, the
one-factory default, the refusal with two, and each flag in either
position on the wire; `vm.bats` asserts `ps` and its `--json`.
