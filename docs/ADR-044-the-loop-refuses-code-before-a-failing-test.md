---
id: ADR-044
title: The loop refuses production code before a failing test, and done before a passing run
status: proposed
date: 2026-09-13
status_date: 2026-09-13
summary: the loop's test-first guard refuses edits and done by the order of test edits, runs and code edits, per specialist
depends_on: [ADR-033, ADR-035, ADR-038, ADR-042]
supersedes: []
superseded_by: []
---

## Context

Every specialist is told to work test first (the `tdd` skill), and the
reviewer reads the commit order for it (`discipline-review`). Both are
norms: a model follows them most of the time, and the reviewer catches
some of the rest one task later. Nothing refuses.

The loop can. It is fabriek's own pi extension (ADR-035), and pi hands an
extension every tool call before it runs, with the power to refuse it and
say why. The loop already sees the agent's `write`, `edit` and `bash`
calls and their results, and already owns `report_outcome`. What it does
not know is which files are tests, which are production, and which
command runs the tests; those differ per language and are exactly what a
specialist is (ADR-042).

Not everything in "test first" is mechanical. Whether an edit after a
green run is a refactor or a new behaviour smuggled in without its test is
a judgement, and the reviewer keeps it. What is mechanical is the order:
a test is written, it is run, then code is written, then it is run again,
and nothing is done until the last run after the last edit passed.

## Decision

**1. A specialist declares what a test is and how tests run.** A catalogue
entry gains one key:

```nix
tests = {
  files = [ "**/*_test.py" "**/test_*.py" "tests/**" ];
  source = [ "src/**" "**/*.py" ];
  command = [ "pytest" "python -m pytest" ];
};
```

`files` are test files; `source` are production files the guard watches;
anything matching neither (docs, configuration, models) is free. `command`
lists the ways the test runner is invoked; a `bash` call whose first words
match one of them is a test run, and its exit code is the verdict.
Composed like the rest (ADR-042 point 4): the union across the role's
specialists, written to `share/fabriek/specialist/tests.json`, linked into
the role's pi directory as `tests.json`. A role whose specialists declare
none has no guard, and the file says so with empty lists.

**2. The guard is a small state machine in the loop, per session.** Three
variables: the last run's verdict (`none`, `failed`, `passed`), whether a
source file was edited since that run, whether a test file was edited
since that run. Four rules:

- A source edit is refused when a test file was edited since the last
  run: the test has to be seen failing first.
- A source edit is refused when the last run passed and a source edit
  already happened since: run between steps.
- A source edit is refused when no run has happened at all in the
  session.
- `report_outcome` with `done` is refused when the last run did not pass
  or a source edit happened since it. `blocked` and `failed` are never
  refused.

Every refusal names the rule and the next step in one sentence, as the
tool's result, so the agent reads what to do rather than guessing. The
tool is not run.

**3. What counts is what the loop saw.** A test run is a `bash` call the
loop matched and whose result carried the exit code; a run the agent
claims in prose is not a run. A file edit is a `write` or `edit` call on a
path the loop classified. Tests that run inside a script the agent wrote
do not count unless the script's first words match the declaration; the
specialist's `command` list is where to add them.

**4. Refusals are events.** Each one goes to the role's events on the bus
like the loop's other events (ADR-038), with the rule and the path, so the
operator's client shows a role fighting the guard and the record of a
session says how often.

**5. The state machine is modeled before it is built.** `models/tdd-guard.qnt`
holds the guard's variables, the agent's moves and the four rules;
`quint run` over its invariants (no two source edits without a run
between, no source edit after a test edit without a run, no done without
a passing run since the last edit) is part of the verification below.

**6. There is one escape and it is visible.** A repository's own
specialist (ADR-042 point 3) that declares no `tests` has no guard on the
roles that name it alone. That choice is a directory in the repository,
in the commit, read by the reviewer; there is no flag a role can set from
inside the cage.

## Consequences

A role cannot write production code before running a test that was
written or changed, and cannot report done on a red or unrun suite. What
it can still do is write a test that does not fail, or refactor after
green into new behaviour; the reviewer keeps both.

The guard is only as right as the patterns. A test file outside `files`
counts as source and its edit is refused until a run; a source file
outside `source` is unwatched. The shipped catalogue's patterns are the
usual layouts per language; a project with an unusual one declares a
specialist of its own with its own patterns, which is the escape above
used as intended.

A session starts with no run, so the first move a role can make on source
is a test run or a test edit. That is the point, and the refusal says so.

The loop gains state and an input surface: `tests.json` from the store,
and the classification of every write. It reads no content and runs
nothing; it matches paths and argv words and reads exit codes it already
received. ADR-034's invariant that nothing a role writes reaches a command
line holds; the loop's own commands are unchanged.

The decider is not guarded: its directory carries no `tests.json`, and it
edits nothing.

## Verification

```bash
quint typecheck models/tdd-guard.qnt
quint run models/tdd-guard.qnt --invariant=allInvariants --max-steps=40 --max-samples=10000
nix develop --command bats tests/command/catalogue.bats
nix develop --command bats tests/command/machine_services.bats
nix build .#factory
```

`guard.test.ts` in the extension drives the state machine with scripted
tool calls and asserts each rule's refusal text and each allowed move;
`bind.test.ts` asserts a refusal is an event on the bus. `catalogue.bats`
composes `tests.json` from fixture specialists and reads it out of the
built role. `machine_services.bats` asserts the pi directory links it.

On a machine, `tests/manual/specialist.sh` gains a step: with a model, a
role told to add a function without a test is refused, and the refusal is
in the transcript and on the bus. Not run as of this document's date.
